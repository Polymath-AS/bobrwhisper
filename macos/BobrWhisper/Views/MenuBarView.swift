import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status
            HStack {
                Image(systemName: appState.statusIcon)
                    .foregroundColor(statusColor)
                Text(appState.statusText)
                    .font(.headline)
            }
            .padding(.horizontal)
            .padding(.top, 8)
            
            Divider()
            
            // Last transcript preview
            if !appState.lastTranscript.isEmpty {
                Text(appState.lastTranscript)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                    .lineLimit(5)
                    .textSelection(.enabled)
                
                Button("Copy to Clipboard") {
                    appState.copyToClipboard()
                }
                .padding(.horizontal)
                
                Divider()
            }
            
            // Quick settings
            Picker("Tone", selection: $appState.tone) {
                ForEach(Tone.allCases) { tone in
                    Text(tone.rawValue).tag(tone)
                }
            }
            .pickerStyle(.menu)
            .padding(.horizontal)
            
            Divider()
            
            // Actions
            Button("Settings...") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            .keyboardShortcut(",", modifiers: .command)
            .padding(.horizontal)
            
            Button("Quit BobrWhisper") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .frame(width: 280)
    }
    
    private var statusColor: Color {
        switch appState.status {
        case .idle: return .secondary
        case .recording: return .red
        case .transcribing, .formatting: return .blue
        case .ready: return .green
        case .error: return .orange
        }
    }
}

#Preview {
    MenuBarView()
        .environmentObject(AppState())
}
