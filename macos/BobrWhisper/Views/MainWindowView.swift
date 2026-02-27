import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject var appState: AppState

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            dashboardHeader

            Divider()

            tableHeader

            Divider()

            if appState.transcriptLog.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(appState.transcriptLog.enumerated()), id: \.element.id) { index, entry in
                            tableRow(entry: entry, index: index)
                            Divider()
                        }
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .navigationTitle("BobrWhisper")
        .frame(minWidth: 940, minHeight: 620)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(appState.isRecording ? "Stop Recording" : "Start Recording") {
                    if appState.isRecording {
                        appState.stopRecording()
                    } else {
                        appState.startRecording()
                    }
                }

                Button("Copy Latest") {
                    appState.copyToClipboard()
                }
                .disabled(appState.transcriptLog.isEmpty)

                Button("Clear Log") {
                    appState.clearTranscriptLog()
                }
                .disabled(appState.transcriptLog.isEmpty)

                Button("Settings") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            }
        }
    }

    private var dashboardHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            statusPill
            metricPill(title: "Entries", value: "\(appState.transcriptLog.count)")
            metricPill(title: "Words", value: "\(totalWordCount)")

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Image(systemName: appState.statusIcon)
            Text(appState.statusText)
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(statusColor.opacity(0.14))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(statusColor.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func metricPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var tableHeader: some View {
        HStack(spacing: 12) {
            Text("Time")
                .frame(width: 90, alignment: .leading)

            Text("Words")
                .frame(width: 64, alignment: .leading)

            Text("Transcript")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func tableRow(entry: TranscriptLogEntry, index: Int) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(Self.timeFormatter.string(from: entry.createdAt))
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .frame(width: 90, alignment: .leading)

            Text("\(wordCount(entry.text))")
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)

            Text(entry.text)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(index.isMultiple(of: 2) ? Color.clear : Color(nsColor: .underPageBackgroundColor).opacity(0.35))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)

            Text("No log entries yet")
                .font(.headline)

            Text("Start and stop recording to build a timestamped transcription log.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var totalWordCount: Int {
        appState.transcriptLog.reduce(0) { partial, entry in
            partial + wordCount(entry.text)
        }
    }

    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    private var statusColor: Color {
        switch appState.status {
        case .idle: return .gray
        case .recording: return .red
        case .transcribing, .formatting: return .blue
        case .ready: return .green
        case .error: return .orange
        }
    }
}

#Preview {
    MainWindowView()
        .environmentObject(AppState())
}
