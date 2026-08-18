import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var permissions: PermissionsCoordinator
    
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .environmentObject(appState)
                .environmentObject(permissions)
            
            ModelsSettingsView()
                .tabItem {
                    Label("Models", systemImage: "cpu")
                }
                .environmentObject(appState)
            
            AboutView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 500, height: 420)
    }
}

/// Inline permission row used in the General settings tab. Mirrors the pill
/// styling of `MainWindowView.statusPill` so settings feels visually
/// consistent with the dashboard.
struct PermissionStatusRow: View {
    let title: String
    let subtitle: String
    let state: PermissionState
    let mandatory: Bool
    let onAction: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    statusPill
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if state != .granted {
                Button(actionLabel, action: onAction)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusPill: some View {
        let (label, color): (String, Color) = {
            switch state {
            case .granted: return ("Granted", .green)
            case .denied: return (mandatory ? "Required" : "Not granted", mandatory ? .orange : .yellow)
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

    private var actionLabel: String {
        switch state {
        case .granted: return "Granted"
        case .notDetermined: return "Grant"
        case .denied: return "Open Settings"
        }
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var permissions: PermissionsCoordinator
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("autoPaste") private var autoPaste = true
    @AppStorage("hotkeyCombo") private var hotkeyCombo = "option+space"
    
    var body: some View {
        Form {
            Section("Permissions") {
                PermissionStatusRow(
                    title: "Microphone",
                    subtitle: "Required for recording.",
                    state: permissions.microphone,
                    mandatory: true,
                    onAction: {
                        switch permissions.microphone {
                        case .notDetermined: permissions.requestMicrophone { _ in }
                        case .denied: permissions.openMicrophoneSettings()
                        case .granted: break
                        }
                    }
                )

                PermissionStatusRow(
                    title: "Accessibility",
                    subtitle: "Required for auto-paste only.",
                    state: permissions.accessibility,
                    mandatory: false,
                    onAction: { permissions.openAccessibilitySettings() }
                )

                Button("Re-run Onboarding...") {
                    (NSApp.delegate as? AppDelegate)?.relaunchOnboarding()
                }
            }

            Section("App Microphone") {
                Picker("Record from", selection: $appState.selectedInputDeviceID) {
                    Text("Follow system default").tag("")
                    ForEach(appState.inputDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .disabled(appState.isRecording)
                Text("BobrWhisper records from this microphone without changing the system input device. The selection applies to the next recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
            }
            
            Section("Behavior") {
                Toggle("Auto-paste after transcription", isOn: $autoPaste)
                    .disabled(!permissions.accessibilityGranted)
                if !permissions.accessibilityGranted {
                    Text("Auto-paste needs Accessibility permission.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Picker("Tone", selection: $appState.tone) {
                    ForEach(Tone.allCases) { tone in
                        Text(tone.rawValue).tag(tone)
                    }
                }
            }
            
            Section("Hotkey") {
                Picker("Activation combo", selection: $hotkeyCombo) {
                    Text("Option (⌥) + Space").tag("option+space")
                    Text("Fn + Option (⌥)").tag("fn+option")
                    Text("Fn + Option (⌥) + Cmd (⌘)").tag("fn+option+cmd")
                    Text("Fn + Cmd (⌘)").tag("fn+cmd")
                    Text("Option (⌥) + Cmd (⌘)").tag("option+cmd")
                    Text("Control (⌃) + Option (⌥)").tag("control+option")
                }
                Text("Hold the keys to record, release to transcribe")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            appState.refreshInputDevices()
        }
    }
}

struct ModelsSettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("defaultModel") private var defaultModelKey: String = ""

    /// Per-group variant override. Lets the user pick "English" on the Tiny
    /// row without that choice leaking into other size groups. Keyed by the
    /// group id (id with `.en` stripped). Empty until the user opens a
    /// dropdown, at which point we remember their choice for the session.
    @State private var groupSelections: [String: String] = [:]

    private var defaultModelID: String {
        resolveLegacyStoredModelID(defaultModelKey)
    }
    
    private func modelStatus(_ model: SpeechModelDescriptor) -> String {
        if appState.modelExists(model) {
            if defaultModelID == model.id {
                return "Downloaded (Default)"
            }
            return "Downloaded"
        } else {
            return "Not downloaded"
        }
    }
    
    var body: some View {
        Form {
            Section("Speech Models") {
                ForEach(modelGroups) { group in
                    modelRow(group: group)
                }
                
                if appState.isDownloading {
                    HStack {
                        ProgressView(value: appState.downloadProgress)
                            .progressViewStyle(.linear)
                        
                        Button("Cancel") {
                            appState.cancelDownload()
                        }
                        .buttonStyle(.borderless)
                    }
                }
                
                Text("Larger models are more accurate but slower. The last loaded model becomes the default and auto-loads on startup.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Writing Cleanup") {
                ForEach(CleanupModelDescriptor.all) { model in
                    cleanupModelRow(model)
                }

                if appState.isDownloadingCleanupModel {
                    HStack {
                        ProgressView(value: appState.cleanupModelDownloadProgress)
                            .progressViewStyle(.linear)

                        Button("Cancel") {
                            appState.cancelCleanupModelDownload()
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Text("Optional and entirely on-device. A cleanup model improves punctuation and wording after transcription; without one, BobrWhisper keeps using deterministic cleanup.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section("Model Location") {
                Text(appState.modelsDirectory.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                
                Button("Open in Finder") {
                    NSWorkspace.shared.open(appState.modelsDirectory)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            appState.refreshCleanupModelInstallations()
        }
    }

    // MARK: - Grouped row rendering

    /// Group key = the model id with any trailing `.en` removed. The
    /// multilingual variant is always listed first so the picker defaults to
    /// "Multilingual" before the user touches it.
    private var modelGroups: [ModelSizeGroup] {
        var keyed: [String: [SpeechModelDescriptor]] = [:]
        var order: [String] = []
        for model in appState.availableModels {
            let key = groupKey(for: model)
            if keyed[key] == nil { order.append(key) }
            keyed[key, default: []].append(model)
        }
        return order.compactMap { key in
            guard var variants = keyed[key], !variants.isEmpty else { return nil }
            // Multilingual (no .en) before English-only.
            variants.sort { lhs, rhs in
                !lhs.isEnglishOnly && rhs.isEnglishOnly
            }
            // Strip the disambiguating " English" word so the row shows the
            // common base name. The size annotation in parens stays.
            let baseName = variants[0].displayName
                .replacingOccurrences(of: " English", with: "")
            return ModelSizeGroup(id: key, baseDisplayName: baseName, variants: variants)
        }
    }

    private func groupKey(for model: SpeechModelDescriptor) -> String {
        model.isEnglishOnly ? String(model.id.dropLast(3)) : model.id
    }

    /// The variant currently shown for this row. Resolution order:
    /// 1. explicit user choice in this session
    /// 2. the globally-selected model, if it belongs to this group
    /// 3. the persisted default model, if it belongs to this group
    /// 4. multilingual fallback (first entry)
    private func currentVariant(for group: ModelSizeGroup) -> SpeechModelDescriptor {
        if let chosen = groupSelections[group.id],
           let v = group.variants.first(where: { $0.id == chosen }) {
            return v
        }
        if let v = group.variants.first(where: { $0.id == appState.selectedModelID }) {
            return v
        }
        if let v = group.variants.first(where: { $0.id == defaultModelID }) {
            return v
        }
        return group.variants[0]
    }

    private func variantBinding(for group: ModelSizeGroup) -> Binding<String> {
        Binding(
            get: { currentVariant(for: group).id },
            set: { groupSelections[group.id] = $0 }
        )
    }

    @ViewBuilder
    private func modelRow(group: ModelSizeGroup) -> some View {
        let current = currentVariant(for: group)

        HStack {
            VStack(alignment: .leading) {
                Text(group.baseDisplayName)
                Text(modelStatus(current))
                    .font(.caption)
                    .foregroundColor(appState.modelExists(current) ? .green : .secondary)
            }

            Spacer()

            if group.variants.count > 1 {
                Picker("", selection: variantBinding(for: group)) {
                    ForEach(group.variants) { variant in
                        Text(variant.isEnglishOnly ? "English" : "Multilingual")
                            .tag(variant.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 130)
            }

            if appState.modelExists(current) {
                if appState.selectedModelID == current.id && appState.isModelLoaded {
                    Button("Loaded") {}
                        .disabled(true)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Load") {
                        appState.selectedModelID = current.id
                        appState.loadModel()
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Button("Download") {
                    appState.selectedModelID = current.id
                    appState.downloadModel(current)
                }
                .disabled(appState.isDownloading)
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func cleanupModelRow(_ model: CleanupModelDescriptor) -> some View {
        let installed = appState.cleanupModelExists(model)
        let selected = installed && appState.selectedCleanupModelID == model.id

        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                Text("\(model.detail) • \(model.sizeLabel)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if installed {
                    Text(selected ? "Downloaded (Active)" : "Downloaded")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }

            Spacer()

            if selected {
                Button("Active") {}
                    .disabled(true)
                    .buttonStyle(.borderedProminent)
            } else if installed {
                Button("Use") {
                    appState.selectCleanupModel(model)
                }
                .disabled(appState.isRecording)
                .buttonStyle(.bordered)
            } else {
                Button("Download") {
                    appState.downloadCleanupModel(model)
                }
                .disabled(appState.isDownloadingCleanupModel)
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 2)
    }
}

/// One row in the Models settings list. May represent a single multilingual
/// model OR a (multilingual, English-only) pair selectable via a dropdown.
private struct ModelSizeGroup: Identifiable {
    let id: String
    let baseDisplayName: String
    let variants: [SpeechModelDescriptor]
}

extension SpeechModelDescriptor {
    /// True for models trained on English audio only (`.en` suffix in the id).
    /// These can transcribe but cannot do language detection or translation.
    var isEnglishOnly: Bool { id.hasSuffix(".en") }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)
            
            Text("BobrWhisper")
                .font(.title)
                .fontWeight(.bold)
            
            Text("v0.1.0")
                .foregroundColor(.secondary)
            
            Text("100% local, privacy-first voice-to-text")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Divider()
                .padding(.horizontal, 40)
            
            VStack(alignment: .leading, spacing: 4) {
                FeatureRow(icon: "lock.shield", text: "No cloud, no subscriptions")
                FeatureRow(icon: "cpu", text: "Powered by Whisper.cpp")
                FeatureRow(icon: "sparkles", text: "AI formatting via llama.cpp")
                FeatureRow(icon: "globe", text: "100+ languages")
            }
            
            Spacer()
            
            Link("GitHub", destination: URL(string: "https://github.com/uzaaft/bobrwhisper")!)
                .font(.caption)
        }
        .padding()
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundColor(.accentColor)
            Text(text)
                .font(.caption)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
        .environmentObject(PermissionsCoordinator())
}
