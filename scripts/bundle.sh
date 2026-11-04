#!/bin/sh
# Builds Yon.app (and Yon.dmg) with nothing but Command Line Tools. No Xcode, no Apple account.
# Usage: scripts/bundle.sh [--dmg]
set -eu
cd "$(dirname "$0")/.."

APP=dist/Yon.app
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ "${1:-}" = "--dev" ]; then
    # Debug build, host arch only, system rclone. Fast inner loop.
    swift build >/dev/null
    cp .build/debug/Yon "$APP/Contents/MacOS/Yon"
    cp Resources/Info.plist "$APP/Contents/"
    [ -f Resources/Yon.icns ] && cp Resources/Yon.icns "$APP/Contents/Resources/"
    codesign --force --sign - "$APP"
    echo "built $APP (dev)"
    exit 0
fi

for a in arm64 x86_64; do swift build -c release --arch "$a" >/dev/null; done
lipo -create -output "$APP/Contents/MacOS/Yon" .build/arm64-apple-macosx/release/Yon .build/x86_64-apple-macosx/release/Yon

cp Resources/Info.plist "$APP/Contents/"
[ -f Resources/Yon.icns ] && cp Resources/Yon.icns "$APP/Contents/Resources/"

# Bundle rclone (MIT) so users need nothing else. Universal binary from the official release zips.
RCLONE_VERSION=${RCLONE_VERSION:-$(curl -fsSL https://downloads.rclone.org/version.txt | sed 's/rclone //')}
tmp=$(mktemp -d)
for a in arm64 amd64; do
    curl -fsSL "https://downloads.rclone.org/$RCLONE_VERSION/rclone-$RCLONE_VERSION-osx-$a.zip" -o "$tmp/$a.zip"
    unzip -q "$tmp/$a.zip" -d "$tmp/$a"
done
lipo -create -output "$APP/Contents/Resources/rclone" "$tmp"/arm64/*/rclone "$tmp"/amd64/*/rclone
chmod +x "$APP/Contents/Resources/rclone"
rm -rf "$tmp"

codesign --force --deep --sign - "$APP"
echo "built $APP"

if [ "${1:-}" = "--dmg" ]; then
    ln -sfn /Applications dist/Applications
    hdiutil create -quiet -volname Yon -srcfolder dist -ov -format UDZO dist/Yon.dmg
    rm dist/Applications
    echo "built dist/Yon.dmg"
fi
