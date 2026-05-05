import SwiftUI
import BobrWhisperKit

@main
struct BobrWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup("BobrWhisper", id: "dashboard") {
            MainWindowView()
                .environmentObject(appDelegate.appState)
                .environmentObject(appDelegate.permissions)
        }

        Settings {
            SettingsView()
                .environmentObject(appDelegate.appState)
                .environmentObject(appDelegate.permissions)
        }
        
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appDelegate.appState)
                .environmentObject(appDelegate.permissions)
        } label: {
            // The label is the always-alive part of the MenuBarExtra scene —
            // it's instantiated on launch and kept alive for the app lifetime.
            // Mounting `DashboardOpener` as an overlay here gives us a SwiftUI
            // surface with `\.openWindow` that AppDelegate can drive via
            // NotificationCenter, without depending on the menu actually
            // being opened by the user.
            Image(systemName: appDelegate.appState.statusIcon)
                .overlay(DashboardOpener().allowsHitTesting(false))
        }
    }
}

/// SwiftUI bridge that AppKit code reaches via NotificationCenter to programmatically
/// open the dashboard `WindowGroup`. Mounted as a `.background` modifier in any
/// always-alive view (the menubar content) — its sole job is to translate the
/// `.bobrWhisperOpenDashboard` notification into a call on `\.openWindow`,
/// which is the only supported way to open a SwiftUI window scene.
struct DashboardOpener: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .bobrWhisperOpenDashboard)) { _ in
                openWindow(id: "dashboard")
            }
    }
}
