# BobrWhisper

100% local, privacy-first voice-to-text. A subscription-free alternative to SuperWhisper and Wispr Flow.

## Features

- **100% Local** - No cloud, no data collection, no subscriptions
- **Whisper STT** - OpenAI Whisper via whisper.cpp for accurate transcription
- **AI Formatting** - Optional LLM polish via llama.cpp (also local)
- **100+ Languages** - Full Whisper language support
- **Universal Paste** - Auto-paste to any app
- **Customizable** - Personal dictionary, modes, hotkeys

## Architecture

```
┌─────────────────────────────────────────┐
│           Swift macOS App               │
│  (MenuBar UI, Settings, Hotkey)         │
└─────────────────┬───────────────────────┘
                  │ C ABI / FFI
┌─────────────────▼───────────────────────┐
│         Zig Core (libbobrwhisper)       │
│  ┌─────────┐ ┌─────────┐ ┌───────────┐  │
│  │ Audio   │ │ Whisper │ │ llama.cpp │  │
│  │ Capture │→│  STT    │→│ Formatter │  │
│  └─────────┘ └─────────┘ └───────────┘  │
└─────────────────────────────────────────┘
```

## Requirements

- macOS 13+ (Apple Silicon recommended)
- Zig 0.15.0+
- Xcode 15+

## Quick Start

```bash
# Clone
git clone https://github.com/uzaaft/bobrwhisper
cd bobrwhisper

# Build Zig library + CLI
zig build

# Test CLI
./zig-out/bin/bobrwhisper-cli help
./zig-out/bin/bobrwhisper-cli models      # Show model download URLs
./zig-out/bin/bobrwhisper-cli languages   # Show supported languages
```

## Code Signing Builds

By default, Zig-driven Xcode builds keep iOS signing disabled for fast local iteration.

Enable signing explicitly for release/distribution builds:

```bash
# Signed iOS build (Team ID required)
zig build ios -Doptimize=Release -Dxcode-sign=true -Dapple-team-id=FCWK5WR45W

# Signed macOS build (uses Team ID override; identity optional)
zig build macos -Doptimize=Release -Dxcode-sign=true -Dapple-team-id=FCWK5WR45W

# Optional explicit identity override (Developer ID example)
zig build macos -Doptimize=Release -Dxcode-sign=true \
  -Dapple-team-id=FCWK5WR45W \
  -Dcode-sign-identity="Developer ID Application: Your Name (FCWK5WR45W)"
```

If `-Dxcode-sign=true` is set without `-Dapple-team-id`, the build fails fast with a clear error.

## Model Setup

### Whisper Models

Download a Whisper model to `~/.bobrwhisper/models/`:

```bash
mkdir -p ~/.bobrwhisper/models
cd ~/.bobrwhisper/models

# Tiny (75 MB) - fastest, lower accuracy
curl -LO https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin

# Small (466 MB) - good balance
curl -LO https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin

# Large (3.1 GB) - best accuracy
curl -LO https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin
```

### LLM for Formatting (Optional)

Download a GGUF model to `~/.bobrwhisper/models/`:

```bash
# Llama 3.2 1B (700 MB) - recommended
curl -L -o ~/.bobrwhisper/models/llama-3.2-1b-q4_k_m.gguf \
  https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf

# Or Qwen 2.5 0.5B (400 MB) - faster, smaller
curl -L -o ~/.bobrwhisper/models/qwen2.5-0.5b-q4_k_m.gguf \
  https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf
```

## Usage

1. Launch BobrWhisper (menubar app)
2. Hold **Fn** key and speak
3. Release to transcribe
4. Text is auto-pasted to active app

## Privacy

- **Zero network calls** - Everything runs locally
- **No telemetry** or usage tracking
- **All processing on-device**
- Audio never leaves your machine

## Comparison

| Feature | SuperWhisper | Wispr Flow | BobrWhisper |
|---------|-------------|------------|-------------|
| Price | $249 lifetime | $15/mo | **Free** |
| Open Source | ❌ | ❌ | ✅ |
| STT Location | Local | Cloud | **Local** |
| LLM Location | Cloud | Cloud | **Local** |
| Data Training | No | Opt-out | **Never** |

## Project Structure

```
bobrwhisper/
├── build.zig           # Zig build configuration
├── build.zig.zon       # Dependencies
├── include/
│   ├── bobrwhisper.h   # C API header
│   └── module.modulemap
├── src/
│   ├── main.zig        # C API exports
│   ├── c_api.zig       # C type definitions
│   ├── App.zig         # Main application
│   ├── Transcriber.zig # Whisper integration
│   ├── audio/
│   │   └── AudioCapture.zig
│   └── build/           # Build helpers (whisper.cpp, llama.cpp)
└── macos/
    └── BobrWhisper/
        ├── App.swift
        ├── AppDelegate.swift
        ├── AppState.swift
        └── Views/
            ├── MenuBarView.swift
            └── SettingsView.swift
```

## License

Business Source License 1.1 (BSL). See `LICENSE` for details.
