#!/usr/bin/env zsh
set -euo pipefail

ROOT="${0:A:h}"
BUILD="$ROOT/build"
APP="$BUILD/LiveWallpaper.app"

# run main build for swifttt executableeee
"$ROOT/build.sh"

echo "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp "$BUILD/livewallpaper" "$APP/Contents/MacOS/livewallpaper"

echo "Copying plists..."

cp resources/Info.plist "$APP/Contents/Info.plist"

# ad-hoc sign so gatekeeper lets the locally-built bundle run
# later add a --release?
codesign --force --sign - "$APP"

echo "Compiled!! -  $APP"
echo "open \"$APP\" to launch the app"
