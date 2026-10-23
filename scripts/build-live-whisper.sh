#!/bin/bash
# No downloads: exact local whisper.cpp headers/runtime used by the bundled CLI.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${JUSTWISPER_WHISPER_PREFIX:-/opt/homebrew/Cellar/whisper.cpp/1.9.4}"
if [[ "$(basename "$PREFIX")" != 1.9.4 || ! -f "$PREFIX/include/whisper.h" ]]; then
    printf 'Live Whisper requires installed whisper.cpp 1.9.4 headers and libraries.\n' >&2; exit 1
fi
GGML_PREFIX="${JUSTWISPER_GGML_PREFIX:-/opt/homebrew/Cellar/ggml/0.24.0}"
if [[ "$(basename "$GGML_PREFIX")" != 0.24.0 || ! -f "$GGML_PREFIX/include/ggml.h" ]]; then
    printf 'Live Whisper requires the paired ggml 0.24.0 headers and libraries.\n' >&2; exit 1
fi
mkdir -p "$PROJECT_ROOT/.build/live-whisper"
xcrun clang++ -std=c++17 -O2 -mmacosx-version-min=14.0 -I"$PREFIX/include" -I"$GGML_PREFIX/include" \
  "$PROJECT_ROOT/native/live-whisper.cpp" -L"$PREFIX/lib" -L"$GGML_PREFIX/lib" -lwhisper -lggml \
  -Wl,-rpath,"$PREFIX/lib" -o "$PROJECT_ROOT/.build/live-whisper/justwisper-live-native"
printf '%s\n' "$PROJECT_ROOT/.build/live-whisper/justwisper-live-native"
