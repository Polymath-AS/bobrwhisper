import SwiftUI
import BobrWhisperKit

@main
struct BobrWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup("BobrWhisper", id: "dashboard") {
            MainWindowView()
                .environmentObject(appDelegate.appState)
        }

        Settings {
            SettingsView()
                .environmentObject(appDelegate.appState)
        }
        
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appDelegate.appState)
        } label: {
            Image(systemName: appDelegate.appState.statusIcon)
        }
    }
}
