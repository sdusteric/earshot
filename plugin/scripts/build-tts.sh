#!/bin/bash
# Builds the Kokoro helper (tts/) and installs it in ~/.config/kobi/kokoro.
# Setup runs it, and speak.sh runs it in the background after an update.
# On failure it prints one line and exits 1. After a new build it stops the
# running server, so the next line starts the new one.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST=${KOBI_KOKORO_DIR:-$HOME/.config/kobi/kokoro}
BUILD=$HOME/.config/kobi/kokoro-build   # SwiftPM's folder, reused by rebuilds
fail() { echo "$*"; exit 1; }
# Not uname -m: a Rosetta terminal says x86_64 on an Apple Silicon Mac. From
# one, build again as arm64, so the helper is not an Intel build.
[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] || fail "Kokoro needs a Mac with Apple Silicon."
if [ "$(uname -m)" != arm64 ] && [ -z "${KOBI_ARM64:-}" ]; then
  KOBI_ARM64=1 exec arch -arm64 /bin/bash "$0" "$@"
fi
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 15 ] || fail "Kokoro needs macOS 15 or later."
# /usr/bin/swift exists even without the tools (it offers to install them), so
# ask xcode-select whether they are there.
xcode-select -p >/dev/null 2>&1 || fail "Kokoro needs the Command Line Tools. Install them: xcode-select --install"
# Already built from these sources: nothing to do. Setup and the background
# rebuild both check first, but either may have waited for the other.
hash=$(cat "$ROOT/tts/Package.swift" "$ROOT/tts/Package.resolved" "$ROOT/tts/Sources/kobi-tts/main.swift" | md5 -q)
if [ -x "$DEST/kobi-tts" ] && [ ! -e "$DEST/kobi-tts.stale" ] && [ "$(cat "$DEST/source.md5" 2>/dev/null)" = "$hash" ]; then
  echo "The Kokoro helper is up to date."
  exit 0
fi
mkdir -p "$HOME/.config/kobi"
swift build -c release --package-path "$ROOT/tts" --scratch-path "$BUILD" > "$BUILD.log" 2>&1 \
  || fail "Couldn't build the Kokoro helper. Details: $BUILD.log"
bin=$(swift build -c release --package-path "$ROOT/tts" --scratch-path "$BUILD" --show-bin-path)
rm -rf "$DEST.new"; mkdir -p "$DEST.new"
cp "$bin/kobi-tts" "$DEST.new/"
# What it was built from, so an update that only rewrites files is not a change.
echo "$hash" > "$DEST.new/source.md5"
# FluidAudio's resource bundle sits next to the binary.
for b in "$bin"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$DEST.new/"; done
rm -rf "$DEST.old"; [ -d "$DEST" ] && mv "$DEST" "$DEST.old"; mv "$DEST.new" "$DEST"; rm -rf "$DEST.old"
pkill -f "$DEST/kobi-tts serve" || true
echo "Built the Kokoro helper."
