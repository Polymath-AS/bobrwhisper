#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_ROOT/pkgs/whisper-build-ios"
SRC_DIR="/tmp/whisper-cpp-ios"

if [ ! -d "$SRC_DIR" ]; then
    git clone --depth 1 https://github.com/ggerganov/whisper.cpp "$SRC_DIR"
fi

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

cmake "$SRC_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON \
    -DGGML_ACCELERATE=ON \
    -DWHISPER_BUILD_EXAMPLES=OFF \
    -DWHISPER_BUILD_TESTS=OFF

make -j$(sysctl -n hw.ncpu)

mkdir -p "$PROJECT_ROOT/pkgs/whisper-src-ios"
cp -r "$SRC_DIR/include" "$PROJECT_ROOT/pkgs/whisper-src-ios/"
cp -r "$SRC_DIR/ggml/include" "$PROJECT_ROOT/pkgs/whisper-src-ios/ggml-include"
