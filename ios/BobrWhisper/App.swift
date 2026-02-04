import SwiftUI
import BobrWhisperKit

@main
struct BobrWhisperApp: App {
    @StateObject private var appState = AppState()
    
    init() {
#if targetEnvironment(simulator)
        setenv("GGML_METAL_DISABLE", "1", 1)
#endif
        let result = bobrwhisper_init()
        guard result == 0 else {
            fatalError("Failed to initialize BobrWhisper core")
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .onOpenURL { url in
                    handleOpenURL(url)
                }
        }
    }

    private func handleOpenURL(_ url: URL) {
        guard url.scheme == "bobrwhisper" else { return }
        guard url.host == "record" else { return }
        if appState.isRecording {
            appState.stopRecording()
        } else {
            appState.startRecording()
        }
    }
}
