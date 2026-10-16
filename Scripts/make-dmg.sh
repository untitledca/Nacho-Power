#!/bin/zsh
set -eu
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_DIR="${1:-$PROJECT_DIR/dist/Nacho Power.app}"
if [[ ! -f "$APP_DIR/Contents/MacOS/NachoPower" ]]; then
    print -u2 "Build the app with Scripts/build.sh before making the disk image."
    exit 1
fi
APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_DIR/Contents/Info.plist")
OUTPUT_DMG="${2:-$PROJECT_DIR/dist/Nacho-Power-$APP_VERSION-universal.dmg}"
architectures=$(xcrun lipo -archs "$APP_DIR/Contents/MacOS/NachoPower")
if [[ " $architectures " != *" arm64 "* || " $architectures " != *" x86_64 "* ]]; then
    print -u2 "The disk image requires a universal app containing arm64 and x86_64."
    exit 1
fi
# Finder can attach custom-icon metadata after the build is moved into dist.
xattr -dr com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$APP_DIR" 2>/dev/null || true
codesign --verify --deep --strict "$APP_DIR"
if [[ ! -f "$APP_DIR/Contents/Resources/ThirdPartyNotices.txt" ]]; then
    print -u2 "The app is missing its required ThirdPartyNotices.txt. Rebuild before sharing."
    exit 1
fi
for clip in intro loop intro_left looping_left; do
    if [[ ! -f "$APP_DIR/Contents/Resources/$clip.mov" ]]; then
        print -u2 "Missing bundled video: $clip.mov"
        exit 1
    fi
done
mkdir -p "$PROJECT_DIR/.build" "${OUTPUT_DMG:h}"
DMG_BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ecoflow-dmg.XXXXXX")
trap 'rm -rf "$DMG_BUILD_DIR"' EXIT
DMG_STAGE="$DMG_BUILD_DIR/Nacho Power"
mkdir -p "$DMG_STAGE"
# Preserve the complete signed bundle and symbolic links.
ditto --noextattr --norsrc "$APP_DIR" "$DMG_STAGE/Nacho Power.app"
codesign --verify --deep --strict "$DMG_STAGE/Nacho Power.app"
ln -s /Applications "$DMG_STAGE/Applications"
cat > "$DMG_STAGE/Install.txt" <<'INSTALL'
Nacho Power for Mac

Requires macOS 14 or later. Works on Apple silicon and Intel Macs.
Both left- and right-side cat video pairs and the app icon are included.

Install
1. Drag Nacho Power.app onto the Applications folder beside it.
2. Eject this disk image.
3. Open Nacho Power from your Applications folder.
4. Click its Dock icon or menu bar icon to open Settings or preview the cat.

Power connection
Quit the official EcoFlow app and PowerManager before connecting.
Choose Automatic, USB, Bluetooth, or Wi-Fi (cloud) in Connection settings.
USB uses a supported data cable. Bluetooth supports DELTA 3 / DELTA 3 Plus
and automatically reuses an existing EcoFlow sign-in on this Mac. If none is
available, sign in once using your EcoFlow email and password. No account
codes are needed. Wi-Fi uses
EcoFlow's cloud API and needs developer access/secret keys and the device
serial number. Wireless support and firmware limitations are documented
in the repository README.

The Dock and menu bar show the EcoFlow battery percentage: green with AC connected,
red with AC disconnected, and gray when fresh readings are unavailable.
When AC is disconnected, the intro plays once and the loop repeats.
Left positions use the left-entry videos; right positions use the original videos.
Reconnecting AC immediately starts a short pop dismissal, even at 0 W.
Open Settings to choose an immediate reminder or a battery threshold.

No Terminal, compiler, or developer tools are needed to run Nacho Power.

Updates and support
Choose Check for Updates in Settings or the menu bar to install an update.
In App updates, enable Check automatically for updates for daily checks.
Also enable Download and install updates automatically for hands-free updates.
Both are optional. Automatic installation waits until Settings is closed and
no cat reminder or preview is active, then installs and relaunches the app.
An already downloaded update can also finish when you quit normally.
Your settings are kept. Upgrading from EcoFlow Cat? Quit and remove the old
EcoFlow Cat.app after installing Nacho Power so only one copy runs.
Copies older than v1.4.0 need one manual upgrade to get the automatic installer.
Choose Support Nacho Power for optional one-time $5, $10, or $25 USD support
through QuickBooks. The amount opens in your browser for review and payment.
The app remains free; supporting development does not unlock features.

First launch
This build is locally signed and has not been notarized by Apple. If macOS
blocks it as an unverified developer, first attempt to open the installed app.
If you trust this copy, open System Settings > Privacy & Security and choose
Open Anyway for Nacho Power, then confirm Open. Your Mac's administrator may
restrict this option. This approval applies to this app only.
Apple's instructions: https://support.apple.com/en-us/102445

Remove
Quit Nacho Power from its menu bar icon, then move the app to Trash.

Third-party notices are included inside Nacho Power.app under
Contents/Resources/ThirdPartyNotices.txt.
INSTALL
if [[ -f "$APP_DIR/Contents/Resources/AppIcon.icns" ]]; then
    cp "$APP_DIR/Contents/Resources/AppIcon.icns" "$DMG_STAGE/.VolumeIcon.icns"
    if SETFILE_PATH=$(xcrun --find SetFile 2>/dev/null); then
        "$SETFILE_PATH" -a C "$DMG_STAGE"
    fi
fi
hdiutil create -volname "Nacho Power" -srcfolder "$DMG_STAGE" -fs HFS+ \
    -format UDZO -imagekey zlib-level=9 -ov "$OUTPUT_DMG"
hdiutil verify "$OUTPUT_DMG"
(cd "${OUTPUT_DMG:h}" && shasum -a 256 "${OUTPUT_DMG:t}") > "$OUTPUT_DMG.sha256"
print "Created $OUTPUT_DMG"
print "Checksum: $OUTPUT_DMG.sha256"
