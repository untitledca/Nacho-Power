#!/bin/zsh
set -eu
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
mkdir -p "$PROJECT_DIR/.build"
xcrun swiftc -swift-version 5 "$PROJECT_DIR/Sources/ReminderEngine.swift" "$PROJECT_DIR/Tests/ReminderEngineTests.swift" -o "$PROJECT_DIR/.build/reminder-tests"
"$PROJECT_DIR/.build/reminder-tests"
xcrun swiftc -parse-as-library -swift-version 5 "$PROJECT_DIR/Sources/TelemetryModels.swift" "$PROJECT_DIR/Sources/DirectEcoFlowMonitor.swift" "$PROJECT_DIR/Tests/DirectEcoFlowChecks.swift" -o "$PROJECT_DIR/.build/direct-checks"
"$PROJECT_DIR/.build/direct-checks" "$@"

xcrun swiftc -parse-as-library -swift-version 5 "$PROJECT_DIR/Sources/TelemetryModels.swift" "$PROJECT_DIR/Sources/DockStatusIcon.swift" "$PROJECT_DIR/Tests/DockStatusChecks.swift" -o "$PROJECT_DIR/.build/dock-status-checks"
"$PROJECT_DIR/.build/dock-status-checks"

xcrun clang -O2 -c "$PROJECT_DIR/Sources/EcoFlowCrypto.c" -o "$PROJECT_DIR/.build/ecoflow-crypto-tests.o"
xcrun swiftc -parse-as-library -swift-version 5 \
    "$PROJECT_DIR/Sources/TelemetryModels.swift" \
    "$PROJECT_DIR/Sources/DirectEcoFlowMonitor.swift" \
    "$PROJECT_DIR/Sources/EcoFlowWirelessProtocol.swift" \
    "$PROJECT_DIR/Sources/EcoFlowSessionKeyData.swift" \
    "$PROJECT_DIR/Sources/EcoFlowBluetoothMonitor.swift" \
    "$PROJECT_DIR/Sources/EcoFlowConnectionMonitor.swift" \
    "$PROJECT_DIR/Tests/WirelessProtocolChecks.swift" \
    "$PROJECT_DIR/.build/ecoflow-crypto-tests.o" \
    -o "$PROJECT_DIR/.build/wireless-protocol-checks"
"$PROJECT_DIR/.build/wireless-protocol-checks"

xcrun swiftc -parse-as-library -swift-version 5 \
    "$PROJECT_DIR/Sources/TelemetryModels.swift" \
    "$PROJECT_DIR/Sources/DirectEcoFlowMonitor.swift" \
    "$PROJECT_DIR/Sources/EcoFlowWirelessProtocol.swift" \
    "$PROJECT_DIR/Sources/EcoFlowSessionKeyData.swift" \
    "$PROJECT_DIR/Sources/EcoFlowBluetoothMonitor.swift" \
    "$PROJECT_DIR/Sources/EcoFlowConnectionMonitor.swift" \
    "$PROJECT_DIR/Tests/CloudProtocolChecks.swift" \
    "$PROJECT_DIR/.build/ecoflow-crypto-tests.o" \
    -o "$PROJECT_DIR/.build/cloud-protocol-checks"
"$PROJECT_DIR/.build/cloud-protocol-checks"

xcrun swiftc -parse-as-library -swift-version 5 "$PROJECT_DIR/Sources/EcoFlowAccountDiscovery.swift" "$PROJECT_DIR/Tests/EcoFlowAccountDiscoveryChecks.swift" -o "$PROJECT_DIR/.build/account-discovery-checks"
"$PROJECT_DIR/.build/account-discovery-checks"

xcrun swiftc -parse-as-library -swift-version 5 "$PROJECT_DIR/Sources/AppUpdateChecker.swift" "$PROJECT_DIR/Tests/AppUpdateChecks.swift" -o "$PROJECT_DIR/.build/app-update-checks"
"$PROJECT_DIR/.build/app-update-checks"
