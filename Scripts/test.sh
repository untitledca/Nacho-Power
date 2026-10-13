#!/bin/zsh
set -eu
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
mkdir -p "$PROJECT_DIR/.build"
xcrun swiftc -swift-version 5 "$PROJECT_DIR/Sources/ReminderEngine.swift" "$PROJECT_DIR/Tests/ReminderEngineTests.swift" -o "$PROJECT_DIR/.build/reminder-tests"
"$PROJECT_DIR/.build/reminder-tests"
xcrun swiftc -parse-as-library -swift-version 5 "$PROJECT_DIR/Sources/TelemetryModels.swift" "$PROJECT_DIR/Sources/DirectEcoFlowMonitor.swift" "$PROJECT_DIR/Tests/DirectEcoFlowChecks.swift" -o "$PROJECT_DIR/.build/direct-checks"
"$PROJECT_DIR/.build/direct-checks" "$@"
