import AppKit
import SwiftUI
import Carbon.HIToolbox
import BobrWhisperKit

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let appState = AppState()
    let permissions = PermissionsCoordinator()
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

        // Onboarding lives inside the dashboard window now. If permissions
        // need attention on launch, flip the coordinator into onboarding mode
        // and ask SwiftUI to open the dashboard so the user actually sees it.
        if permissions.shouldAutoShowOnLaunch {
            permissions.beginOnboarding()
            DispatchQueue.main.async { [weak self] in
                self?.openDashboardWindow()
            }
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = hotkeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        appState.destroyApp()
        bobrwhisper_deinit()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
    
    /// Open (or focus) the dashboard `WindowGroup`. Used on launch when
    /// onboarding needs to run, and from the menubar's "Open Dashboard" entry.
    /// Walks the existing window list first to focus an already-open dashboard
    /// instead of leaning on SwiftUI to create a duplicate.
    func openDashboardWindow() {
        permissions.refresh()
        NSApp.activate(ignoringOtherApps: true)

        for window in NSApplication.shared.windows
        where window.identifier?.rawValue == "dashboard" {
            window.makeKeyAndOrderFront(nil)
            return
        }

        // SwiftUI registers the WindowGroup with id "dashboard" via a
        // discoverable URL handler under the hood. The standard
        // `NSWorkspace.OpenConfiguration` route does not work for in-process
        // scenes, so post a notification that the SwiftUI commands listener
        // (in `App.swift`) acts on.
        NotificationCenter.default.post(
            name: .bobrWhisperOpenDashboard,
            object: nil
        )
    }

    /// Reset the "I've completed onboarding" flag and re-show the dashboard
    /// in onboarding mode. Bound to the menubar / settings re-run actions.
    func relaunchOnboarding() {
        permissions.resetOnboarding()
        permissions.beginOnboarding()
        openDashboardWindow()
    }
}

extension Notification.Name {
    /// Posted by `AppDelegate.openDashboardWindow` when a SwiftUI surface needs
    /// to call `openWindow(id: "dashboard")` on its behalf. Subscribed to from
    /// the App scene, which is the only place with access to the
    /// `\.openWindow` environment.
    static let bobrWhisperOpenDashboard = Notification.Name("bobrWhisperOpenDashboard")
}
