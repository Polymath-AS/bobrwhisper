import AppKit
import Foundation
import Combine
import BobrWhisperKit

class AppState: ObservableObject {
    struct InputDevice: Identifiable, Hashable {
        let id: String
        let name: String
        let kind: String
    }
    @Published private(set) var status: Status = .idle
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var lastTranscript: String = ""
    @Published private(set) var errorMessage: String?
    /// Non-fatal advisory text (stuck mic, Bluetooth mic, etc.). Cleared
    /// automatically a few seconds after it is set so the UI doesn't have to
    /// own dismissal logic. Lives separately from `errorMessage` so it does
    /// not flip status to `.error`.
    @Published private(set) var warningMessage: String?
    private var warningClearWorkItem: DispatchWorkItem?
    @Published private(set) var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0
    @Published private(set) var isDownloadingCleanupModel: Bool = false
    @Published var cleanupModelDownloadProgress: Double = 0
    @Published private(set) var installedCleanupModelIDs: Set<String> = []
    @Published private(set) var selectedCleanupModelID: String =
        UserDefaults.standard.string(forKey: "cleanupModelID") ?? CleanupModelDescriptor.defaultID
    @Published private(set) var transcriptLog: [TranscriptLogEntry] = []
    
    @Published private(set) var availableModels: [SpeechModelDescriptor] = []
    @Published var selectedModelID: String = defaultSpeechModelID
    @Published var tone: Tone = .neutral {
        didSet {
            persistSettings()
        }
    }
    @Published private(set) var isModelLoaded: Bool = false
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var inputDevices: [InputDevice] = []
    @Published var selectedInputDeviceID: String = UserDefaults.standard.string(forKey: "inputDeviceID") ?? "" {
        didSet {
            UserDefaults.standard.set(selectedInputDeviceID, forKey: "inputDeviceID")
            applySelectedInputDevice()
        }
    }
    
    var overlayController: OverlayPanelController?
    
    private var app: bobrwhisper_app_t?
    private var audioLevelTimer: Timer?
    private var modelsDirCString: UnsafeMutablePointer<CChar>?
    private var configDomainCString: UnsafeMutablePointer<CChar>?
    private var vadModelPathCString: UnsafeMutablePointer<CChar>?
    private var llmModelPathCString: UnsafeMutablePointer<CChar>?
    private var downloadSession: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var cleanupDownloadSession: URLSession?
    private var cleanupDownloadTask: URLSessionDownloadTask?
    private let transcriptLogLimit: Int = 50
    private var activeSessionID: UInt64 = 0
    private var latestSessionRevision: UInt64 = 0
    private var focusedFieldSession: FocusedFieldSession?
    
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
    
    var statusText: String {
        switch status {
        case .idle: return "Ready"
        case .recording: return "Recording..."
        case .transcribing: return "Transcribing..."
        case .formatting: return "Formatting..."
        case .ready: return "Done"
        case .error: return errorMessage ?? "Error"
        }
    }

    var latestTranscriptText: String {
        transcriptLog.first?.text ?? lastTranscript
    }
    
    init() {}

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
    
    func createApp() {
        let modelsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".bobrwhisper/models").path
        
        // Ensure models directory exists
        try? FileManager.default.createDirectory(
            atPath: modelsDir,
            withIntermediateDirectories: true
        )
        refreshCleanupModelInstallations()
        
        // Build runtime config with callbacks
        var config = bobrwhisper_runtime_config_s()
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.on_status_change = { userdata, newStatus in
            guard let userdata = userdata else { return }
            let appState = Unmanaged<AppState>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async {
                appState.status = Status(cValue: newStatus)
            }
        }
        config.on_transcript = nil
        config.on_transcript_update = { userdata, update in
            guard let userdata = userdata else { return }
            func copiedString(_ value: bobrwhisper_string_s) -> String {
                guard let ptr = value.ptr, value.len > 0 else { return "" }
                return String(decoding: UnsafeRawBufferPointer(start: ptr, count: value.len), as: UTF8.self)
            }
            let stable = copiedString(update.stable_text)
            let unstable = copiedString(update.unstable_text)
            let transcript = stable + unstable
            let sessionID = update.session_id
            let revision = update.revision
            let isFinal = update.phase == BOBRWHISPER_TRANSCRIPT_FINAL
            let appState = Unmanaged<AppState>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async {
                guard sessionID == appState.activeSessionID,
                      revision > appState.latestSessionRevision else { return }
                appState.latestSessionRevision = revision
                appState.lastTranscript = transcript
                appState.focusedFieldSession?.apply(text: transcript, isFinal: isFinal)
                if isFinal {
                    let finalTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !finalTranscript.isEmpty {
                        // Zig owns persistence of raw and final text. Swift only
                        // updates its in-memory projection.
                        appState.appendTranscriptLogEntry(finalTranscript, persistToStore: false)
                    }
                    appState.focusedFieldSession = nil
                    appState.activeSessionID = 0
                    appState.overlayController?.scheduleAutoDismiss()
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
            }
        }

        config.on_warning = { userdata, warning in
            guard let userdata = userdata else { return }
            let warningMsg: String?
            if let ptr = warning.ptr, warning.len > 0 {
                let data = Data(bytes: ptr, count: warning.len)
                warningMsg = String(data: data, encoding: .utf8)
            } else {
                warningMsg = nil
            }
            let appState = Unmanaged<AppState>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async {
                appState.presentWarning(warningMsg)
            }
        }
        
        let vadModelPath = Bundle.main.path(forResource: "silero-v6.2.0", ofType: "bin")
        
        let configDomain = Bundle.main.bundleIdentifier ?? "com.uzaaft.BobrWhisper"

        modelsDirCString = strdup(modelsDir)
        configDomainCString = strdup(configDomain)
        vadModelPathCString = vadModelPath.flatMap { strdup($0) }
        if let selectedCleanupModel = CleanupModelDescriptor.model(id: selectedCleanupModelID),
           cleanupModelExists(selectedCleanupModel) {
            llmModelPathCString = strdup(cleanupModelPath(selectedCleanupModel).path)
        }

        config.models_dir = UnsafePointer(modelsDirCString)
        config.config_path = UnsafePointer(configDomainCString)
        config.vad_model_path = UnsafePointer(vadModelPathCString)
        config.llm_model_path = UnsafePointer(llmModelPathCString)
        
        app = bobrwhisper_app_new(&config)
        
        if app == nil {
            errorMessage = "Failed to create BobrWhisper app"
            status = .error
            return
        }

        refreshAvailableModels()
        refreshInputDevices()
        applySelectedInputDevice()
        loadTranscriptLogFromStore()
        persistSettings()
        loadDefaultModel()
    }

    func refreshInputDevices() {
        guard let app else { return }
        let count = Int(bobrwhisper_audio_device_count(app))
        var devices: [InputDevice] = []
        devices.reserveCapacity(count)
        for index in 0..<count {
            var raw = bobrwhisper_audio_device_descriptor_s()
            guard bobrwhisper_audio_device_at(app, index, &raw) else { continue }
            defer { bobrwhisper_audio_device_descriptor_free(&raw) }
            guard let id = string(from: raw.id), let name = string(from: raw.name) else { continue }
            devices.append(InputDevice(id: id, name: name, kind: string(from: raw.kind) ?? "unknown"))
        }
        inputDevices = devices
        if !selectedInputDeviceID.isEmpty && !devices.contains(where: { $0.id == selectedInputDeviceID }) {
            selectedInputDeviceID = ""
        }
    }

    private func applySelectedInputDevice() {
        guard let app else { return }
        selectedInputDeviceID.withCString { id in
            _ = bobrwhisper_set_input_device(app, id)
        }
    }

    private func string(from value: bobrwhisper_string_s) -> String? {
        guard let ptr = value.ptr, value.len > 0 else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: ptr, count: value.len), as: UTF8.self)
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
        if let ptr = configDomainCString { free(ptr); configDomainCString = nil }
        if let ptr = vadModelPathCString { free(ptr); vadModelPathCString = nil }
        if let ptr = llmModelPathCString { free(ptr); llmModelPathCString = nil }
    }

    /// Display a non-fatal advisory and auto-clear it after a short delay so
    /// the UI doesn't have to track dismissal. Re-firing while a warning is
    /// already on screen restarts the timer with the new text.
    func presentWarning(_ message: String?) {
        warningClearWorkItem?.cancel()
        warningMessage = message
        guard message != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.warningMessage = nil
            self.warningClearWorkItem = nil
        }
        warningClearWorkItem = work
        // 4.5 s sits between "long enough to read" and "out of the way before
        // the next utterance lands". Matches the auto-dismiss feel of a
        // short-lived toast.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: work)
    }

    /// Manually dismiss the warning (used when the user taps the toast).
    func dismissWarning() {
        warningClearWorkItem?.cancel()
        warningClearWorkItem = nil
        warningMessage = nil
    }

    private func persistSettings() {
        guard let app = app else { return }

        var settings = bobrwhisper_settings_s()
        settings.tone = tone.cValue
        settings.remove_filler_words = true
        settings.auto_punctuate = true
        settings.use_llm_formatting = false

        if !bobrwhisper_settings_write(app, &settings) {
            errorMessage = "Failed to save settings"
        }
    }
    
    func startRecording() {
        guard let app = app else { return }
        guard !isRecording, status != .transcribing, status != .formatting else { return }
        
        let autoPasteEnabled = (UserDefaults.standard.object(forKey: "autoPaste") as? Bool) ?? true
        let fieldSession = FocusedFieldSession.capture(insertionEnabled: autoPasteEnabled)
        let context = fieldSession.context

        let strings = [
            strdup("en"),
            strdup(context.bundleID),
            strdup(context.windowTitle),
            strdup(context.textBeforeCursor),
            strdup(context.textAfterCursor),
            strdup(context.selectedText),
        ]
        defer { strings.forEach { free($0) } }

        var recordingContext = bobrwhisper_recording_context_s()
        recordingContext.bundle_id = UnsafePointer(strings[1])
        recordingContext.window_title = UnsafePointer(strings[2])
        recordingContext.text_before_cursor = UnsafePointer(strings[3])
        recordingContext.text_after_cursor = UnsafePointer(strings[4])
        recordingContext.selected_text = UnsafePointer(strings[5])
        recordingContext.is_secure = context.isSecure

        var options = bobrwhisper_recording_options_s()
        options.language = UnsafePointer(strings[0])
        options.postprocess_mode = tone == .neutral
            ? BOBRWHISPER_POSTPROCESS_CONSERVATIVE
            : BOBRWHISPER_POSTPROCESS_POLISH
        options.tone = tone.cValue

        let sessionID = withUnsafePointer(to: &recordingContext) { contextPointer -> UInt64 in
            options.context = contextPointer
            return bobrwhisper_recording_start(app, &options)
        }
        if sessionID != 0 {
            activeSessionID = sessionID
            latestSessionRevision = 0
            focusedFieldSession = fieldSession
            isRecording = true
            lastTranscript = ""
            overlayController?.show()
            startAudioLevelPolling()
        } else {
            fieldSession.detach()
        }
    }
    
    func stopRecording() {
        guard let app = app, isRecording else { return }
        
        stopAudioLevelPolling()
        isRecording = false
        status = .transcribing
        let sessionID = activeSessionID
        
        // Stop/transcribe off the main thread so the recording UI can update immediately.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let success = bobrwhisper_recording_stop(app, sessionID)
            guard !success else { return }

            DispatchQueue.main.async {
                self?.focusedFieldSession?.detach()
                self?.focusedFieldSession = nil
                self?.activeSessionID = 0
                self?.errorMessage = "Failed to transcribe recording"
                self?.status = .error
            }
        }
    }
    
    private func startAudioLevelPolling() {
        audioLevelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self, let app = self.app else { return }
            self.audioLevel = bobrwhisper_get_audio_level(app)
        }
    }
    
    private func stopAudioLevelPolling() {
        audioLevelTimer?.invalidate()
        audioLevelTimer = nil
        audioLevel = 0
    }
    
    func transcribe() {
        guard let app = app else { return }
        
        let currentTone = tone
        
        DispatchQueue.global(qos: .userInitiated).async {
            "en".withCString { langPtr in
                var options = bobrwhisper_transcribe_options_s()
                options.language = langPtr
                options.tone = currentTone.cValue
                options.remove_filler_words = true
                options.auto_punctuate = true
                options.use_llm_formatting = false
                
                _ = bobrwhisper_transcribe(app, &options)
            }
        }
    }
    
    func modelExists(_ model: SpeechModelDescriptor) -> Bool {
        guard let app = app else {
            let modelsDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".bobrwhisper/models")
            let modelPath = modelsDir.appendingPathComponent(model.localFilename)
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
                if !success {
                    self.errorMessage = "Failed to load model"
                    self.status = .error
                    self.isModelLoaded = false
                } else {
                    self.status = .idle
                    self.isModelLoaded = true
                    UserDefaults.standard.set(model.id, forKey: "defaultModel")
                }
            }
        }
    }
    
    func unloadModel() {
        guard let app = app else { return }
        bobrwhisper_model_unload(app)
        isModelLoaded = false
    }
    
    var modelsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".bobrwhisper/models")
    }

    func cleanupModelPath(_ model: CleanupModelDescriptor) -> URL {
        modelsDirectory.appendingPathComponent(model.localFilename)
    }

    func cleanupModelExists(_ model: CleanupModelDescriptor) -> Bool {
        installedCleanupModelIDs.contains(model.id) ||
            FileManager.default.fileExists(atPath: cleanupModelPath(model).path)
    }

    func refreshCleanupModelInstallations() {
        installedCleanupModelIDs = Set(
            CleanupModelDescriptor.all.filter {
                FileManager.default.fileExists(atPath: cleanupModelPath($0).path)
            }.map(\.id)
        )
    }

    @discardableResult
    func selectCleanupModel(_ model: CleanupModelDescriptor) -> Bool {
        guard cleanupModelExists(model), !isRecording, let app else { return false }
        let path = cleanupModelPath(model).path
        let selected = path.withCString { bobrwhisper_llm_model_set_path(app, $0) }
        guard selected else {
            presentWarning("Could not switch cleanup models while transcription is active.")
            return false
        }
        selectedCleanupModelID = model.id
        UserDefaults.standard.set(model.id, forKey: "cleanupModelID")
        return true
    }

    func downloadCleanupModel(_ model: CleanupModelDescriptor) {
        guard !isDownloadingCleanupModel else { return }

        isDownloadingCleanupModel = true
        cleanupModelDownloadProgress = 0
        let destinationURL = cleanupModelPath(model)
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        cleanupDownloadSession = URLSession(
            configuration: .default,
            delegate: DownloadDelegate(appState: self, kind: .cleanup),
            delegateQueue: nil
        )
        cleanupDownloadTask = cleanupDownloadSession?.downloadTask(with: model.downloadURL) { [weak self] tempURL, response, error in
            guard let self else { return }
            let result = self.saveDownloadedModel(
                temporaryURL: tempURL,
                response: response,
                error: error,
                destinationURL: destinationURL
            )
            DispatchQueue.main.async {
                self.cleanupDownloadTask = nil
                self.cleanupDownloadSession?.finishTasksAndInvalidate()
                self.cleanupDownloadSession = nil
                self.isDownloadingCleanupModel = false

                switch result {
                case .success:
                    self.cleanupModelDownloadProgress = 1
                    self.installedCleanupModelIDs.insert(model.id)
                    _ = self.selectCleanupModel(model)
                case .failure(let error as URLError) where error.code == .cancelled:
                    self.cleanupModelDownloadProgress = 0
                case .failure(let error):
                    self.errorMessage = "Cleanup model download failed: \(error.localizedDescription)"
                    self.status = .error
                }
            }
        }
        cleanupDownloadTask?.resume()
    }

    func cancelCleanupModelDownload() {
        cleanupDownloadTask?.cancel()
        cleanupDownloadTask = nil
        cleanupDownloadSession?.invalidateAndCancel()
        cleanupDownloadSession = nil
        isDownloadingCleanupModel = false
        cleanupModelDownloadProgress = 0
    }
    
    func downloadModel(_ model: SpeechModelDescriptor) {
        guard !isDownloading else { return }
        guard let url = model.downloadURL else { return }
        
        isDownloading = true
        downloadProgress = 0
        
        let destinationURL = modelsDirectory.appendingPathComponent(model.localFilename)
        
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        
        // Store session to prevent deallocation
        downloadSession = URLSession(
            configuration: .default,
            delegate: DownloadDelegate(appState: self, kind: .speech),
            delegateQueue: nil
        )
        downloadTask = downloadSession?.downloadTask(with: url) { [weak self] tempURL, response, error in
            guard let self else { return }
            let result = self.saveDownloadedModel(
                temporaryURL: tempURL,
                response: response,
                error: error,
                destinationURL: destinationURL
            )
            DispatchQueue.main.async {
                self.downloadTask = nil
                self.downloadSession?.finishTasksAndInvalidate()
                self.downloadSession = nil
                self.isDownloading = false

                switch result {
                case .success:
                    self.downloadProgress = 1
                    self.selectedModelID = model.id
                    self.loadModel()
                case .failure(let error as URLError) where error.code == .cancelled:
                    self.downloadProgress = 0
                case .failure(let error):
                    self.errorMessage = "Download failed: \(error.localizedDescription)"
                    self.status = .error
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

    private func saveDownloadedModel(
        temporaryURL: URL?,
        response: URLResponse?,
        error: Error?,
        destinationURL: URL
    ) -> Result<Void, Error> {
        if let error { return .failure(error) }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            return .failure(ModelDownloadError.httpStatus(http.statusCode))
        }
        guard let temporaryURL else { return .failure(ModelDownloadError.emptyResponse) }

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }
    
    func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(latestTranscriptText, forType: .string)
    }
    
    func pasteToActiveApp() {
        copyToClipboard()

        // Auto-paste is opt-out via Settings, but ALSO requires Accessibility
        // permission. If either is missing we still copy (above) so the user
        // can paste manually — silent no-op otherwise would surprise users who
        // skipped Accessibility during onboarding.
        let autoPasteEnabled = (UserDefaults.standard.object(forKey: "autoPaste") as? Bool) ?? true
        guard autoPasteEnabled, AXIsProcessTrusted() else { return }

        // Simulate Cmd+V
        let source = CGEventSource(stateID: .hidSystemState)
        let vKeyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let vKeyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        
        vKeyDown?.flags = .maskCommand
        vKeyUp?.flags = .maskCommand
        
        vKeyDown?.post(tap: .cghidEventTap)
        vKeyUp?.post(tap: .cghidEventTap)
    }

    func clearTranscriptLog() {
        if let app = app {
            _ = bobrwhisper_log_clear(app)
        }
        transcriptLog.removeAll()
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
                text: entry.formattedText ?? entry.text,
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
    let formattedText: String?

    enum CodingKeys: String, CodingKey {
        case createdAtUnixMs = "created_at_unix_ms"
        case text
        case formattedText = "formatted_text"
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

struct CleanupModelDescriptor: Identifiable, Equatable {
    let id: String
    let displayName: String
    let localFilename: String
    let downloadURL: URL
    let sizeLabel: String
    let detail: String

    static let defaultID = "qwen2.5-0.5b"

    static let all: [CleanupModelDescriptor] = [
        .init(
            id: "qwen2.5-0.5b",
            displayName: "Qwen 2.5 0.5B",
            localFilename: "qwen2.5-0.5b-instruct-q4_k_m.gguf",
            downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf")!,
            sizeLabel: "~400 MB",
            detail: "Fastest (Recommended)"
        ),
        .init(
            id: "llama3.2-1b",
            displayName: "Llama 3.2 1B",
            localFilename: "llama-3.2-1b-q4_k_m.gguf",
            downloadURL: URL(string: "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf")!,
            sizeLabel: "~700 MB",
            detail: "Fast, good quality"
        ),
        .init(
            id: "qwen2.5-1.5b",
            displayName: "Qwen 2.5 1.5B",
            localFilename: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
            downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf")!,
            sizeLabel: "~1.1 GB",
            detail: "Balanced"
        ),
        .init(
            id: "llama3.2-3b",
            displayName: "Llama 3.2 3B",
            localFilename: "llama-3.2-3b-q4_k_m.gguf",
            downloadURL: URL(string: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf")!,
            sizeLabel: "~2.0 GB",
            detail: "Best quality, slowest"
        ),
    ]

    static func model(id: String) -> CleanupModelDescriptor? {
        all.first { $0.id == id }
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

private enum ModelDownloadKind {
    case speech
    case cleanup
}

private enum ModelDownloadError: LocalizedError {
    case emptyResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .emptyResponse: return "No file was received."
        case .httpStatus(let code): return "The server returned HTTP \(code)."
        }
    }
}

private class DownloadDelegate: NSObject, URLSessionDownloadDelegate, URLSessionDataDelegate {
    weak var appState: AppState?
    private let kind: ModelDownloadKind
    private var expectedBytes: Int64 = 0
    
    init(appState: AppState, kind: ModelDownloadKind) {
        self.appState = appState
        self.kind = kind
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
            switch self.kind {
            case .speech:
                self.appState?.downloadProgress = progress
            case .cleanup:
                self.appState?.cleanupModelDownloadProgress = progress
            }
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
}
