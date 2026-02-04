import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                modelSection
                transcriptionSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private var modelSection: some View {
        Section {
            ForEach(ModelSize.allCases) { size in
                ModelRow(size: size)
                    .environmentObject(appState)
            }
        } header: {
            Text("Whisper Model")
        } footer: {
            Text("Larger models are more accurate but slower and use more memory. Models are stored locally on your device.")
        }
    }
    
    private var transcriptionSection: some View {
        Section {
            Picker("Tone", selection: $appState.tone) {
                ForEach(Tone.allCases) { tone in
                    Label(tone.rawValue, systemImage: tone.icon)
                        .tag(tone)
                }
            }
            
            Toggle("Remove Filler Words", isOn: $appState.removeFillerWords)
            Toggle("Auto-Punctuate", isOn: $appState.autoPunctuate)
        } header: {
            Text("Transcription")
        } footer: {
            Text("These settings affect how the transcribed text is processed.")
        }
    }
    
    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                Spacer()
                Text("0.1.0")
                    .foregroundColor(.secondary)
            }
            
            NavigationLink {
                AboutView()
            } label: {
                Text("About BobrWhisper")
            }
            
            Link(destination: URL(string: "https://github.com/uzaaft/bobrwhisper")!) {
                HStack {
                    Text("GitHub")
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("About")
        }
    }
}

struct ModelRow: View {
    let size: ModelSize
    @EnvironmentObject var appState: AppState
    
    private var isDownloaded: Bool {
        appState.modelExists(size)
    }
    
    private var isSelected: Bool {
        appState.selectedModel == size && appState.isModelLoaded
    }
    
    private var isDownloading: Bool {
        appState.isDownloading && appState.selectedModel == size
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(size.rawValue)
                            .font(.headline)
                        
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                    }
                    
                    Text(size.sizeDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                modelButton
            }
            
            if isDownloading {
                ProgressView(value: appState.downloadProgress)
                    .progressViewStyle(.linear)
                
                HStack {
                    Text("\(Int(appState.downloadProgress * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Button("Cancel") {
                        appState.cancelDownload()
                    }
                    .font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    @ViewBuilder
    private var modelButton: some View {
        if isDownloading {
            ProgressView()
                .progressViewStyle(.circular)
        } else if !isDownloaded {
            Button("Download") {
                appState.selectedModel = size
                KeyboardSharedState.writeSelectedModelFilename(size.filename)
                appState.downloadModel(size)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        } else if isSelected {
            Button("Unload") {
                appState.unloadModel()
                KeyboardSharedState.writeSelectedModelFilename(nil)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else {
            Button("Load") {
                appState.selectedModel = size
                KeyboardSharedState.writeSelectedModelFilename(size.filename)
                appState.loadModel()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.accentColor)
                    
                    Text("BobrWhisper")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Text("v0.1.0")
                        .foregroundColor(.secondary)
                }
                .padding(.top, 40)
                
                Text("100% local, privacy-first voice-to-text")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                
                Divider()
                    .padding(.horizontal, 40)
                
                VStack(alignment: .leading, spacing: 16) {
                    FeatureRow(icon: "lock.shield.fill", title: "Private by Design", description: "All processing happens on-device. Your voice never leaves your phone.")
                    
                    FeatureRow(icon: "cpu.fill", title: "Powered by Whisper", description: "Uses OpenAI's Whisper model via whisper.cpp for fast, accurate transcription.")
                    
                    FeatureRow(icon: "globe", title: "100+ Languages", description: "Supports transcription in over 100 languages with auto-detection.")
                    
                    FeatureRow(icon: "bolt.fill", title: "Metal Accelerated", description: "Leverages Apple's Metal GPU framework for maximum performance.")
                }
                .padding(.horizontal)
                
                Spacer(minLength: 40)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
