import SwiftUI
import BobrWhisperKit

@main
struct BobrWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
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
