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
        appState.overlayController = OverlayPanelController(appState: appState)
        
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
        hotkeyMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.flagsChanged, .keyDown, .keyUp]
        ) { [weak self] event in
            self?.handleHotkeyEvent(event)
        }
    }
    
    private func handleHotkeyEvent(_ event: NSEvent) {
        let hotkeyCombo = UserDefaults.standard.string(forKey: "hotkeyCombo") ?? "option+space"
        
        if hotkeyCombo == "option+space" {
            handleOptionSpace(event)
        } else if event.type == .flagsChanged {
            handleFlagsChanged(event, combo: hotkeyCombo)
        }
    }
    
    private func handleOptionSpace(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            if event.charactersIgnoringModifiers == " ", !event.isARepeat,
               event.modifierFlags.contains(.option), !appState.isRecording {
                appState.startRecording()
            }
        case .keyUp:
            if event.charactersIgnoringModifiers == " ", appState.isRecording {
                appState.stopRecording()
            }
        case .flagsChanged:
            if !event.modifierFlags.contains(.option), appState.isRecording {
                appState.stopRecording()
            }
        default:
            break
        }
    }
    
    private func handleFlagsChanged(_ event: NSEvent, combo: String) {
        let flags = event.modifierFlags
        
        let keyPressed: Bool
        switch combo {
        case "fn+option+cmd":
            keyPressed = flags.contains(.function) && flags.contains(.option) && flags.contains(.command)
        case "fn+cmd":
            keyPressed = flags.contains(.function) && flags.contains(.command)
        case "option+cmd":
            keyPressed = flags.contains(.option) && flags.contains(.command)
        case "control+option":
            keyPressed = flags.contains(.control) && flags.contains(.option)
        default:
            keyPressed = flags.contains(.function) && flags.contains(.option)
        }
        
        if keyPressed && !appState.isRecording {
            appState.startRecording()
        } else if !keyPressed && appState.isRecording {
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
