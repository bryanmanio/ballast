#!/bin/sh
#
# Wraps an app in the drag-to-install disk image: the app on the left,
# Applications on the right, and a background telling you to drag one onto
# the other. Unsigned; release.sh signs and notarises what this produces.
#
#     ./scripts/make-dmg.sh path/to/Ballast.app dist/Ballast.dmg
#
# Finder is the only thing that writes a window layout macOS will honour, so
# this drives it over AppleScript, and the first run asks for permission to
# control Finder.

set -eu

[ $# -eq 2 ] || { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
APP=$1
DMG=$2
NAME=$(basename "$APP" .app)

die() { echo "error: $1" >&2; exit 1; }

[ -d "$APP" ] || die "no app at $APP"
# Finder addresses the volume by name, so a second one called the same would
# get the layout instead of ours.
[ -e "/Volumes/$NAME" ] && die "a volume called $NAME is already mounted; eject it first"

SCRIPTS=$(cd "$(dirname "$0")" && pwd)
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp/}ballast-dmg.XXXXXX")
MOUNT="/Volumes/$NAME"
cleanup() {
    [ -d "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet -force 2>/dev/null
    rm -rf "$SCRATCH"
}
trap cleanup EXIT

STAGE="$SCRATCH/stage"
mkdir "$STAGE"
cp -R "$APP" "$STAGE/"
# The drag-to-install convention. It matters beyond habit: Launch at Login
# uses SMAppService, which refuses to register an app that isn't properly
# installed, and an app left in Downloads runs translocated from a random
# read-only path.
ln -s /Applications "$STAGE/Applications"

swiftc "$SCRIPTS/make-dmg-background.swift" -o "$SCRATCH/make-dmg-background" 2>/dev/null \
    || die "couldn't compile $SCRIPTS/make-dmg-background.swift"
# Hidden in a folder rather than as a dotfile at the root, which Finder
# refuses to take as a background picture.
mkdir "$STAGE/.background"
"$SCRATCH/make-dmg-background" "$NAME" "$STAGE/.background/background.png"

# Built writable so Finder can save the layout into it, then compressed.
# The headroom is for the .DS_Store Finder writes.
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))
hdiutil create \
    -volname "$NAME" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDRW \
    -size "${SIZE_MB}m" \
    -quiet \
    "$SCRATCH/rw.dmg"
hdiutil attach "$SCRATCH/rw.dmg" -readwrite -noverify -noautoopen -quiet
[ -d "$MOUNT" ] || die "the image didn't mount at $MOUNT"

# Icon positions are the centres of the icons, in the same top-left points as
# the background; keep them in step with make-dmg-background.swift. Bounds
# are screen coordinates, so only their size matters, and they take in the
# title bar: the extra 32 points leave the whole 800 x 400 background showing.
osascript - "$NAME" <<'EOF' || die "Finder couldn't lay out the window; if it was refused permission, allow your terminal to control Finder in System Settings → Privacy & Security → Automation"
on run {volumeName}
    tell application "Finder"
        tell disk volumeName
            open
            tell container window
                set current view to icon view
                set toolbar visible to false
                set statusbar visible to false
                set bounds to {200, 120, 1000, 552}
            end tell
            set viewOptions to icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 212
            set text size of viewOptions to 16
            set background picture of viewOptions to file ".background:background.png"
            set position of item (volumeName & ".app") of container window to {190, 200}
            set position of item "Applications" of container window to {610, 200}
            update without registering applications
            close
        end tell
    end tell
end run
EOF

# Finder writes .DS_Store when it gets round to it, not when the script ends.
i=0
until [ -f "$MOUNT/.DS_Store" ]; do
    i=$((i + 1))
    [ $i -le 20 ] || die "Finder never saved the window layout"
    sleep 0.5
done

# The app's own icon for the mounted volume, in Finder's sidebar and on the
# desktop. Added only now because laying out the window deletes it.
if [ -f "$APP/Contents/Resources/AppIcon.icns" ]; then
    cp "$APP/Contents/Resources/AppIcon.icns" "$MOUNT/.VolumeIcon.icns"
    xcrun SetFile -a C "$MOUNT"
fi

rm -rf "$MOUNT/.fseventsd"
sync

# Finder can hold the volume open for a moment after closing the window.
i=0
until hdiutil detach "$MOUNT" -quiet 2>/dev/null; do
    i=$((i + 1))
    [ $i -le 10 ] || die "couldn't eject $MOUNT"
    sleep 1
done

rm -f "$DMG"
hdiutil convert "$SCRATCH/rw.dmg" -format UDZO -imagekey zlib-level=9 -quiet -o "$DMG"
