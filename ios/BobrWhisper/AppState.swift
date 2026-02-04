import Foundation
import AVFoundation
import UIKit
import BobrWhisperKit

class AppState: ObservableObject {
    @Published private(set) var status: Status = .idle
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var lastTranscript: String = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var isModelLoaded: Bool = false
    @Published private(set) var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0
    
    @Published var selectedModel: ModelSize = .small
    @Published var tone: Tone = .neutral
    @Published var removeFillerWords: Bool = true
    @Published var autoPunctuate: Bool = true
    
    private var app: bobrwhisper_app_t?
    private var downloadSession: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var modelsDirCString: UnsafeMutablePointer<CChar>?
    private var vadModelPathCString: UnsafeMutablePointer<CChar>?
    
    var statusText: String {
        switch status {
        case .idle: return isModelLoaded ? "Ready" : "Load a model to start"
        case .recording: return "Recording..."
        case .transcribing: return "Transcribing..."
        case .formatting: return "Formatting..."
        case .ready: return "Done"
        case .error: return errorMessage ?? "Error"
        }
    }
    
    var statusIcon: String {
        switch status {
        case .idle: return "waveform"
        case .recording: return "waveform.circle.fill"
        case .transcribing: return "text.bubble"
        case .formatting: return "sparkles"
        case .ready: return "checkmark.circle"
        case .error: return "exclamationmark.triangle"
        }
    }
    
    var statusColor: UIColor {
        switch status {
        case .idle: return .secondaryLabel
        case .recording: return .systemRed
        case .transcribing, .formatting: return .systemBlue
        case .ready: return .systemGreen
        case .error: return .systemOrange
        }
    }
    
    init() {
        setupAudioSession()
    }
    
    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            print("Failed to set up audio session: \(error)")
        }
    }
    
    var modelsDirectory: URL {
        KeyboardSharedState.modelsDirectory()
    }
    
    func createApp() {
        let modelsDir = modelsDirectory.path
        try? FileManager.default.createDirectory(atPath: modelsDir, withIntermediateDirectories: true)
        KeyboardSharedState.writeIsRecording(false)
        KeyboardSharedState.writeIsModelLoaded(false)
        KeyboardSharedState.writeTranscript("")
        KeyboardSharedState.writeStatusRaw(Int(Status.idle.rawValue))

        #if targetEnvironment(simulator)
        setenv("GGML_METAL_DISABLE", "1", 1)
        #endif
        
        var config = bobrwhisper_runtime_config_s()
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.on_status_change = { userdata, newStatus in
            guard let userdata = userdata else { return }
            let appState = Unmanaged<AppState>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async {
                appState.status = Status(cValue: newStatus)
                KeyboardSharedState.writeStatusRaw(Int(newStatus.rawValue))
            }
        }
        config.on_transcript = { userdata, text, isFinal in
            guard let userdata = userdata else { return }
            // Copy string synchronously before Zig frees it
            // Use the length from the struct, not strlen (Zig strings aren't null-terminated)
            let transcript: String
            if let ptr = text.ptr, text.len > 0 {
                let data = Data(bytes: ptr, count: text.len)
                transcript = String(data: data, encoding: .utf8) ?? ""
            } else {
                transcript = ""
            }
            let appState = Unmanaged<AppState>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async {
                appState.lastTranscript = transcript
                KeyboardSharedState.writeTranscript(transcript)
            }
        }
        config.on_error = { userdata, error in
            guard let userdata = userdata else { return }
            // Copy string synchronously before Zig frees it
            // Use the length from the struct, not strlen (Zig strings aren't null-terminated)
            let errorMsg: String?
            if let ptr = error.ptr, error.len > 0 {
                let data = Data(bytes: ptr, count: error.len)
                errorMsg = String(data: data, encoding: .utf8)
            } else {
                errorMsg = nil
            }
            let appState = Unmanaged<AppState>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async {
                appState.errorMessage = errorMsg
                appState.status = .error
                KeyboardSharedState.writeStatusRaw(Int(Status.error.rawValue))
            }
        }
        
        let vadModelPath = Bundle.main.path(forResource: "silero-v6.2.0", ofType: "bin")
        
        modelsDirCString = strdup(modelsDir)
        vadModelPathCString = vadModelPath.flatMap { strdup($0) }
        
        config.models_dir = UnsafePointer(modelsDirCString)
        config.vad_model_path = UnsafePointer(vadModelPathCString)
        
        app = bobrwhisper_app_new(&config)
        
        if app == nil {
            errorMessage = "Failed to create BobrWhisper app"
            status = .error
            KeyboardSharedState.writeStatusRaw(Int(Status.error.rawValue))
        }
    }
    
    func destroyApp() {
        if let app = app {
            bobrwhisper_app_free(app)
            self.app = nil
        }
        if let ptr = modelsDirCString { free(ptr); modelsDirCString = nil }
        if let ptr = vadModelPathCString { free(ptr); vadModelPathCString = nil }
        KeyboardSharedState.writeIsRecording(false)
    }
    
    func startRecording() {
        guard let app = app else { return }
        
        // Use live transcription for streaming results
        "en".withCString { langPtr in
            if bobrwhisper_start_recording_live(app, langPtr) {
                isRecording = true
                lastTranscript = "" // Clear previous transcript
                KeyboardSharedState.writeIsRecording(true)
                KeyboardSharedState.writeTranscript("")
            }
        }
    }
    
    func stopRecording() {
        guard let app = app else { return }
        
        // Stop with final transcription
        "en".withCString { langPtr in
            var options = bobrwhisper_transcribe_options_s()
            options.language = langPtr
            options.tone = tone.cValue
            options.remove_filler_words = removeFillerWords
            options.auto_punctuate = autoPunctuate
            options.use_llm_formatting = false
            
            _ = bobrwhisper_stop_recording_live(app, &options)
        }
        isRecording = false
        KeyboardSharedState.writeIsRecording(false)
    }
    
    func transcribe() {
        guard let app = app else { return }
        
        "en".withCString { langPtr in
            var options = bobrwhisper_transcribe_options_s()
            options.language = langPtr
            options.tone = tone.cValue
            options.remove_filler_words = removeFillerWords
            options.auto_punctuate = autoPunctuate
            options.use_llm_formatting = false
            
            _ = bobrwhisper_transcribe(app, &options)
        }
    }
    
    func modelExists(_ size: ModelSize) -> Bool {
        guard let app = app else {
            // Fallback to FileManager if app not initialized
            let modelPath = modelsDirectory.appendingPathComponent(size.filename)
            return FileManager.default.fileExists(atPath: modelPath.path)
        }
        return bobrwhisper_model_exists(app, size.cValue)
    }
    
    func getModelPath(_ size: ModelSize) -> String? {
        guard let app = app else { return nil }
        let pathStr = bobrwhisper_model_path(app, size.cValue)
        guard let ptr = pathStr.ptr else { return nil }
        let path = String(cString: ptr)
        bobrwhisper_string_free(pathStr)
        return path
    }
    
    func loadModel() {
        guard let app = app else { return }
        let model = selectedModel
        status = .transcribing  // Show loading state
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let success = bobrwhisper_model_load(app, model.cValue)
            
            DispatchQueue.main.async {
                guard let self = self else { return }
                if success {
                    self.isModelLoaded = true
                    KeyboardSharedState.writeIsModelLoaded(true)
                    KeyboardSharedState.writeSelectedModelFilename(model.filename)
                } else {
                    KeyboardSharedState.writeIsModelLoaded(false)
                }
                self.status = .idle
            }
        }
    }
    
    func unloadModel() {
        guard let app = app else { return }
        bobrwhisper_model_unload(app)
        isModelLoaded = false
        KeyboardSharedState.writeIsModelLoaded(false)
    }
    
    func downloadModel(_ size: ModelSize) {
        guard !isDownloading else { return }
        
        isDownloading = true
        downloadProgress = 0
        
        let url = URL(string: size.downloadURL)!
        let destinationURL = modelsDirectory.appendingPathComponent(size.filename)
        
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        
        // Store session to prevent deallocation
        downloadSession = URLSession(configuration: .default, delegate: DownloadDelegate(appState: self), delegateQueue: nil)
        downloadTask = downloadSession?.downloadTask(with: url) { [weak self] tempURL, response, error in
            DispatchQueue.main.async {
                self?.isDownloading = false
                
                if let error = error {
                    self?.errorMessage = "Download failed: \(error.localizedDescription)"
                    self?.status = .error
                    return
                }
                
                guard let tempURL = tempURL else {
                    self?.errorMessage = "Download failed: No file received"
                    self?.status = .error
                    return
                }
                
                do {
                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        try FileManager.default.removeItem(at: destinationURL)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: destinationURL)
                    self?.downloadProgress = 1.0
                } catch {
                    self?.errorMessage = "Failed to save model: \(error.localizedDescription)"
                    self?.status = .error
                    KeyboardSharedState.writeStatusRaw(Int(Status.error.rawValue))
                }
            }
        }
        downloadTask?.resume()
    }
    
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadSession?.invalidateAndCancel()
        downloadSession = nil
        isDownloading = false
        downloadProgress = 0
    }
    
    func copyToClipboard() {
        UIPasteboard.general.string = lastTranscript
    }
    
    func clearTranscript() {
        lastTranscript = ""
        status = .idle
    }
}

private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    weak var appState: AppState?
    private var expectedBytes: Int64 = 0
    
    init(appState: AppState) {
        self.appState = appState
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // Handle case where server doesn't send Content-Length
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes
        let progress: Double
        if expected > 0 {
            progress = Double(totalBytesWritten) / Double(expected)
        } else {
            // Indeterminate - use bytes written as rough indicator (capped)
            progress = min(0.99, Double(totalBytesWritten) / Double(100_000_000))
        }
        DispatchQueue.main.async {
            self.appState?.downloadProgress = progress
        }
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        expectedBytes = response.expectedContentLength
        completionHandler(.allow)
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

enum Status: Int {
    case idle = 0
    case recording = 1
    case transcribing = 2
    case formatting = 3
    case ready = 4
    case error = 5
    
    init(cValue: bobrwhisper_status_e) {
        self = Status(rawValue: Int(cValue.rawValue)) ?? .idle
    }
}

enum ModelSize: String, CaseIterable, Identifiable {
    case tiny = "Tiny (~75 MB)"
    case base = "Base (~142 MB)"
    case small = "Small (~466 MB)"
    case medium = "Medium (~1.5 GB)"
    case large = "Large (~3.1 GB)"
    
    var id: String { rawValue }
    
    var cValue: bobrwhisper_model_size_e {
        switch self {
        case .tiny: return BOBRWHISPER_MODEL_TINY
        case .base: return BOBRWHISPER_MODEL_BASE
        case .small: return BOBRWHISPER_MODEL_SMALL
        case .medium: return BOBRWHISPER_MODEL_MEDIUM
        case .large: return BOBRWHISPER_MODEL_LARGE
        }
    }
    
    var filename: String {
        switch self {
        case .tiny: return "ggml-tiny.bin"
        case .base: return "ggml-base.bin"
        case .small: return "ggml-small.bin"
        case .medium: return "ggml-medium.bin"
        case .large: return "ggml-large-v3.bin"
        }
    }
    
    var downloadURL: String {
        let base = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
        return "\(base)/\(filename)"
    }
    
    var sizeDescription: String {
        switch self {
        case .tiny: return "~75 MB • Fastest, least accurate"
        case .base: return "~142 MB • Fast, basic accuracy"
        case .small: return "~466 MB • Balanced speed/accuracy"
        case .medium: return "~1.5 GB • Slow, high accuracy"
        case .large: return "~3.1 GB • Slowest, best accuracy"
        }
    }
}

enum Tone: String, CaseIterable, Identifiable {
    case neutral = "Neutral"
    case formal = "Formal"
    case casual = "Casual"
    case code = "Code"
    
    var id: String { rawValue }
    
    var cValue: bobrwhisper_tone_e {
        switch self {
        case .neutral: return BOBRWHISPER_TONE_NEUTRAL
        case .formal: return BOBRWHISPER_TONE_FORMAL
        case .casual: return BOBRWHISPER_TONE_CASUAL
        case .code: return BOBRWHISPER_TONE_CODE
        }
    }
    
    var icon: String {
        switch self {
        case .neutral: return "text.alignleft"
        case .formal: return "briefcase"
        case .casual: return "bubble.left"
        case .code: return "chevron.left.forwardslash.chevron.right"
        }
    }
    
    var description: String {
        switch self {
        case .neutral: return "Standard transcription"
        case .formal: return "Professional, polished"
        case .casual: return "Conversational, relaxed"
        case .code: return "Technical, preserves syntax"
        }
    }
}
