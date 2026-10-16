#!/bin/zsh
set -eu
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
mkdir -p "$PROJECT_DIR/.build"
xcrun swiftc -parse-as-library -swift-version 5 \
    "$PROJECT_DIR/Sources/OverlayDisplaySelection.swift" \
    "$PROJECT_DIR/Tests/DisplaySelectionChecks.swift" \
    -o "$PROJECT_DIR/.build/display-selection-checks"
"$PROJECT_DIR/.build/display-selection-checks"

# Runs real transparent AppKit windows and real bundled clips with an injected
# three-display inventory. No installed app or EcoFlow connection is opened.
xcrun swiftc -parse-as-library -swift-version 5 \
    "$PROJECT_DIR/Sources/OverlayDisplaySelection.swift" \
    "$PROJECT_DIR/Sources/CatOverlay.swift" \
    "$PROJECT_DIR/Tests/MultiDisplayOverlaySmoke.swift" \
    -o "$PROJECT_DIR/.build/multi-display-overlay-smoke"
"$PROJECT_DIR/.build/multi-display-overlay-smoke" "$PROJECT_DIR/Assets" \
    "$PROJECT_DIR/.build/multi-display-overlay-smoke.json"
