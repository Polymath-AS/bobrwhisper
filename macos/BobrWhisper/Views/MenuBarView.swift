import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var permissions: PermissionsCoordinator
    @Environment(\.openSettings) private var openSettings
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

            // Non-fatal advisories (stuck mic, Bluetooth mic, ...). Auto-clears
            // via AppState; tapping dismisses immediately.
            if let warning = appState.warningMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.yellow.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.horizontal, 8)
                .onTapGesture { appState.dismissWarning() }
            }

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
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",", modifiers: .command)
            .padding(.horizontal)

            // Permission warning + re-run hook. Yellow strip mirrors the
            // warning-banner pattern established for non-fatal advisories.
            if !permissions.micGranted || !permissions.accessibilityGranted {
                permissionStatusRow
            }

            Button("Re-run Onboarding...") {
                (NSApp.delegate as? AppDelegate)?.relaunchOnboarding()
            }
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

    /// Compact status strip listing every non-granted permission. Yellow accent
    /// matches the existing warning banner so users associate "yellow stripe in
    /// the menu" with "something needs attention but isn't broken".
    private var permissionStatusRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !permissions.micGranted {
                permissionLine(name: "Microphone", missing: true, mandatory: true)
            }
            if !permissions.accessibilityGranted {
                permissionLine(name: "Accessibility", missing: true, mandatory: false)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, 8)
    }

    private func permissionLine(name: String, missing: Bool, mandatory: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.caption)
            Text("\(name) permission \(mandatory ? "required" : "not granted")")
                .font(.caption)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview {
    MenuBarView()
        .environmentObject(AppState())
        .environmentObject(PermissionsCoordinator())
}
