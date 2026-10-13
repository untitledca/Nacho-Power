#!/bin/zsh
set -eu
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_DIR="${1:-$PROJECT_DIR/dist/EcoFlow Cat.app}"
if [[ ! -f "$APP_DIR/Contents/MacOS/EcoFlowCat" ]]; then
    print -u2 "Build the app with Scripts/build.sh before making the disk image."
    exit 1
fi
APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_DIR/Contents/Info.plist")
OUTPUT_DMG="${2:-$PROJECT_DIR/dist/EcoFlow-Cat-$APP_VERSION-universal.dmg}"
architectures=$(xcrun lipo -archs "$APP_DIR/Contents/MacOS/EcoFlowCat")
if [[ " $architectures " != *" arm64 "* || " $architectures " != *" x86_64 "* ]]; then
    print -u2 "The disk image requires a universal app containing arm64 and x86_64."
    exit 1
fi
codesign --verify --deep --strict "$APP_DIR"
if [[ ! -f "$APP_DIR/Contents/Resources/ThirdPartyNotices.txt" ]]; then
    print -u2 "The app is missing its required ThirdPartyNotices.txt. Rebuild before sharing."
    exit 1
fi
for clip in intro middle outro; do
    if [[ ! -f "$APP_DIR/Contents/Resources/$clip.mov" ]]; then
        print -u2 "Missing bundled video: $clip.mov"
        exit 1
    fi
done
mkdir -p "$PROJECT_DIR/.build" "${OUTPUT_DMG:h}"
DMG_BUILD_DIR=$(mktemp -d "$PROJECT_DIR/.build/dmg.XXXXXX")
trap 'rm -rf "$DMG_BUILD_DIR"' EXIT
DMG_STAGE="$DMG_BUILD_DIR/EcoFlow Cat"
mkdir -p "$DMG_STAGE"
# Preserve the complete signed bundle and symbolic links.
ditto "$APP_DIR" "$DMG_STAGE/EcoFlow Cat.app"
ln -s /Applications "$DMG_STAGE/Applications"
cat > "$DMG_STAGE/Install.txt" <<'INSTALL'
EcoFlow Cat for Mac

Requires macOS 14 or later. Works on Apple silicon and Intel Macs.
All three cat videos and the app icon are included.

Install
1. Drag EcoFlow Cat.app onto the Applications folder beside it.
2. Eject this disk image.
3. Open EcoFlow Cat from your Applications folder.
4. Use its cat icon in the menu bar to open Settings or preview the cat.

Power connection
Connect one supported EcoFlow power station to this Mac with a USB data cable.
EcoFlow Cat reads the battery and input-power status directly over USB.
PowerManager is not required. Quit PowerManager or other apps using the
EcoFlow USB connection so EcoFlow Cat can read it. Open Settings to check
the connection and choose an immediate reminder or a battery threshold.

No Terminal, compiler, or developer tools are needed to run EcoFlow Cat.

First launch
This build is locally signed and has not been notarized by Apple. If macOS
blocks it as an unverified developer, first attempt to open the installed app.
If you trust this copy, open System Settings > Privacy & Security and choose
Open Anyway for EcoFlow Cat, then confirm Open. Your Mac's administrator may
restrict this option. This approval applies to this app only.
Apple's instructions: https://support.apple.com/en-us/102445

Remove
Quit EcoFlow Cat from its menu bar icon, then move the app to Trash.

Third-party notices are included inside EcoFlow Cat.app under
Contents/Resources/ThirdPartyNotices.txt.
INSTALL
if [[ -f "$APP_DIR/Contents/Resources/AppIcon.icns" ]]; then
    cp "$APP_DIR/Contents/Resources/AppIcon.icns" "$DMG_STAGE/.VolumeIcon.icns"
    if SETFILE_PATH=$(xcrun --find SetFile 2>/dev/null); then
        "$SETFILE_PATH" -a C "$DMG_STAGE"
    fi
fi
hdiutil create -volname "EcoFlow Cat" -srcfolder "$DMG_STAGE" -fs HFS+ \
    -format UDZO -imagekey zlib-level=9 -ov "$OUTPUT_DMG"
hdiutil verify "$OUTPUT_DMG"
(cd "${OUTPUT_DMG:h}" && shasum -a 256 "${OUTPUT_DMG:t}") > "$OUTPUT_DMG.sha256"
print "Created $OUTPUT_DMG"
print "Checksum: $OUTPUT_DMG.sha256"
