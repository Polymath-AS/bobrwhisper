# BobrWhisper

Local-first voice-to-text. Alternative to SuperWhisper/Wispr Flow.

## Commands

```bash
zig build              # Build library + CLI
zig build run          # Build and run macOS app
zig build run-cli      # Run CLI
zig build test         # Run tests
zig build xcframework  # Build XCFramework for macOS
zig build xcframework-ios  # Build XCFramework for iOS
zig build macos        # Build macOS app via Xcode
zig build ios          # Build iOS app via Xcode

./zig-out/bin/bobrwhisper-cli help
./zig-out/bin/bobrwhisper-cli live  # Live transcription mode
```

## Architecture

- **Zig core** (`src/`) - C ABI library consumed by Swift
- **Swift macOS app** (`macos/`) - Native macOS menubar app
- **Swift iOS app** (`ios/`) - Native iOS app with full feature parity
- **C header** (`include/bobrwhisper.h`) - FFI bridge
- **XCFrameworks**:
  - `macos/BobrWhisperKit.xcframework` - macOS arm64
  - `ios/BobrWhisperKit.xcframework` - iOS device + simulator
- **Build modules** (`src/build/`) - Zig build helpers for dependencies

## Key Files

- `src/main.zig` - C API exports
- `src/App.zig` - Core application state
- `src/Transcriber.zig` - Whisper.cpp wrapper
- `src/audio/AudioCapture.zig` - CoreAudio recording
- `src/cli.zig` - CLI tool with live transcription
- `src/build/whisper.zig` - Builds whisper.cpp from source
- `src/build/llama.zig` - Builds llama.cpp from source
- `macos/BobrWhisper/AppState.swift` - Swift↔Zig bridge
- `build.zig` - Build system with XCFramework support

## Dependencies

Dependencies are declared in `build.zig.zon` and built from source:

- **whisper.cpp** - Built from source via `src/build/whisper.zig`
  - Fetched from git, compiled with Zig's C/C++ toolchain
- **llama.cpp** - Built from source via `src/build/llama.zig`
  - Provides shared ggml with Metal and Accelerate backends
  - Whisper uses llama's ggml to avoid symbol conflicts

## Models

**Whisper models** are auto-downloaded on first use to `~/.bobrwhisper/models/`.

Manual download:
```bash
mkdir -p ~/.bobrwhisper/models
curl -L -o ~/.bobrwhisper/models/ggml-tiny.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin
```

**Silero VAD model** (~868KB) is bundled in the app resources for automatic silence detection.
- Skips silent segments before transcription for faster processing
- Downloaded via `scripts/download-vad-model.sh` during development
- Bundled in both macOS and iOS app bundles

## Status

- ✅ Zig build system with XCFramework (macOS)
- ✅ whisper.cpp built from source (no pre-built binaries)
- ✅ llama.cpp built from source (no pre-built binaries)
- ✅ Silero VAD for silence detection (bundled in app)
- ✅ C ABI header
- ✅ CLI tool with live transcription
- ✅ AudioCapture (CoreAudio)
- ✅ Swift macOS app builds and launches
- ⚠️ iOS XCFramework (Zig cross-compilation has libc++ issues, needs pre-built libs)

## Feature Parity (iOS ↔ macOS)

| Feature | macOS | iOS |
|---------|-------|-----|
| Recording | ✅ | ✅ |
| Transcription | ✅ | ✅ |
| Model Download | ✅ | ✅ |
| Model Selection | ✅ | ✅ |
| Tone Settings | ✅ | ✅ |
| Filler Word Removal | ✅ | ✅ |
| Auto-Punctuation | ✅ | ✅ |
| Copy to Clipboard | ✅ | ✅ |
| Share | ❌ | ✅ |
| Auto-Paste | ✅ | ❌ |
| llama.cpp Formatting | ✅ | ❌ |
| Menubar Integration | ✅ | ❌ |
| Hotkey Recording | ✅ | ❌ |
