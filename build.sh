#!/usr/bin/env zsh
set -euo pipefail

ROOT="${0:A:h}"
BUILD="$ROOT/build"
mkdir -p "$BUILD"

echo "Compiling Swift..."

# this auto chmods
swiftc \
  -O \
  -framework AppKit \
  -framework AVFoundation \
  -o "$BUILD/livewallpaper" \
  "$ROOT"/src/*.swift

echo "Compiled! check $BUILD/livewallpaper"
