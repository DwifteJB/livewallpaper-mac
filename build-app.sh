#!/usr/bin/env zsh
set -euo pipefail

ROOT="${0:A:h}"
BUILD="$ROOT/build"
APP="$BUILD/LiveWallpaper.app"

# run main build for swifttt executableeee
"$ROOT/build.sh"

echo "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILD/livewallpaper" "$APP/Contents/MacOS/livewallpaper"

# bundle ffmpeg
cp "$ROOT/vendor/ffmpeg" "$APP/Contents/Resources/ffmpeg"

echo "Copying plists..."

cp resources/Info.plist "$APP/Contents/Info.plist"

# sign the nested ffmpeg first, then the bundle, so gatekeeper lets the local build run
codesign --force --sign - "$APP/Contents/Resources/ffmpeg"
codesign --force --sign - "$APP"

echo "Compiled!! -  $APP"
echo "open \"$APP\" to launch the app"
