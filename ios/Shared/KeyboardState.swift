import Foundation

enum KeyboardStatus: Int {
    case idle = 0
    case recording = 1
    case transcribing = 2
    case formatting = 3
    case ready = 4
    case error = 5
}

struct KeyboardStateSnapshot {
    let isRecording: Bool
    let isModelLoaded: Bool
    let selectedModelID: String?
    let transcript: String
    let status: KeyboardStatus?

    init() {
        isRecording = KeyboardSharedState.readIsRecording() ?? false
        isModelLoaded = KeyboardSharedState.readIsModelLoaded() ?? false
        selectedModelID = KeyboardSharedState.readSelectedModelID()
        transcript = KeyboardSharedState.readTranscript() ?? ""
        if let raw = KeyboardSharedState.readStatusRaw() {
            status = KeyboardStatus(rawValue: raw)
        } else {
            status = nil
        }
    }
}
