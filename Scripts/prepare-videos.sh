#!/bin/zsh
set -eu
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
if [[ $# -lt 1 ]]; then
    print -u2 "Usage: Scripts/prepare-videos.sh /path/to/ProRes-masters [right|left|all]"
    exit 1
fi
SOURCE_DIR="$1"
case "${2:-right}" in
    right) CLIPS=(intro loop) ;;
    left) CLIPS=(intro_left looping_left) ;;
    all) CLIPS=(intro loop intro_left looping_left) ;;
    *) print -u2 "Choose right, left, or all."; exit 1 ;;
esac
mkdir -p "$PROJECT_DIR/.build" "$PROJECT_DIR/Assets"
xcrun swiftc -swift-version 5 -parse-as-library "$PROJECT_DIR/tools/validate-videos.swift" -o "$PROJECT_DIR/.build/validate-videos"
"$PROJECT_DIR/.build/validate-videos" "$SOURCE_DIR" "$PROJECT_DIR/.build/source-video-validation.json" "${CLIPS[@]}"
xcrun swiftc -swift-version 5 -parse-as-library "$PROJECT_DIR/tools/export-alpha-videos.swift" -o "$PROJECT_DIR/.build/export-alpha-videos"
"$PROJECT_DIR/.build/export-alpha-videos" "$SOURCE_DIR" "$PROJECT_DIR/Assets" "${CLIPS[@]}"
ALL_CLIPS=(intro loop)
if [[ -f "$PROJECT_DIR/Assets/intro_left.mov" || -f "$PROJECT_DIR/Assets/looping_left.mov" ]]; then
    ALL_CLIPS+=(intro_left looping_left)
fi
"$PROJECT_DIR/.build/validate-videos" "$PROJECT_DIR/Assets" "$PROJECT_DIR/Assets/video-validation.json" "${ALL_CLIPS[@]}"
