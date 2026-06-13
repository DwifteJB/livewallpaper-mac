#!/usr/bin/env zsh
set -euo pipefail

# grab ffmpeg

ROOT="${0:A:h}"
VENDOR="$ROOT/vendor"
OUT="$VENDOR/ffmpeg"

# gets this ver
TAG="b6.1.1"
BASE="https://github.com/eugeneware/ffmpeg-static/releases/download/$TAG"

if [[ -x "$OUT" ]]; then
  echo "ffmpeg already vendored: $OUT"
  exit 0
fi

mkdir -p "$VENDOR"

echo "Downloading ffmpeg $TAG"
curl -fL "$BASE/ffmpeg-darwin-arm64" -o "$VENDOR/ffmpeg-arm64"
curl -fL "$BASE/ffmpeg-darwin-x64"   -o "$VENDOR/ffmpeg-x64"

echo "Stitching universal binary..."
lipo -create "$VENDOR/ffmpeg-arm64" "$VENDOR/ffmpeg-x64" -output "$OUT"
rm -f "$VENDOR/ffmpeg-arm64" "$VENDOR/ffmpeg-x64"
chmod +x "$OUT"

# arm64 and x86_64 are not signed
codesign --force --sign - "$OUT"

echo "ffmpeg ready: $OUT"
