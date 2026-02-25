import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .environmentObject(appState)
            
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
        .frame(width: 500, height: 350)
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("autoPaste") private var autoPaste = true
    @AppStorage("hotkeyCombo") private var hotkeyCombo = "option+space"
    
    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
            }
            
            Section("Behavior") {
                Toggle("Auto-paste after transcription", isOn: $autoPaste)
                
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
    }
}

struct ModelsSettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("defaultModel") private var defaultModelKey: String = ""
    
    private var defaultModel: ModelSize? {
        ModelSize.fromStorageKey(defaultModelKey)
    }
    
    private func modelStatus(_ size: ModelSize) -> String {
        if appState.modelExists(size) {
            if defaultModel == size {
                return "Downloaded (Default)"
            }
            return "Downloaded"
        } else {
            return "Not downloaded"
        }
    }
    
    var body: some View {
        Form {
            Section("Whisper Model") {
                ForEach(ModelSize.allCases) { size in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(size.rawValue)
                            Text(modelStatus(size))
                                .font(.caption)
                                .foregroundColor(appState.modelExists(size) ? .green : .secondary)
                        }
                        
                        Spacer()
                        
                        if appState.modelExists(size) {
                            if appState.selectedWhisperModel == size && appState.isModelLoaded {
                                Button("Loaded") {}
                                    .disabled(true)
                                    .buttonStyle(.borderedProminent)
                            } else {
                                Button("Load") {
                                    appState.selectedWhisperModel = size
                                    appState.loadModel()
                                }
                                .buttonStyle(.bordered)
                            }
                        } else {
                            Button("Download") {
                                appState.selectedWhisperModel = size
                                appState.downloadModel(size)
                            }
                            .disabled(appState.isDownloading)
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 2)
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
    }
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
}
