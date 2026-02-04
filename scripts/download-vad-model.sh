#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESOURCES_DIR="$PROJECT_DIR/resources"

MODEL_URL="https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin"
MODEL_FILE="silero-v6.2.0.bin"

mkdir -p "$RESOURCES_DIR"

if [ -f "$RESOURCES_DIR/$MODEL_FILE" ]; then
    exit 0
fi

curl -L -o "$RESOURCES_DIR/$MODEL_FILE" "$MODEL_URL"
