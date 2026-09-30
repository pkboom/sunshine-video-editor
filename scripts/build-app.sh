#!/bin/bash
# Builds dist/Sunshine.app (arm64, ad-hoc signed, non-sandboxed).
#   scripts/build-app.sh          build the .app
#   scripts/build-app.sh --zip    also write dist/Sunshine.zip for sharing
# Run scripts/fetch-helpers.sh first so Helpers/ is populated.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${SUNSHINE_BUILD_SCRATCH:-$ROOT/.build-app}"
DIST="$ROOT/dist"
APP="$DIST/Sunshine.app"
HELPERS=(yt-dlp deno ffmpeg)

ZIP=0
for arg in "$@"; do
    case "$arg" in
        --zip) ZIP=1 ;;
        *) echo "usage: $0 [--zip]" >&2; exit 2 ;;
    esac
done

echo "==> verifying Helpers/ against scripts/helpers.lock"
"$ROOT/scripts/fetch-helpers.sh" --check

echo "==> swift build (release, arm64)"
swift build --package-path "$ROOT" --scratch-path "$SCRATCH" -c release --arch arm64 --product Sunshine
BIN="$(swift build --package-path "$ROOT" --scratch-path "$SCRATCH" -c release --arch arm64 --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN/Sunshine" "$APP/Contents/MacOS/Sunshine"
chmod 755 "$APP/Contents/MacOS/Sunshine"

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
fi

# SwiftPM resource bundles (if any target declares resources).
shopt -s nullglob
for bundle in "$BIN"/*.bundle; do
    cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob

for h in "${HELPERS[@]}"; do
    cp "$ROOT/Helpers/$h" "$APP/Contents/Helpers/$h"
    chmod 755 "$APP/Contents/Helpers/$h"
done
# Contents/Helpers may hold only code (codesign treats every file there as
# nested code), so the ffmpeg license ships in Contents/Resources.
cp "$ROOT/Helpers/ffmpeg.LICENSE.txt" "$APP/Contents/Resources/ffmpeg.LICENSE.txt"
chmod 644 "$APP/Contents/Resources/ffmpeg.LICENSE.txt"
xattr -cr "$APP"

echo "==> ad-hoc signing (helpers first, then the app)"
for h in "${HELPERS[@]}"; do
    codesign --force --sign - "$APP/Contents/Helpers/$h"
done
codesign --force --sign - "$APP"

if [[ "$ZIP" == 1 ]]; then
    echo "==> zipping"
    rm -f "$DIST/Sunshine.zip"
    ditto -c -k --keepParent "$APP" "$DIST/Sunshine.zip"
    echo "wrote $DIST/Sunshine.zip ($(du -h "$DIST/Sunshine.zip" | cut -f1))"
fi

echo "built $APP ($(du -sh "$APP" | cut -f1))"
