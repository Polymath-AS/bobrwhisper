import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    private static let logTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
    
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
            
            // Activity log
            if !appState.transcriptLog.isEmpty {
                HStack {
                    Text("Activity Log")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()
                
                    Button("Clear") {
                        appState.clearTranscriptLog()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                }
                .padding(.horizontal)

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(appState.transcriptLog) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(Self.logTimestampFormatter.string(from: entry.createdAt))
                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                    .foregroundColor(.secondary)

                                Text(entry.text)
                                    .font(.caption)
                                    .foregroundColor(.primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)

                            if entry.id != appState.transcriptLog.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .frame(maxHeight: 180)

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
            Button("Open Dashboard") {
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            }
            .padding(.horizontal)

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
        .frame(width: 320)
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
