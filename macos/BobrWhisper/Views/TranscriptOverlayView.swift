import AppKit
import Combine
import SwiftUI

// Notch Overlay View

struct NotchOverlayView: View {
    @ObservedObject var appState: AppState
    var onStopRecording: () -> Void
    var onDismiss: () -> Void

    @State private var dotOpacity: Double = 1.0
    @State private var elapsedSeconds: Int = 0

    private let durationTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var isExpanded: Bool {
        !appState.lastTranscript.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            compactBar

            if isExpanded {
                separator
                transcriptText
            }
        }
        .frame(width: isExpanded ? 300 : 180)
        .background(pillBackground)
        .overlay(pillBorder)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onTapGesture {
            if appState.isRecording {
                onStopRecording()
            } else if appState.status == .ready {
                onDismiss()
            }
        }
        .onReceive(durationTimer) { _ in
            if appState.isRecording {
                elapsedSeconds += 1
            }
        }
        .onChange(of: appState.isRecording) { recording in
            if recording { elapsedSeconds = 0 }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: isExpanded)
    }

    // MARK: - Compact Bar

    private var compactBar: some View {
        HStack(spacing: 8) {
            statusDot

            if appState.status == .recording {
                AudioVisualizerBars(audioLevel: appState.audioLevel)
            }

            Spacer(minLength: 4)

            Text(statusLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))

            if appState.status == .recording {
                Text(formatDuration(elapsedSeconds))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 8, height: 8)
            .opacity(appState.status == .recording ? dotOpacity : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    dotOpacity = 0.3
                }
            }
    }

    private var dotColor: Color {
        switch appState.status {
        case .recording: return .red
        case .transcribing, .formatting: return .cyan
        case .ready: return .green
        case .error: return .orange
        case .idle: return .gray
        }
    }

    private var statusLabel: String {
        switch appState.status {
        case .idle: return "Ready"
        case .recording: return "Listening"
        case .transcribing: return "Transcribing…"
        case .formatting: return "Formatting…"
        case .ready: return "Done"
        case .error: return "Error"
        }
    }

    // MARK: - Expanded Content

    private var separator: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .frame(height: 0.5)
            .padding(.horizontal, 10)
    }

    private var transcriptText: some View {
        Text(appState.lastTranscript)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(3)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Pill Shape

    private var cornerRadius: CGFloat {
        isExpanded ? 18 : 22
    }

    private var pillBackground: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.black.opacity(0.9))
    }

    private var pillBorder: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
    }

    private func formatDuration(_ totalSeconds: Int) -> String {
        String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

// MARK: - Audio Visualizer Bars

struct AudioVisualizerBars: View {
    let audioLevel: Float
    private let barCount = 4
    private let barScales: [CGFloat] = [0.5, 1.0, 0.7, 0.85]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                AudioBar(level: audioLevel, scale: barScales[index])
            }
        }
        .frame(height: 14)
    }
}

private struct AudioBar: View {
    let level: Float
    let scale: CGFloat

    private var height: CGFloat {
        let normalised = CGFloat(min(level / 0.15, 1.0))
        return max(3, normalised * 14 * scale)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(.white.opacity(0.5))
            .frame(width: 2, height: height)
            .animation(.interpolatingSpring(stiffness: 300, damping: 20), value: level)
    }
}

// MARK: - Overlay Panel Controller

class OverlayPanelController {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<NotchOverlayView>?
    private unowned let appState: AppState
    private var dismissWorkItem: DispatchWorkItem?
    private var stateObserver: AnyCancellable?
    private var shouldBeVisible = false

    init(appState: AppState) {
        self.appState = appState
    }

    func show() {
        shouldBeVisible = true
        dismissWorkItem?.cancel()
        dismissWorkItem = nil

        if panel == nil {
            createPanel()
        }

        updatePanelFrame()
        panel?.alphaValue = 0
        panel?.orderFront(nil)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.panel?.animator().alphaValue = 1
        }
    }

    func hide() {
        shouldBeVisible = false
        dismissWorkItem?.cancel()
        dismissWorkItem = nil

        guard let panel = panel else { return }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }) { [weak self] in
            guard let self = self, !self.shouldBeVisible else { return }
            panel.orderOut(nil)
        }
    }

    func scheduleAutoDismiss() {
        dismissWorkItem?.cancel()

        let wordCount = max(1, appState.lastTranscript.split(separator: " ").count)
        let delayMs = min(5000, max(1500, wordCount * 400))

        let work = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: work)
    }

    // MARK: - Private

    private func createPanel() {
        let view = NotchOverlayView(
            appState: appState,
            onStopRecording: { [weak self] in
                self?.appState.stopRecording()
            },
            onDismiss: { [weak self] in
                self?.hide()
            }
        )

        let hosting = NSHostingView(rootView: view)
        self.hostingView = hosting

        let initialSize = hosting.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        panel.isMovableByWindowBackground = false

        self.panel = panel
        positionPanel()

        stateObserver = appState.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self?.updatePanelFrame()
            }
        }
    }

    private func updatePanelFrame() {
        guard let hosting = hostingView, let panel = panel else { return }
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        guard let screen = NSScreen.main else { return }

        let topY = screen.visibleFrame.maxY
        let x = screen.frame.midX - size.width / 2
        let y = topY - size.height - 4

        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func positionPanel() {
        guard let panel = panel, let screen = NSScreen.main else { return }

        let panelSize = panel.frame.size
        let topY = screen.visibleFrame.maxY
        let x = screen.frame.midX - panelSize.width / 2
        let y = topY - panelSize.height - 4

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
