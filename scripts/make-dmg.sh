#!/bin/bash
# Packs an app bundle into a drag-to-Applications DMG with a background, fixed window and
# volume icon. Called by scripts/build-app.sh --dmg.
#   scripts/make-dmg.sh <Sunshine.app> <out.dmg> <scratch dir>
# Finder lays out the window via AppleScript, so the first run may ask to let your terminal
# control Finder.
set -euo pipefail

APP="$1"
OUT="$2"
WORK="$3/dmg"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VOL=Sunshine
# Must match scripts/dmg-background.swift.
WIN_W=640
WIN_H=400
TITLE_H=32 # bounds include the title bar; the background starts below it
ICON_Y=190
LEFT_X=170
RIGHT_X=470

rm -rf "$WORK"
mkdir -p "$WORK/stage/.background"

echo "    rendering background"
swift "$ROOT/scripts/dmg-background.swift" "$WORK/bg.png" 1
swift "$ROOT/scripts/dmg-background.swift" "$WORK/bg@2x.png" 2
tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$WORK/stage/.background/background.tiff" 2>/dev/null

ditto "$APP" "$WORK/stage/$VOL.app"
ln -s /Applications "$WORK/stage/Applications"

# A stale mount of the same name would take the volume path.
if [[ -d "/Volumes/$VOL" ]]; then
    hdiutil detach "/Volumes/$VOL" -force >/dev/null || true
fi

echo "    laying out window"
# Headroom so Finder can write .DS_Store; the final UDZO conversion drops the slack.
SIZE_MB=$(( $(du -sm "$WORK/stage" | cut -f1) + 20 ))
hdiutil create -volname "$VOL" -srcfolder "$WORK/stage" -fs HFS+ -format UDRW -size "${SIZE_MB}m" -ov "$WORK/rw.dmg" >/dev/null
DEVICE="$(hdiutil attach -readwrite -noverify -noautoopen "$WORK/rw.dmg" | awk '/Apple_HFS/ {print $1}')"
MNT="/Volumes/$VOL"
trap 'hdiutil detach "$DEVICE" -force >/dev/null 2>&1 || true' EXIT

osascript >/dev/null <<EOF
tell application "Finder"
    tell disk "$VOL"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set pathbar visible of container window to false
        set the bounds of container window to {200, 120, $((200 + WIN_W)), $((120 + WIN_H + TITLE_H))}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "$VOL.app" of container window to {$LEFT_X, $ICON_Y}
        set position of item "Applications" of container window to {$RIGHT_X, $ICON_Y}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF

# Let Finder finish writing .DS_Store before detaching.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -f "$MNT/.DS_Store" ]] && break
    sleep 1
done
# Volume icon goes in after the layout: Finder's layout pass deletes .VolumeIcon.icns and
# clears the custom-icon flag.
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$MNT/.VolumeIcon.icns"
    SetFile -a C "$MNT"
fi
sync
chmod -Rf go-w "$MNT" || true
hdiutil detach "$DEVICE" >/dev/null
trap - EXIT

rm -f "$OUT"
hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
rm -rf "$WORK"
