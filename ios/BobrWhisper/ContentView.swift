import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingSettings = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    statusSection
                    
                    if !appState.lastTranscript.isEmpty {
                        transcriptSection
                    }
                    
                    if !appState.isModelLoaded {
                        modelPrompt
                    }
                    
                    Spacer(minLength: 100)
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) {
                recordButton
            }
            .navigationTitle("BobrWhisper")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
                    .environmentObject(appState)
            }
        }
        .onAppear {
            appState.createApp()
        }
    }
    
    private var statusSection: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color(appState.statusColor).opacity(0.15))
                    .frame(width: 120, height: 120)
                
                Circle()
                    .stroke(Color(appState.statusColor), lineWidth: 3)
                    .frame(width: 120, height: 120)
                
                Image(systemName: appState.statusIcon)
                    .font(.system(size: 48))
                    .foregroundColor(Color(appState.statusColor))
            }
            
            Text(appState.statusText)
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .padding(.top, 20)
    }
    
    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transcript")
                    .font(.headline)
                
                Spacer()
                
                Button {
                    appState.clearTranscript()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
            
            Text(appState.lastTranscript)
                .font(.body)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemGray6))
                .cornerRadius(12)
                .textSelection(.enabled)
            
            HStack(spacing: 12) {
                Button {
                    appState.copyToClipboard()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                
                ShareLink(item: appState.lastTranscript) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }
    
    private var modelPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "cpu")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            
            Text("No Model Loaded")
                .font(.headline)
            
            Text("Download and load a Whisper model to start transcribing")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button("Open Settings") {
                showingSettings = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(16)
    }
    
    private var recordButton: some View {
        VStack(spacing: 8) {
            Button {
                if appState.isRecording {
                    appState.stopRecording()
                } else {
                    appState.startRecording()
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(appState.isRecording ? Color.red : Color.accentColor)
                        .frame(width: 80, height: 80)
                        .shadow(color: (appState.isRecording ? Color.red : Color.accentColor).opacity(0.4), radius: 10)
                    
                    if appState.isRecording {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white)
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.white)
                    }
                }
            }
            .disabled(!appState.isModelLoaded || appState.status == .transcribing)
            .opacity(appState.isModelLoaded ? 1 : 0.5)
            
            Text(appState.isRecording ? "Tap to stop" : "Tap to record")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.bottom, 20)
        .background(
            LinearGradient(
                colors: [Color(.systemBackground).opacity(0), Color(.systemBackground)],
                startPoint: .top,
                endPoint: .center
            )
        )
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
