import AppKit
import Combine
import SwiftUI

// Notch Overlay View

struct NotchOverlayView: View {
    @ObservedObject var appState: AppState
    var onStopRecording: () -> Void
    var onDismiss: () -> Void

    @State private var elapsedSeconds: Int = 0
    @State private var audioDetected = false
    @State private var showTranscript = false

    private let durationTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var isExpanded: Bool {
        !appState.lastTranscript.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            compactBar
            separator
            transcriptText
        }
        .frame(width: isExpanded ? 300 : 180)
        .background(pillBackground)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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
            if recording { elapsedSeconds = 0; audioDetected = false }
        }
        .onChange(of: isExpanded) { expanded in
            if expanded {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(.timingCurve(0.65, 0, 0.35, 1, duration: 0.4)) {
                        showTranscript = true
                        audioDetected = true
                    }
                }
            } else {
                showTranscript = false
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.timingCurve(0.65, 0, 0.35, 1, duration: 0.5), value: isExpanded)
        .animation(.timingCurve(0.65, 0, 0.35, 1, duration: 0.4), value: showTranscript)
    }

    // MARK: - Compact Bar

    private var compactBar: some View {
        HStack(spacing: 8) {
            statusDot

            ZStack(alignment: .leading) {
                Text(statusLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .opacity(audioDetected ? 0 : 1)
                    .blur(radius: audioDetected ? 4 : 0)

                if appState.status == .recording {
                    AudioVisualizerBars(audioLevel: appState.audioLevel)
                        .opacity(audioDetected ? 0.7 : 0)
                        .blur(radius: audioDetected ? 0 : 4)
                }
            }

            Spacer(minLength: 4)

            if appState.status == .recording {
                Text(formatDuration(elapsedSeconds))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var statusDot: some View {
        let recording = appState.status == .recording
        return Circle()
            .fill(dotColor)
            .frame(width: 8, height: 8)
            .shadow(color: recording ? .red.opacity(0.9) : .clear, radius: recording ? 4 : 0)
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
        RoundedRectangle(cornerRadius: 1.5)
            .fill(.white.opacity(0.1))
            .frame(width: isExpanded ? nil : 0, height: isExpanded ? 1 : 0)
            .padding(.horizontal, isExpanded ? 10 : 0)
    }

    private var transcriptText: some View {
        AnimatedTranscriptView(text: appState.lastTranscript)
            .padding(.horizontal, 14)
            .padding(.bottom, showTranscript ? 10 : 0)
            .frame(maxHeight: showTranscript ? .none : 0)
            .clipped()
            .opacity(showTranscript ? 1 : 0)
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

// MARK: - Animated Transcript View

struct AnimatedTranscriptView: View {
    let text: String
    @State private var words: [Word] = []
    @State private var contentHeight: CGFloat = 0

    private let maxHeight: CGFloat = 66
    private var clampedHeight: CGFloat { min(contentHeight + 10, maxHeight) }
    private var isOverflowing: Bool { contentHeight + 10 > maxHeight }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                FlowLayout(spacing: 4) {
                    ForEach(words) { word in
                        WordView(word: word)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: HeightKey.self, value: geo.size.height)
                })
                Color.clear.frame(height: 1).id("bottom")
            }
            .frame(maxWidth: .infinity, maxHeight: clampedHeight, alignment: .topLeading)
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: isOverflowing ? 16 : 0)
                    Color.black
                }
            )
            .onPreferenceChange(HeightKey.self) { newHeight in
                withAnimation(.timingCurve(0.65, 0, 0.35, 1, duration: 0.35)) { contentHeight = newHeight }
            }
            .onChange(of: text) { newText in
                updateWords(from: newText)
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private func updateWords(from newText: String) {
        let incoming = newText.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let old = words
        words = incoming.enumerated().map { i, text in
            if i < old.count, old[i].text == text { return old[i] }
            return Word(text: text, isNew: i >= old.count)
        }
    }

    private struct WordView: View {
        let word: Word
        @State private var appeared = false

        var body: some View {
            Text(word.text)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(appeared ? 1 : 0))
                .blur(radius: appeared ? 0 : (word.isNew ? 3 : 0))
                .offset(y: appeared ? 0 : (word.isNew ? 2 : 0))
                .onAppear {
                    guard !appeared else { return }
                    withAnimation(word.isNew
                        ? .timingCurve(0.25, 0.1, 0.25, 1.0, duration: 0.45)
                        : .easeIn(duration: 0.2)
                    ) { appeared = true }
                }
        }
    }

    private struct Word: Identifiable {
        let id = UUID()
        let text: String
        let isNew: Bool
    }

    private struct HeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(in: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, offset) in layout(in: bounds.width, subviews: subviews).offsets.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y), proposal: .unspecified)
        }
    }

    private func layout(in maxWidth: CGFloat, subviews: Subviews) -> (size: CGSize, offsets: [CGPoint]) {
        var offsets: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > maxWidth, x > 0 {
                y += rowHeight + spacing
                x = 0; rowHeight = 0
            }
            offsets.append(CGPoint(x: x, y: y))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
        return (CGSize(width: maxWidth, height: y + rowHeight), offsets)
    }
}

// MARK: - Audio Visualizer Bars

struct AudioVisualizerBars: View {
    let audioLevel: Float
    private let barCount = 5
    // Center-out envelope: bar 2 (index 2) is center, edges are smallest
    private let centerScales: [CGFloat] = [0.45, 0.75, 1.0, 0.75, 0.45]
    private let phaseOffsets: [Double] = [0.0, 0.18, 0.09, 0.25, 0.13]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                AudioBar(level: audioLevel, scale: centerScales[index], phaseOffset: phaseOffsets[index])
            }
        }
        .frame(height: 14)
    }
}

private struct AudioBar: View {
    let level: Float
    let scale: CGFloat
    let phaseOffset: Double

    private var height: CGFloat {
        let normalised = CGFloat(min(level / 0.1, 1.0))
        return max(2, normalised * 14 * scale)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(.white.opacity(1.0))
            .frame(width: 2, height: height)
            .animation(.interpolatingSpring(stiffness: 150, damping: 14).delay(phaseOffset * 0.3), value: level)
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

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: CGSize(width: Self.panelWidth, height: Self.panelHeight)),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
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

    private static let panelWidth: CGFloat = 320
    private static let panelHeight: CGFloat = 140

    private func updatePanelFrame() {
        guard let panel = panel, let screen = NSScreen.main else { return }

        let topY = screen.visibleFrame.maxY
        let x = screen.frame.midX - Self.panelWidth / 2
        let y = topY - Self.panelHeight - 4

        panel.setFrame(NSRect(x: x, y: y, width: Self.panelWidth, height: Self.panelHeight), display: true)
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
