import AppKit
import SwiftUI
import Carbon.HIToolbox
import BobrWhisperKit

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let appState = AppState()
    private var hotkeyMonitor: Any?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize Zig core
        let result = bobrwhisper_init()
        guard result == 0 else {
            fatalError("Failed to initialize BobrWhisper core")
        }
        
        // Create app with runtime config
        appState.createApp()
        
        // Register global hotkey (Fn key or custom)
        setupHotkey()
        
        // Request accessibility permissions if needed
        requestAccessibilityPermissions()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = hotkeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        appState.destroyApp()
        bobrwhisper_deinit()
    }
    
    private func setupHotkey() {
        // Global event monitor for Fn key (or configurable hotkey)
        hotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
    }
    
    private func handleFlagsChanged(_ event: NSEvent) {
        // Get the configured hotkey combo
        let hotkeyCombo = UserDefaults.standard.string(forKey: "hotkeyCombo") ?? "fn+option"
        
        let flags = event.modifierFlags
        
        let keyPressed: Bool
        switch hotkeyCombo {
        case "fn+option+cmd":
            keyPressed = flags.contains(.function) && flags.contains(.option) && flags.contains(.command)
        case "fn+cmd":
            keyPressed = flags.contains(.function) && flags.contains(.command)
        case "option+cmd":
            keyPressed = flags.contains(.option) && flags.contains(.command)
        case "control+option":
            keyPressed = flags.contains(.control) && flags.contains(.option)
        case "fn+option":
            keyPressed = flags.contains(.function) && flags.contains(.option)
        default: // "fn+option" as default
            keyPressed = flags.contains(.function) && flags.contains(.option)
        }
        
        if keyPressed && !appState.isRecording {
            print("Starting recording...")
            appState.startRecording()
        } else if !keyPressed && appState.isRecording {
            print("Stopping recording and transcribing...")
            appState.stopRecording()
        }
    }
    
    private func requestAccessibilityPermissions() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options)
        
        if !trusted {
            print("Accessibility permissions required for global hotkey")
        }
    }
}
