#!/bin/bash
# Builds the unsigned Release app (ad-hoc signed, no Developer Team) and packs it into a DMG.
# Run from the project root (it builds from a copy in a new /tmp/cmt-release.XXXXXX folder, removed afterwards, also on failure):
#   tools/release/make-dmg.sh <output folder>
# The DMG opens as the "Catch My Train Installer" volume with the app icon as its icon. Its window shows the app,
# an Applications link with an arrow between them (tools/release/dmg-background.png, no words), and two guide folders
# whose names and pages follow the Mac's language (tools/release/make-guide.py): the install guide with a question-mark
# icon, which also holds LICENSE.txt, and the notes for people who use the desktop widget, with a four-squares icon.
# Laying out the window asks Finder through AppleScript: the first run may ask to let this app control Finder.
# The Debug build keeps its Developer Team (from Local.xcconfig); only this Release build drops it, and the copy it builds from
# leaves Local.xcconfig out. CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO keeps the debug-only get-task-allow entitlement out of the release.
set -euo pipefail
OUT="${1:?usage: tools/release/make-dmg.sh <output folder>}"
[ $# -eq 1 ] || { echo "usage: tools/release/make-dmg.sh <output folder>"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" App/Info.plist)
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac

# The bundled subway data is only a fallback (the app downloads new data each month), but a published version shouldn't carry
# data that has already ended: say so (it doesn't stop the build). tools/generate_stations.py refreshes it.
FEED_END=$(grep -o '"feedEndDate":"[0-9]*"' Packages/CatchCore/Sources/TransitCore/Resources/subway_stations.json | grep -o '[0-9]\{8\}' || true)
if [ -n "$FEED_END" ] && [ "$FEED_END" -lt "$(TZ=America/New_York date +%Y%m%d)" ]; then
    echo "Note: the bundled subway data ended on $FEED_END. Refresh it with tools/generate_stations.py before publishing this DMG."
fi

# Build from a copy in /tmp: the compiler embeds source and build paths in the binaries, and the
# project folder's path contains the macOS account name. mktemp makes a new private folder each time (no fixed path
# another account could prepare in advance); everything temporary lives under it.
WORK="$(mktemp -d /tmp/cmt-release.XXXXXX)"
DEVICE=""
CHECK="$WORK/check"
cleanup() {
    cd /
    if [ -n "$DEVICE" ]; then hdiutil detach "$DEVICE" -quiet || hdiutil detach "$DEVICE" -force -quiet || true; fi
    if [ -d "$CHECK" ]; then hdiutil detach "$CHECK" -quiet >/dev/null 2>&1 || hdiutil detach "$CHECK" -force -quiet >/dev/null 2>&1 || true; fi
    rm -rf "$WORK"
}
trap cleanup EXIT
rsync -a --exclude build --exclude .build --exclude .swiftpm --exclude Local.xcconfig \
    "$PWD/" "$WORK/CatchMyTrain/"
cd "$WORK/CatchMyTrain"

xcodebuild -project CatchMyTrain.xcodeproj -scheme CatchMyTrain -configuration Release -derivedDataPath build \
    DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- PROVISIONING_PROFILE_SPECIFIER= CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    build
APP="$PWD/build/Build/Products/Release/Catch My Train.app"
codesign --verify --deep --strict "$APP"

# Keep this Mac's only registered copy the Debug build: unregister the Release app right after building it.
"$LSREGISTER" -u "$APP" || true
"$LSREGISTER" -u "$APP" || true   # once is sometimes not enough

# No path from the home folder may be left in the binaries (raw-byte search; `strings` misses some).
for BIN in "$APP/Contents/MacOS/Catch My Train" "$APP/Contents/PlugIns/Catch My Train Widget.appex/Contents/MacOS/Catch My Train Widget"; do
    if grep -a -c -e "$HOME" -e "/Users/" "$BIN" >/dev/null; then
        echo "A home-folder path is still inside $(basename "$BIN"); not packing."
        exit 1
    fi
done

VOLNAME="Catch My Train Installer"
DMG="$OUT/Catch-My-Train-$VERSION.dmg"
ICNS="$APP/Contents/Resources/AppIcon.icns"
[ -f "$ICNS" ] || { echo "The app has no AppIcon.icns; not packing."; exit 1; }
# A volume already mounted under the same name would make Finder lay out the wrong window
[ ! -e "/Volumes/$VOLNAME" ] || { echo "Eject \"$VOLNAME\" first."; exit 1; }

STAGE="$WORK/stage"
mkdir "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# make-guide.py prints the two folders it made, one per line: the install guide, then the widget notes
GUIDES="$(python3 tools/release/make-guide.py "$STAGE")"
GUIDE="$(echo "$GUIDES" | sed -n 1p)"
WIDGET_GUIDE="$(echo "$GUIDES" | sed -n 2p)"
[ -d "$GUIDE" ] && [ -d "$WIDGET_GUIDE" ] || { echo "make-guide.py didn't make both guide folders; not packing."; exit 1; }
cp LICENSE "$GUIDE/LICENSE.txt"
mkdir "$STAGE/.background"
tiffutil -cathidpicheck tools/release/dmg-background.png tools/release/dmg-background@2x.png -out "$STAGE/.background/background.tiff"

# Writable image first, so Finder can save the window layout (.DS_Store) and the volume can get its icon
RW="$WORK/rw.dmg"
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -size "${SIZE_MB}m" "$RW"
rm -r "$STAGE"
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep -E '^/dev/' | head -1 | awk '{print $1}')
MOUNT="/Volumes/$VOLNAME"
sleep 2
# Custom volume icon: .VolumeIcon.icns plus the "has custom icon" Finder flag on the volume root.
# hdiutil -srcfolder leaves the icon file out, so it is copied onto the mounted volume.
setfile() { if command -v SetFile >/dev/null; then SetFile "$@"; else xcrun SetFile "$@"; fi; }
volume_icon() {
    [ -f "$MOUNT/.VolumeIcon.icns" ] || cp "$ICNS" "$MOUNT/.VolumeIcon.icns"
    setfile -c icnC "$MOUNT/.VolumeIcon.icns"
    setfile -a C "$MOUNT"
}
volume_icon
# Words that would tell whose Mac built the DMG: the account name and the account's full name, any home folder path, the
# computer's name and its other spelling (the local host name, with hyphens), the name and email git has on this Mac, and the
# system disk's name (the window layout in .DS_Store records the disk; "Macintosh HD" is the default and names no one). Every
# file is read as raw bytes in UTF-8 and UTF-16 (.DS_Store and bookmarks keep names in UTF-16). The project's public names
# (bundle id, repository, copyright line) are left out first. Only the kind of word and the file are printed, never the word,
# so the output can be shared as is. A word this Mac doesn't have isn't looked for; one shorter than 3 characters would be
# found everywhere, so it isn't either, and the output says so.
scan_image() {
    local disk computer host full gitname gitmail
    # awk reads to the end, so diskutil never stops early on a closed pipe
    disk="$(diskutil info / | awk -F': *' '/Volume Name/ && !n {print $2; n = 1}')" || return 1
    computer="$(scutil --get ComputerName)" || return 1
    [ -n "$disk" ] && [ -n "$computer" ] || { echo "Couldn't read this Mac's computer or system disk name for the check."; return 1; }
    [ "$disk" = "Macintosh HD" ] && disk=""
    host="$(scutil --get LocalHostName 2>/dev/null || true)"
    full="$(id -F 2>/dev/null || true)"
    gitname="$(git config --get user.name 2>/dev/null || true)"
    gitmail="$(git config --get user.email 2>/dev/null || true)"
    python3 - "$1" "account name=$(id -un)" "home folder path=/Users/" "computer name=$computer" "system disk name=$disk" \
        "account full name=$full" "local host name=$host" "git name=$gitname" "git email=$gitmail" \
        "name part of the git email=${gitmail%%@*}" <<'PY'
import os, sys
root = sys.argv[1]
words = [arg.split("=", 1) for arg in sys.argv[2:]]
for kind, word in words:
    if 0 < len(word) < 3:
        print("The " + kind + " is shorter than 3 characters: not looked for")
words = [(kind, word) for kind, word in words if len(word) >= 3]
public = ["Copyright (c) 2026 CheeCar", "com.cheecar", "CheeCar/Catch-My-Train", "github.com/CheeCar"]
codecs = ["utf-8", "utf-16-le", "utf-16-be"]
found = 0
for folder, _, names in os.walk(root):
    for name in names:
        path = os.path.join(folder, name)
        if os.path.islink(path):
            continue
        with open(path, "rb") as f:
            data = f.read()
        for codec in codecs:
            for phrase in public:
                data = data.replace(phrase.encode(codec), b"")
        for kind, word in words:
            if any(word.encode(codec) in data for codec in codecs):
                print("The " + kind + " is inside " + os.path.relpath(path, root))
                found += 1
sys.exit(1 if found else 0)
PY
}
# Labels macOS puts on files that say where they came from or when they were last used (downloaded from which page, opened
# when): none may be on a file of the image. Only the label's name and the file are printed, never what the label says.
scan_labels() {
    local labels
    labels="$(cd "$1" && xattr -r . 2>/dev/null | grep -i -E 'quarantine|wherefroms|lastuseddate|metadata:kMDItem' || true)"
    [ -z "$labels" ] && return 0
    echo "Files of the image carry labels about where they came from or when they were used:"
    echo "$labels"
    return 1
}
# The window size Finder saved in the image's .DS_Store ("{{left, top}, {width, height}}"): the one asked for below, or the
# installer window opens in another size on other Macs. When none can be read from the file, that is said and the image is
# still finished: check the window by opening the DMG.
WINDOW_SIZE="640, 508"
scan_window() {
    local saved
    saved="$(grep -a -o -E '\{\{-?[0-9]+, -?[0-9]+\}, \{[0-9]+, [0-9]+\}\}' "$1/.DS_Store" 2>/dev/null | sort -u || true)"
    if [ -z "$saved" ]; then
        echo "Note: couldn't read the saved window size from the image. Open the DMG and check its window."
        return 0
    fi
    if echo "$saved" | grep -v -q -F "{$WINDOW_SIZE}}"; then
        echo "The image's saved window isn't $WINDOW_SIZE points: $(echo "$saved" | tr '\n' ' ')"
        return 1
    fi
}
GUIDE_NAME="$(basename "$GUIDE")"
WIDGET_NAME="$(basename "$WIDGET_GUIDE")"
# Each guide folder gets a page icon, so neither looks like a second folder to install: a question mark on the install
# guide, the widget glyph (four squares) on the widget notes
set_icon() {
    osascript -l JavaScript - "$1" "$2" <<'JXA'
ObjC.import('AppKit');
function run(argv) {
    const image = $.NSImage.alloc.initWithContentsOfFile(argv[0]);
    if (!$.NSWorkspace.sharedWorkspace.setIconForFileOptions(image, argv[1], 0)) throw new Error('could not set a guide icon');
}
JXA
}
set_icon "$PWD/tools/release/dmg-guide-icon.png" "$MOUNT/$GUIDE_NAME"
set_icon "$PWD/tools/release/dmg-widget-icon.png" "$MOUNT/$WIDGET_NAME"
# Window: 640 x 480 points of content, no toolbar, icons 112 points; positions are icon centres. The two guide folders sit side
# by side below the arrow. Icons and labels stay in the top 400 points, so a Finder tab bar, path bar or status bar can't cover
# the guides' names, two lines at most (tools/release/dmg-background.mjs).
# After the layout the window's size is read back (width, height): Finder must have kept the one asked for.
if ! SHOWN="$(osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 840, 628}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 112
        set text size of viewOptions to 12
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "Catch My Train.app" of container window to {170, 140}
        set position of item "Applications" of container window to {470, 140}
        set position of item "$GUIDE_NAME" of container window to {220, 280}
        set position of item "$WIDGET_NAME" of container window to {420, 280}
        close
        open
        update without registering applications
        delay 2
        set shown to the bounds of container window
        close
    end tell
end tell
return (((item 3 of shown) - (item 1 of shown)) as text) & ", " & (((item 4 of shown) - (item 2 of shown)) as text)
APPLESCRIPT
)"; then
    echo "Finder couldn't lay out the window (allow this app to control Finder in System Settings > Privacy & Security > Automation); not packing."
    exit 1
fi
if [ "$SHOWN" != "$WINDOW_SIZE" ]; then
    echo "Finder's window is $SHOWN points, not $WINDOW_SIZE; not packing."
    exit 1
fi
# Finder can clear the volume's custom-icon flag while it saves the layout, so set it again
volume_icon
rm -rf "$MOUNT/.fseventsd"
chmod -Rf go-w "$MOUNT" || true
sync
hdiutil detach "$DEVICE" -quiet || { sleep 3; hdiutil detach "$DEVICE" -force -quiet; }
DEVICE=""
# The image is finished and checked inside WORK and only then moved to OUT, so a failed rebuild of the same version
# never replaces or deletes a good DMG that is already there
FINAL="$WORK/final.dmg"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$FINAL"
rm -f "$RW"
# The finished image must still carry its volume icon, and none of its files may name this Mac (see scan_image)
mkdir "$CHECK"
hdiutil attach -readonly -nobrowse -noverify -mountpoint "$CHECK" "$FINAL" >/dev/null
ICON_OK=yes
[ -f "$CHECK/.VolumeIcon.icns" ] || ICON_OK=no
GetFileInfo -a "$CHECK" 2>/dev/null | grep -q C || xcrun GetFileInfo -a "$CHECK" | grep -q C || ICON_OK=no
SCAN_OK=yes
scan_image "$CHECK" || SCAN_OK=no
LABELS_OK=yes
scan_labels "$CHECK" || LABELS_OK=no
WINDOW_OK=yes
scan_window "$CHECK" || WINDOW_OK=no
hdiutil detach "$CHECK" -quiet || hdiutil detach "$CHECK" -force -quiet
rmdir "$CHECK"
[ "$ICON_OK" = yes ] || { echo "The DMG lost its volume icon; not finished."; exit 1; }
[ "$SCAN_OK" = yes ] || { echo "The DMG names this Mac or its user (see above; for the system disk, rename it or check the name is no one's); not finished."; exit 1; }
[ "$LABELS_OK" = yes ] || { echo "Files in the DMG carry labels (see above); not finished."; exit 1; }
[ "$WINDOW_OK" = yes ] || { echo "The DMG's window has the wrong size (see above); not finished."; exit 1; }
mkdir -p "$OUT"
mv -f "$FINAL" "$DMG"
# File name only: the output folder's path holds the account name, and this line gets pasted into release notes
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")")
