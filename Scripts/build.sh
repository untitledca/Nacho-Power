#!/bin/zsh
set -eu
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_DIR="$PROJECT_DIR/dist/EcoFlow Cat.app"
ASSET_DIR="${1:-$PROJECT_DIR/Assets}"
mkdir -p "$PROJECT_DIR/.build" "$PROJECT_DIR/dist"
if [[ ! -f "$PROJECT_DIR/Resources/ThirdPartyNotices.txt" ]]; then
    print -u2 "Missing required distribution resource: ThirdPartyNotices.txt"
    exit 1
fi
for clip in intro loop; do
    if [[ ! -f "$ASSET_DIR/$clip.mov" ]]; then
        print -u2 "Missing video: $ASSET_DIR/$clip.mov"
        exit 1
    fi
done
# Stage outside iCloud/other file-provider folders, which can reattach Finder
# metadata after signing and invalidate the distributed bundle.
BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ecoflow-build.XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT
BUILD_APP_DIR="$BUILD_DIR/EcoFlow Cat.app"
mkdir -p "$BUILD_APP_DIR/Contents/MacOS" "$BUILD_APP_DIR/Contents/Resources"
BINARIES=()
for architecture in arm64 x86_64; do
    binary="$BUILD_DIR/EcoFlowCat-$architecture"
    crypto="$BUILD_DIR/EcoFlowCrypto-$architecture.o"
    xcrun clang -O2 -target "$architecture-apple-macos14.0" \
        -c "$PROJECT_DIR/Sources/EcoFlowCrypto.c" -o "$crypto"
    xcrun swiftc -swift-version 5 -O -target "$architecture-apple-macos14.0" \
        -module-cache-path "$PROJECT_DIR/.build/module-cache-$architecture" \
        "$PROJECT_DIR"/Sources/*.swift "$crypto" -o "$binary"
    BINARIES+=("$binary")
done
xcrun lipo -create "${BINARIES[@]}" -output "$BUILD_APP_DIR/Contents/MacOS/EcoFlowCat"
cp -X "$PROJECT_DIR/Resources/Info.plist" "$BUILD_APP_DIR/Contents/Info.plist"
# Include branding, ThirdPartyNotices.txt, and all other bundle resources.
for resource in "$PROJECT_DIR"/Resources/*(N); do
    if [[ "${resource:t}" != "Info.plist" ]]; then
        ditto --noextattr --norsrc "$resource" "$BUILD_APP_DIR/Contents/Resources/${resource:t}"
    fi
done
for clip in intro loop; do
    cp -X "$ASSET_DIR/$clip.mov" "$BUILD_APP_DIR/Contents/Resources/$clip.mov"
done
if [[ -f "$ASSET_DIR/video-validation.json" ]]; then
    validation="$BUILD_APP_DIR/Contents/Resources/video-validation.json"
    cp -X "$ASSET_DIR/video-validation.json" "$validation"
    # The app needs validation results, never this Mac's original render path.
    if plutil -extract sourceDirectory raw -o - "$validation" >/dev/null 2>&1; then
        plutil -remove sourceDirectory "$validation"
        plutil -convert json "$validation"
    fi
fi
# Finder/iCloud may attach icon metadata even to newly copied files. These two
# non-code attributes are forbidden by codesign; remove them only in staging.
xattr -dr com.apple.FinderInfo "$BUILD_APP_DIR" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$BUILD_APP_DIR" 2>/dev/null || true
codesign --force --sign - "$BUILD_APP_DIR"
codesign --verify --deep --strict "$BUILD_APP_DIR"
# Keep the previous app intact until both architectures and resources validate.
if [[ -e "$APP_DIR" ]]; then
    mv "$APP_DIR" "$BUILD_DIR/previous.app"
fi
if ! mv "$BUILD_APP_DIR" "$APP_DIR"; then
    if [[ -e "$BUILD_DIR/previous.app" ]]; then
        mv "$BUILD_DIR/previous.app" "$APP_DIR"
    fi
    exit 1
fi
print "Built universal Mac app (Apple silicon + Intel): $APP_DIR"
