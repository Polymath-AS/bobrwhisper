import Foundation

enum KeyboardSharedState {
    static let appGroupID = "group.com.bobrwhisper.shared"

    private static let transcriptKey = "keyboard.transcript"
    private static let statusKey = "keyboard.status"
    private static let isRecordingKey = "keyboard.isRecording"
    private static let isModelLoadedKey = "keyboard.isModelLoaded"
    private static let selectedModelFilenameKey = "keyboard.selectedModelFilename"

    private static func userDefaults() -> UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    static func modelsDirectory() -> URL {
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return container.appendingPathComponent("models", isDirectory: true)
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models")
    }

    static func writeTranscript(_ text: String) {
        userDefaults()?.set(text, forKey: transcriptKey)
    }

    static func readTranscript() -> String? {
        userDefaults()?.string(forKey: transcriptKey)
    }

    static func writeStatusRaw(_ value: Int) {
        userDefaults()?.set(value, forKey: statusKey)
    }

    static func readStatusRaw() -> Int? {
        userDefaults()?.object(forKey: statusKey) as? Int
    }

    static func writeIsRecording(_ value: Bool) {
        userDefaults()?.set(value, forKey: isRecordingKey)
    }

    static func readIsRecording() -> Bool? {
        userDefaults()?.object(forKey: isRecordingKey) as? Bool
    }

    static func writeIsModelLoaded(_ value: Bool) {
        userDefaults()?.set(value, forKey: isModelLoadedKey)
    }

    static func readIsModelLoaded() -> Bool? {
        userDefaults()?.object(forKey: isModelLoadedKey) as? Bool
    }

    static func writeSelectedModelFilename(_ filename: String?) {
        guard let defaults = userDefaults() else {
            return
        }
        if let filename = filename {
            defaults.set(filename, forKey: selectedModelFilenameKey)
        } else {
            defaults.removeObject(forKey: selectedModelFilenameKey)
        }
    }

    static func readSelectedModelFilename() -> String? {
        userDefaults()?.string(forKey: selectedModelFilenameKey)
    }
}
