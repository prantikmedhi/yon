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
    cp "$(swift build --show-bin-path)/Yon" "$APP/Contents/MacOS/Yon"
    cp Resources/Info.plist "$APP/Contents/"
    [ -f Resources/Yon.icns ] && cp Resources/Yon.icns "$APP/Contents/Resources/"
    codesign --force --sign - "$APP"
    echo "built $APP (dev)"
    exit 0
fi

# ARCHS="arm64 x86_64" for a universal build (what .github/workflows/release.yml ships). The macOS 27 Command Line Tools no longer compile x86_64,
# so the default is Apple silicon only; build the Intel slice on a machine with an older SDK.
ARCHS=${ARCHS:-arm64}
bins=""
for a in $ARCHS; do
    swift build -c release --arch "$a" >/dev/null
    bin="$(swift build -c release --arch "$a" --show-bin-path)/Yon"
    cp "$bin" ".build/Yon-$a"
    bins="$bins .build/Yon-$a"
done
lipo -create -output "$APP/Contents/MacOS/Yon" $bins

cp Resources/Info.plist "$APP/Contents/"
[ -f Resources/Yon.icns ] && cp Resources/Yon.icns "$APP/Contents/Resources/"

# Own OAuth clients, from the environment so secrets never land in git.
P="$APP/Contents/Info.plist"
[ -n "${YON_GOOGLE_CLIENT_ID:-}" ] && plutil -replace YonOAuthClients.drive.id -string "$YON_GOOGLE_CLIENT_ID" "$P" && plutil -replace YonOAuthClients.drive.secret -string "${YON_GOOGLE_CLIENT_SECRET:-}" "$P"
[ -n "${YON_MS_CLIENT_ID:-}" ] && plutil -replace YonOAuthClients.onedrive.id -string "$YON_MS_CLIENT_ID" "$P" && plutil -replace YonOAuthClients.onedrive.secret -string "${YON_MS_CLIENT_SECRET:-}" "$P"

# Bundle rclone (MIT) so users need nothing else, from the official release zips.
RCLONE_VERSION=${RCLONE_VERSION:-$(curl -fsSL https://downloads.rclone.org/version.txt | sed 's/rclone //')}
tmp=$(mktemp -d)
rbins=""
for a in $ARCHS; do
    r=$([ "$a" = x86_64 ] && echo amd64 || echo arm64)
    curl -fsSL "https://downloads.rclone.org/$RCLONE_VERSION/rclone-$RCLONE_VERSION-osx-$r.zip" -o "$tmp/$r.zip"
    unzip -q "$tmp/$r.zip" -d "$tmp/$r"
    rbins="$rbins $tmp/$r/*/rclone"
done
lipo -create -output "$APP/Contents/Resources/rclone" $rbins
chmod +x "$APP/Contents/Resources/rclone"
rm -rf "$tmp"

codesign --force --deep --sign - "$APP"
echo "built $APP"

if [ "${1:-}" = "--dmg" ]; then
    ln -sfn /Applications dist/Applications
    # Explicit size: hdiutil under-sizes the image for the 85 MB rclone binary otherwise.
    hdiutil create -quiet -volname Yon -srcfolder dist -ov -format UDZO -size 200m dist/Yon.dmg
    rm dist/Applications
    echo "built dist/Yon.dmg"
fi
