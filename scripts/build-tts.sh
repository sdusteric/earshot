#!/bin/bash
# Builds the Kokoro helper (tts/) and installs it in ~/.config/earshot/kokoro.
# Setup runs it, and speak.sh runs it in the background after an update.
# On failure it prints one line and exits 1. After a new build it stops the
# running server, so the next line starts the new one.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST=${EARSHOT_KOKORO_DIR:-$HOME/.config/earshot/kokoro}
BUILD=$HOME/.config/earshot/kokoro-build   # SwiftPM's folder, reused by rebuilds
fail() { echo "$*"; exit 1; }
[ "$(uname -m)" = arm64 ] || fail "Kokoro needs a Mac with Apple Silicon."
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 15 ] || fail "Kokoro needs macOS 15 or later."
command -v swift >/dev/null || fail "swift not found. Install the Command Line Tools: xcode-select --install"
mkdir -p "$HOME/.config/earshot"
swift build -c release --package-path "$ROOT/tts" --scratch-path "$BUILD" > "$BUILD.log" 2>&1 \
  || fail "Couldn't build the Kokoro helper. Details: $BUILD.log"
bin=$(swift build -c release --package-path "$ROOT/tts" --scratch-path "$BUILD" --show-bin-path)
rm -rf "$DEST.new"; mkdir -p "$DEST.new"
cp "$bin/earshot-tts" "$DEST.new/"
# What it was built from, so an update that only rewrites files is not a change.
cat "$ROOT/tts/Package.swift" "$ROOT/tts/Package.resolved" "$ROOT/tts/Sources/earshot-tts/main.swift" | md5 -q > "$DEST.new/source.md5"
# FluidAudio's resource bundle sits next to the binary.
for b in "$bin"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$DEST.new/"; done
rm -rf "$DEST.old"; [ -d "$DEST" ] && mv "$DEST" "$DEST.old"; mv "$DEST.new" "$DEST"; rm -rf "$DEST.old"
pkill -f "$DEST/earshot-tts serve" || true
echo "Built the Kokoro helper."
