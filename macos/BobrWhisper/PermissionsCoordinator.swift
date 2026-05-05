import AppKit
import ApplicationServices
import AVFoundation
import Combine
import Foundation

/// Tri-state for OS-granted privacy permissions.
///
/// `notDetermined` means the system has never prompted; this is the only state
/// from which `AVCaptureDevice.requestAccess` will trigger the OS prompt.
/// `denied` covers both user-denied and MDM-restricted; recovery in both cases
/// requires the user to flip the toggle in System Settings.
enum PermissionState: Equatable {
    case granted
    case denied
    case notDetermined
}

/// Tracks Microphone (mandatory) and Accessibility (auto-paste only) permissions.
///
/// macOS does not deliver a reliable signal when the user changes a TCC entry
/// in System Settings, so we re-poll on app activation and on a coarse fallback
/// timer. This coordinator deliberately knows nothing about the Zig core or the
/// `bobrwhisper_app_t` lifecycle; it is a pure SwiftUI/AppKit concern.
final class PermissionsCoordinator: ObservableObject {
    @Published private(set) var microphone: PermissionState = .notDetermined
    @Published private(set) var accessibility: PermissionState = .notDetermined

    private static let onboardingCompletedKey = "hasCompletedOnboarding"

    var hasCompletedOnboarding: Bool {
        UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey)
    }

    var micGranted: Bool { microphone == .granted }
    var accessibilityGranted: Bool { accessibility == .granted }

    /// True when the dashboard should render the onboarding flow instead of
    /// the transcript table. Mandatory permission missing OR the user has
    /// never completed the flow. Settings surfaces optional regression
    /// (accessibility only) inline rather than blocking the dashboard.
    @Published var isOnboardingActive: Bool = false

    /// Whether the dashboard should auto-show on launch (because onboarding
    /// needs to run). Independent of `isOnboardingActive` so we can decide
    /// "open the window AND show onboarding" in one step.
    var shouldAutoShowOnLaunch: Bool {
        if !micGranted { return true }
        return !hasCompletedOnboarding
    }

    func beginOnboarding() {
        isOnboardingActive = true
    }

    func finishOnboarding() {
        markOnboardingComplete()
        isOnboardingActive = false
    }

    private var pollTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var workspaceObserver: NSObjectProtocol?

    init() {
        refresh()
        startObserving()
    }

    deinit {
        stopObserving()
    }

    /// Re-read both permissions from the OS. Cheap; safe to call from a timer.
    func refresh() {
        let newMic: PermissionState
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: newMic = .granted
        case .denied, .restricted: newMic = .denied
        case .notDetermined: newMic = .notDetermined
        @unknown default: newMic = .notDetermined
        }

        let newAX: PermissionState = AXIsProcessTrusted() ? .granted : .denied

        if newMic != microphone { microphone = newMic }
        if newAX != accessibility { accessibility = newAX }
    }

    /// Triggers the system microphone prompt. Only effective in `notDetermined`;
    /// after a denial the user has to toggle it in System Settings, so callers
    /// should fall back to `openMicrophoneSettings()` in that case.
    func requestMicrophone(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                self?.refresh()
                completion(granted)
            }
        }
    }

    func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Accessibility cannot be prompted programmatically — Apple intentionally
    /// requires a manual toggle. We deep-link to the right pane instead.
    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func markOnboardingComplete() {
        UserDefaults.standard.set(true, forKey: Self.onboardingCompletedKey)
    }

    func resetOnboarding() {
        UserDefaults.standard.set(false, forKey: Self.onboardingCompletedKey)
    }

    // MARK: - Observation

    private func startObserving() {
        // App activation is the most common moment for the user to flip back
        // from System Settings. AppKit fires this even for our own app
        // returning from background.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }

        // Workspace activation catches the case where another app (e.g., System
        // Settings itself) becomes active and back without us regaining focus.
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }

        // TCC changes don't always fire a usable notification. A 2 s coarse
        // poll covers the gap; cost is negligible since `AXIsProcessTrusted`
        // and `AVCaptureDevice.authorizationStatus` are both in-process reads.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func stopObserving() {
        if let obs = activationObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
