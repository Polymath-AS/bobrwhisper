import AppKit
import SwiftUI

/// First-run onboarding pane. Rendered inline inside the dashboard window —
/// the user sees this BEFORE the transcript table on first launch (or any
/// later launch where mandatory permissions regressed). Walks through
/// Microphone (mandatory) and Accessibility (auto-paste only), with a
/// "skip accessibility" path that completes onboarding with auto-paste
/// disabled.
///
/// Visual style mirrors `MainWindowView`: top header with status pill,
/// rounded-rect cards on `controlBackgroundColor`, same yellow/green/orange
/// semantic palette established for warnings.
struct OnboardingView: View {
    @EnvironmentObject var permissions: PermissionsCoordinator
    @AppStorage("autoPaste") private var autoPaste: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    micCard
                    accessibilityCard
                    note
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))

            Divider()

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { permissions.refresh() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome to BobrWhisper")
                    .font(.system(size: 18, weight: .semibold))
                Text("Grant the permissions below to enable voice transcription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            overallStatusPill
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var overallStatusPill: some View {
        let (text, color, icon): (String, Color, String) = {
            if !permissions.micGranted {
                return ("Setup required", .yellow, "exclamationmark.triangle.fill")
            }
            if !permissions.accessibilityGranted {
                return ("Mic ready", .green, "checkmark.circle.fill")
            }
            return ("All set", .green, "checkmark.seal.fill")
        }()

        return HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.14))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(color.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .foregroundStyle(color)
    }

    // MARK: - Permission cards

    private var micCard: some View {
        permissionCard(
            title: "Microphone",
            subtitle: "Required for voice recording. BobrWhisper cannot capture audio without this permission.",
            icon: "mic.fill",
            state: permissions.microphone,
            mandatory: true,
            primaryLabel: micPrimaryLabel,
            primaryAction: micPrimaryAction
        )
    }

    private var micPrimaryLabel: String {
        switch permissions.microphone {
        case .granted: return "Granted"
        case .notDetermined: return "Grant Microphone"
        case .denied: return "Open Microphone Settings"
        }
    }

    private func micPrimaryAction() {
        switch permissions.microphone {
        case .notDetermined:
            permissions.requestMicrophone { _ in }
        case .denied:
            permissions.openMicrophoneSettings()
        case .granted:
            break
        }
    }

    private var accessibilityCard: some View {
        permissionCard(
            title: "Accessibility",
            subtitle: "Required only for auto-paste after transcription. Without it, transcripts still appear in the overlay and log — you just have to paste them yourself.",
            icon: "hand.tap.fill",
            state: permissions.accessibility,
            mandatory: false,
            primaryLabel: permissions.accessibilityGranted ? "Granted" : "Open Accessibility Settings",
            primaryAction: { permissions.openAccessibilitySettings() }
        )
    }

    private var note: some View {
        Text("After flipping a toggle in System Settings, return here — the status updates automatically.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    @ViewBuilder
    private func permissionCard(
        title: String,
        subtitle: String,
        icon: String,
        state: PermissionState,
        mandatory: Bool,
        primaryLabel: String,
        primaryAction: @escaping () -> Void
    ) -> some View {
        let accent = accentColor(for: state, mandatory: mandatory)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(.tint)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                        statePill(for: state, mandatory: mandatory)
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }

            HStack {
                Spacer()
                if state == .granted {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                } else {
                    Button(primaryLabel, action: primaryAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(accent.opacity(0.35), lineWidth: 1)
        )
    }

    private func statePill(for state: PermissionState, mandatory: Bool) -> some View {
        let (label, color): (String, Color) = {
            switch state {
            case .granted: return ("Granted", .green)
            case .denied: return (mandatory ? "Required" : "Optional", mandatory ? .orange : .yellow)
            case .notDetermined: return ("Not requested", .yellow)
            }
        }()

        return Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14))
            .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 0.5))
            .clipShape(Capsule())
    }

    private func accentColor(for state: PermissionState, mandatory: Bool) -> Color {
        switch state {
        case .granted: return .green
        case .denied: return mandatory ? .orange : .yellow
        case .notDetermined: return .yellow
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            // Skip path disables auto-paste so the user isn't surprised by a
            // silent no-op every time they finish a recording.
            Button("Skip Accessibility") {
                autoPaste = false
                permissions.finishOnboarding()
            }
            .disabled(!permissions.micGranted || permissions.accessibilityGranted)

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }

            Button("Continue") {
                permissions.finishOnboarding()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!permissions.micGranted)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

#Preview {
    OnboardingView()
        .environmentObject(PermissionsCoordinator())
}
