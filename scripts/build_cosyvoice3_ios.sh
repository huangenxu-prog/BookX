#!/usr/bin/env bash
# Experimental CosyVoice3 iOS static-library build. Run on macOS with Xcode.
# This does NOT modify the BookX app or claim an integrated speech engine.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${COSYVOICE_WORKDIR:-$ROOT/.cosyvoice3-build}"
UPSTREAM="https://github.com/tetherto/qvac-fabric-speech.cpp.git"
command -v xcrun >/dev/null || { echo "Xcode command-line tools required" >&2; exit 1; }
command -v cmake >/dev/null || { echo "CMake required" >&2; exit 1; }
command -v git >/dev/null || { echo "Git required" >&2; exit 1; }
mkdir -p "$WORK"
if [[ ! -d "$WORK/source/.git" ]]; then
  git clone --depth 1 "$UPSTREAM" "$WORK/source"
fi
echo "Upstream commit: $(git -C "$WORK/source" rev-parse HEAD)"
bash "$WORK/source/engines/tts/scripts/setup-ggml.sh"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
cmake -S "$WORK/source/engines/tts" -B "$WORK/ios-arm64" \
  -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT="$SDK" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=18.0 \
  -DCMAKE_BUILD_TYPE=Release \
  -DTTS_CPP_USE_SYSTEM_GGML=OFF \
  -DTTS_CPP_BUILD_SHARED=OFF \
  -DTTS_CPP_BUILD_EXECUTABLES=OFF \
  -DTTS_CPP_BUILD_TESTS=OFF \
  -DTTS_CPP_COREML=OFF
cmake --build "$WORK/ios-arm64" --config Release --target tts-cpp --parallel 4
echo "Experimental static library build finished. App bridging and runtime verification remain outstanding."
