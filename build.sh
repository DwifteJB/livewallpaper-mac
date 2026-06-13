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

# bundle ffmpeg next to the loose binary (for webm/mkv/etc that avfoundation can't read)
"$ROOT/fetch-ffmpeg.sh"
cp "$ROOT/vendor/ffmpeg" "$BUILD/ffmpeg"

echo "Compiled! check $BUILD/livewallpaper"
