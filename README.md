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

- macOS 15+ (Apple Silicon recommended)
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

## libwhisper

`libwhisper` is the UI-independent transcription core for C and Zig consumers.
It loads a caller-provided whisper.cpp model and accepts caller-provided 16 kHz
mono `float` PCM; it does not depend on Swift, audio capture, app settings, or
LLM formatting.

```bash
# Installs shared/static libraries, the C header, and pkg-config metadata.
zig build libwhisper -Doptimize=ReleaseFast

# Zig unit tests plus a C ABI smoke test linked against the static archive.
zig build test-libwhisper

# Reproducible Nix package (Debug and ReleaseSafe variants are also exposed).
nix build .#libwhisper
```

Installed outputs:

- `lib/libbobrwhisper.{so,dylib}` and `lib/libbobrwhisper.a`
- `include/libwhisper.h`
- `share/pkgconfig/bobrwhisper.pc`

The shared library needs nothing beyond libc and libm — Zig links libc++ into it
statically. Linking the **static** archive additionally requires libc++
(`pkg-config --static --libs bobrwhisper` reports `-lc++`); libstdc++ cannot
substitute, because the archive references `std::__1::` symbols from libc++'s
inline namespace.

The file is named `libbobrwhisper` because whisper.cpp installs its own
`libwhisper.so` with SONAME `libwhisper.so.0` and an unrelated ABI, so sharing
the name would make the two unco-installable. The API keeps the `libwhisper_`
prefix, which does not collide with whisper.cpp's `whisper_`.

```c
#include <libwhisper.h>

libwhisper_config_s config;
libwhisper_config_init(&config);
config.model_path = "/path/to/ggml-base.en.bin";

libwhisper_t *transcriber = NULL;
if (libwhisper_create(&config, &transcriber) != LIBWHISPER_SUCCESS) return 1;

libwhisper_string_s text;
if (libwhisper_transcribe(transcriber, samples, sample_count, NULL, &text) == LIBWHISPER_SUCCESS) {
    if (text.ptr != NULL) {   /* NULL means an empty transcript */
        printf("%s\n", text.ptr);
        libwhisper_string_free(text);
    }
}
libwhisper_destroy(transcriber);
```

`examples/c-smoke/main.c` is the executable version of that contract, and runs
as part of `zig build test-libwhisper`.

The flake exposes `libwhisper`, `libwhisper-debug`, `libwhisper-releasesafe`, and
`libwhisper-releasefast` on Darwin and Linux; `libwhisper` is an alias for the
ReleaseFast variant. `nix flake check` builds the library and runs its tests,
including the C ABI smoke test, inside the sandbox.

whisper.cpp and llama.cpp are lazy dependencies, so a plain `zig build` fetches
them on first use. The Nix build cannot reach the network, so it feeds Zig a
prebuilt package set via `--system`, described by `build.zig.zon.nix`. That file
is generated from `build.zig.zon` — regenerate it in the same commit as any
dependency change, using the `zon2nix` provided by the dev shell:

```bash
zon2nix --16 --nix=build.zig.zon.nix build.zig.zon
```

Because the Nix pins are derived rather than restated, they cannot drift from
`build.zig.zon`.

As a Zig package dependency, import the `bobrwhisper` module; it carries the
whisper.cpp bridge and its link dependencies, so no extra artifact wiring is
needed:

```zig
const bobrwhisper = b.dependency("bobrwhisper", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("bobrwhisper", bobrwhisper.module("bobrwhisper"));
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
