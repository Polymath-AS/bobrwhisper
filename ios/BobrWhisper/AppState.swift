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
    @Published private(set) var transcriptLog: [TranscriptLogEntry] = []
    
    @Published private(set) var availableModels: [SpeechModelDescriptor] = []
    @Published var selectedModelID: String = defaultSpeechModelID
    @Published var tone: Tone = .neutral
    @Published var removeFillerWords: Bool = true
    @Published var autoPunctuate: Bool = true
    
    private var app: bobrwhisper_app_t?
    private var downloadSession: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var modelsDirCString: UnsafeMutablePointer<CChar>?
    private var vadModelPathCString: UnsafeMutablePointer<CChar>?
    private let transcriptLogLimit: Int = 50
    
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

    var latestTranscriptText: String {
        transcriptLog.first?.text ?? lastTranscript
    }
    
    init() {
        setupAudioSession()
    }

    private func refreshAvailableModels() {
        availableModels = Self.loadAvailableModels(app)
        if let selectedModel = resolveModel(id: selectedModelID) {
            selectedModelID = selectedModel.id
            return
        }
        if let defaultModel = resolveModel(id: defaultSpeechModelID) {
            selectedModelID = defaultModel.id
        } else if let firstModel = availableModels.first {
            selectedModelID = firstModel.id
        }
    }

    private static func loadAvailableModels(_ app: bobrwhisper_app_t?) -> [SpeechModelDescriptor] {
        let count = Int(bobrwhisper_model_count(app))
        guard count > 0 else { return [] }

        var models: [SpeechModelDescriptor] = []
        models.reserveCapacity(count)

        for index in 0..<count {
            var descriptor = bobrwhisper_model_descriptor_s()
            guard bobrwhisper_model_descriptor_at(app, index, &descriptor) else { continue }
            guard let model = SpeechModelDescriptor(rawDescriptor: descriptor) else { continue }
            models.append(model)
        }

        return models
    }

    func resolveModel(id: String) -> SpeechModelDescriptor? {
        availableModels.first { $0.id == id }
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
        KeyboardSharedState.writeSelectedModelID(nil)
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
                if isFinal {
                    appState.appendTranscriptLogEntry(transcript, persistToStore: true)
                }
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
            return
        }

        refreshAvailableModels()
        loadTranscriptLogFromStore()
        loadDefaultModel()
    }

    private func loadDefaultModel() {
        guard let key = UserDefaults.standard.string(forKey: "defaultModel") else { return }

        let resolvedModelID = resolveLegacyStoredModelID(key)
        guard let model = resolveModel(id: resolvedModelID), modelExists(model) else { return }

        selectedModelID = model.id
        loadModel()
    }
    
    func destroyApp() {
        if let app = app {
            bobrwhisper_app_free(app)
            self.app = nil
        }
        if let ptr = modelsDirCString { free(ptr); modelsDirCString = nil }
        if let ptr = vadModelPathCString { free(ptr); vadModelPathCString = nil }
        KeyboardSharedState.writeIsRecording(false)
        KeyboardSharedState.writeIsModelLoaded(false)
        KeyboardSharedState.writeSelectedModelID(nil)
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
    
    func modelExists(_ model: SpeechModelDescriptor) -> Bool {
        guard let app = app else {
            let modelPath = modelsDirectory.appendingPathComponent(model.localFilename)
            return FileManager.default.fileExists(atPath: modelPath.path)
        }
        return model.id.withCString { modelIDPtr in
            bobrwhisper_model_exists_id(app, modelIDPtr)
        }
    }
    
    func getModelPath(_ model: SpeechModelDescriptor) -> String? {
        guard let app = app else { return nil }
        let pathStr = model.id.withCString { modelIDPtr in
            bobrwhisper_model_path_id(app, modelIDPtr)
        }
        guard let ptr = pathStr.ptr else { return nil }
        let path = String(cString: ptr)
        bobrwhisper_string_free(pathStr)
        return path
    }
    
    func loadModel() {
        guard let app = app else { return }
        guard let model = resolveModel(id: selectedModelID) else { return }
        status = .transcribing  // Show loading state
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let success = model.id.withCString { modelIDPtr in
                bobrwhisper_model_load_id(app, modelIDPtr)
            }
            
            DispatchQueue.main.async {
                guard let self = self else { return }
                if success {
                    self.isModelLoaded = true
                    KeyboardSharedState.writeIsModelLoaded(true)
                    KeyboardSharedState.writeSelectedModelID(model.id)
                    UserDefaults.standard.set(model.id, forKey: "defaultModel")
                } else {
                    self.errorMessage = "Failed to load model"
                    self.isModelLoaded = false
                    self.status = .error
                    KeyboardSharedState.writeIsModelLoaded(false)
                    KeyboardSharedState.writeSelectedModelID(nil)
                    return
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
        KeyboardSharedState.writeSelectedModelID(nil)
    }
    
    func downloadModel(_ model: SpeechModelDescriptor) {
        guard !isDownloading else { return }
        guard let url = model.downloadURL else { return }
        
        isDownloading = true
        downloadProgress = 0
        
        let destinationURL = modelsDirectory.appendingPathComponent(model.localFilename)
        
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
                    self?.selectedModelID = model.id
                    self?.loadModel()
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
        UIPasteboard.general.string = latestTranscriptText
    }
    
    func clearTranscript() {
        if let app = app {
            _ = bobrwhisper_log_clear(app)
        }
        lastTranscript = ""
        transcriptLog.removeAll()
        status = .idle
    }

    private func appendTranscriptLogEntry(_ transcript: String, persistToStore: Bool) {
        let normalizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTranscript.isEmpty else {
            return
        }

        if persistToStore, let app = app {
            normalizedTranscript.withCString { textPtr in
                let text = bobrwhisper_string_s(ptr: textPtr, len: normalizedTranscript.utf8.count)
                _ = bobrwhisper_log_transcript(app, text)
            }
        }

        transcriptLog.insert(TranscriptLogEntry(text: normalizedTranscript, createdAt: Date()), at: 0)
        if transcriptLog.count > transcriptLogLimit {
            transcriptLog.removeLast(transcriptLog.count - transcriptLogLimit)
        }
    }

    private func loadTranscriptLogFromStore() {
        guard let app = app else { return }

        let jsonString = bobrwhisper_log_recent_json(app, transcriptLogLimit)
        defer { bobrwhisper_string_free(jsonString) }

        guard let ptr = jsonString.ptr, jsonString.len > 0 else {
            transcriptLog = []
            return
        }

        let data = Data(bytes: ptr, count: jsonString.len)
        let decoder = JSONDecoder()
        guard let entries = try? decoder.decode([TranscriptLogStoreEntry].self, from: data) else {
            transcriptLog = []
            return
        }

        transcriptLog = entries.map { entry in
            TranscriptLogEntry(
                text: entry.text,
                createdAt: Date(timeIntervalSince1970: Double(entry.createdAtUnixMs) / 1000.0)
            )
        }
    }
}

struct TranscriptLogEntry: Identifiable {
    let id = UUID()
    let text: String
    let createdAt: Date
}

private struct TranscriptLogStoreEntry: Decodable {
    let createdAtUnixMs: Int64
    let text: String

    enum CodingKeys: String, CodingKey {
        case createdAtUnixMs = "created_at_unix_ms"
        case text
    }
}

private let defaultSpeechModelID = "whisper-small"

func resolveLegacyStoredModelID(_ storedValue: String) -> String {
    switch storedValue {
    case "tiny": return "whisper-tiny"
    case "base": return "whisper-base"
    case "small": return "whisper-small"
    case "medium": return "whisper-medium"
    case "large": return "whisper-large-v3"
    case "large_turbo": return "whisper-large-v3-turbo"
    default: return storedValue
    }
}

struct SpeechModelDescriptor: Identifiable, Equatable {
    let id: String
    let displayName: String
    let family: String
    let runtime: ModelRuntime
    let localFilename: String
    let downloadURL: URL?
    let sizeBytes: UInt64
    let capabilities: UInt64
    let availableOnThisDevice: Bool

    init?(rawDescriptor: bobrwhisper_model_descriptor_s) {
        guard let idPtr = rawDescriptor.id,
              let displayNamePtr = rawDescriptor.display_name,
              let familyPtr = rawDescriptor.family,
              let localFilenamePtr = rawDescriptor.local_filename else {
            return nil
        }

        id = String(cString: idPtr)
        displayName = String(cString: displayNamePtr)
        family = String(cString: familyPtr)
        runtime = ModelRuntime(cValue: rawDescriptor.runtime)
        localFilename = String(cString: localFilenamePtr)
        if let downloadURLPtr = rawDescriptor.download_url {
            downloadURL = URL(string: String(cString: downloadURLPtr))
        } else {
            downloadURL = nil
        }
        sizeBytes = rawDescriptor.size_bytes
        capabilities = rawDescriptor.capabilities
        availableOnThisDevice = rawDescriptor.available_on_this_device
    }

    var detailsText: String {
        "\(family.capitalized) • \(formattedSize)"
    }

    private var formattedSize: String {
        let gigabyte = 1024.0 * 1024.0 * 1024.0
        let megabyte = 1024.0 * 1024.0
        let size = Double(sizeBytes)
        if size >= gigabyte {
            return String(format: "%.1f GB", size / gigabyte)
        }
        return String(format: "%.0f MB", size / megabyte)
    }
}

enum ModelRuntime: String {
    case whisperCpp = "whisper.cpp"
    case coreml = "Core ML"
    case onnx = "ONNX"
    case server = "Server"

    init(cValue: bobrwhisper_model_runtime_e) {
        switch cValue {
        case BOBRWHISPER_MODEL_RUNTIME_COREML:
            self = .coreml
        case BOBRWHISPER_MODEL_RUNTIME_ONNX:
            self = .onnx
        case BOBRWHISPER_MODEL_RUNTIME_SERVER:
            self = .server
        default:
            self = .whisperCpp
        }
    }
}

private class DownloadDelegate: NSObject, URLSessionDownloadDelegate, URLSessionDataDelegate {
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
