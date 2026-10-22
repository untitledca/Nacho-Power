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
    "$PROJECT_DIR/Sources/SupportDiagnostics.swift" \
    "$PROJECT_DIR/Sources/DirectEcoFlowMonitor.swift" \
    "$PROJECT_DIR/Sources/EcoFlowWirelessProtocol.swift" \
    "$PROJECT_DIR/Sources/EcoFlowSessionKeyData.swift" \
    "$PROJECT_DIR/Sources/EcoFlowBluetoothSessionState.swift" \
    "$PROJECT_DIR/Sources/EcoFlowBluetoothMonitor.swift" \
    "$PROJECT_DIR/Sources/EcoFlowConnectionMonitor.swift" \
    "$PROJECT_DIR/Sources/EcoFlowStationSlot.swift" \
    "$PROJECT_DIR/Tests/WirelessProtocolChecks.swift" \
    "$PROJECT_DIR/.build/ecoflow-crypto-tests.o" \
    -o "$PROJECT_DIR/.build/wireless-protocol-checks"
"$PROJECT_DIR/.build/wireless-protocol-checks"

xcrun swiftc -parse-as-library -swift-version 5 \
    "$PROJECT_DIR/Sources/TelemetryModels.swift" \
    "$PROJECT_DIR/Sources/SupportDiagnostics.swift" \
    "$PROJECT_DIR/Sources/DirectEcoFlowMonitor.swift" \
    "$PROJECT_DIR/Sources/EcoFlowWirelessProtocol.swift" \
    "$PROJECT_DIR/Sources/EcoFlowSessionKeyData.swift" \
    "$PROJECT_DIR/Sources/EcoFlowBluetoothSessionState.swift" \
    "$PROJECT_DIR/Sources/EcoFlowBluetoothMonitor.swift" \
    "$PROJECT_DIR/Sources/EcoFlowConnectionMonitor.swift" \
    "$PROJECT_DIR/Sources/EcoFlowStationSlot.swift" \
    "$PROJECT_DIR/Tests/CloudProtocolChecks.swift" \
    "$PROJECT_DIR/.build/ecoflow-crypto-tests.o" \
    -o "$PROJECT_DIR/.build/cloud-protocol-checks"
"$PROJECT_DIR/.build/cloud-protocol-checks"

xcrun swiftc -parse-as-library -swift-version 5 "$PROJECT_DIR/Sources/EcoFlowAccountDiscovery.swift" "$PROJECT_DIR/Tests/EcoFlowAccountDiscoveryChecks.swift" -o "$PROJECT_DIR/.build/account-discovery-checks"
"$PROJECT_DIR/.build/account-discovery-checks"

xcrun swiftc -parse-as-library -swift-version 5 "$PROJECT_DIR/Sources/AppUpdateChecker.swift" "$PROJECT_DIR/Tests/AppUpdateChecks.swift" -o "$PROJECT_DIR/.build/app-update-checks"
"$PROJECT_DIR/.build/app-update-checks"

# The production installation policy is deterministic and does not load Sparkle
# or contact an update server. Actual installer integration is checked separately.
xcrun swiftc -parse-as-library -swift-version 5 \
    "$PROJECT_DIR/Sources/AutomaticUpdatePolicy.swift" \
    "$PROJECT_DIR/Tests/AutomaticUpdateChecks.swift" \
    -o "$PROJECT_DIR/.build/automatic-update-checks"
"$PROJECT_DIR/.build/automatic-update-checks"

# Display targeting and migration use synthetic descriptors without opening windows.
xcrun swiftc -parse-as-library -swift-version 5 \
    "$PROJECT_DIR/Sources/OverlayDisplaySelection.swift" \
    "$PROJECT_DIR/Tests/DisplaySelectionChecks.swift" \
    -o "$PROJECT_DIR/.build/display-selection-checks"
"$PROJECT_DIR/.build/display-selection-checks"

# Pure canvas geometry; this test does not create an app, player, or window.
xcrun swiftc -parse-as-library -swift-version 5 \
    "$PROJECT_DIR/Sources/OverlayDisplaySelection.swift" \
    "$PROJECT_DIR/Sources/CatOverlay.swift" \
    "$PROJECT_DIR/Tests/OverlayLayoutChecks.swift" \
    -o "$PROJECT_DIR/.build/overlay-layout-checks"
"$PROJECT_DIR/.build/overlay-layout-checks"

# Pointer/alpha coordinate mapping is pure geometry by default. The optional
# --video-alpha flag also samples bundled video alpha headlessly, without windows.
xcrun swiftc -O -parse-as-library -swift-version 5 \
    "$PROJECT_DIR/Sources/OverlayDisplaySelection.swift" \
    "$PROJECT_DIR/Sources/CatOverlay.swift" \
    "$PROJECT_DIR/Tests/OverlayInteractionChecks.swift" \
    -o "$PROJECT_DIR/.build/overlay-interaction-checks"
"$PROJECT_DIR/.build/overlay-interaction-checks"
if [[ " $* " == *" --video-alpha "* ]]; then
    "$PROJECT_DIR/.build/overlay-interaction-checks" "$PROJECT_DIR/Assets"
fi

# Session state uses the production parser and routing rules without BLE hardware.
xcrun swiftc -parse-as-library -swift-version 5 \
    "$PROJECT_DIR/Sources/TelemetryModels.swift" \
    "$PROJECT_DIR/Sources/EcoFlowWirelessProtocol.swift" \
    "$PROJECT_DIR/Sources/EcoFlowSessionKeyData.swift" \
    "$PROJECT_DIR/Sources/EcoFlowBluetoothSessionState.swift" \
    "$PROJECT_DIR/Tests/BluetoothSessionChecks.swift" \
    "$PROJECT_DIR/.build/ecoflow-crypto-tests.o" \
    -o "$PROJECT_DIR/.build/bluetooth-session-checks"
"$PROJECT_DIR/.build/bluetooth-session-checks"

# Pure diagnostics tests use isolated temporary storage and synthetic packets.
xcrun swiftc -parse-as-library -swift-version 5 \
    "$PROJECT_DIR/Sources/SupportDiagnostics.swift" \
    "$PROJECT_DIR/Tests/SupportDiagnosticsChecks.swift" \
    -o "$PROJECT_DIR/.build/support-diagnostics-checks"
"$PROJECT_DIR/.build/support-diagnostics-checks"

xcrun swiftc -parse-as-library -swift-version 5 \
    "$PROJECT_DIR/Sources/TelemetryModels.swift" \
    "$PROJECT_DIR/Sources/SupportDiagnostics.swift" \
    "$PROJECT_DIR/Sources/EcoFlowWirelessProtocol.swift" \
    "$PROJECT_DIR/Sources/EcoFlowSessionKeyData.swift" \
    "$PROJECT_DIR/Sources/EcoFlowBluetoothSessionState.swift" \
    "$PROJECT_DIR/Tests/BluetoothDiagnosticChecks.swift" \
    "$PROJECT_DIR/.build/ecoflow-crypto-tests.o" \
    -o "$PROJECT_DIR/.build/bluetooth-diagnostic-checks"
"$PROJECT_DIR/.build/bluetooth-diagnostic-checks"

# Nearby station metadata and serial targeting never open a telemetry session.
xcrun swiftc -parse-as-library -swift-version 5 \
    "$PROJECT_DIR/Sources/TelemetryModels.swift" \
    "$PROJECT_DIR/Sources/SupportDiagnostics.swift" \
    "$PROJECT_DIR/Sources/DirectEcoFlowMonitor.swift" \
    "$PROJECT_DIR/Sources/EcoFlowWirelessProtocol.swift" \
    "$PROJECT_DIR/Sources/EcoFlowSessionKeyData.swift" \
    "$PROJECT_DIR/Sources/EcoFlowBluetoothSessionState.swift" \
    "$PROJECT_DIR/Sources/EcoFlowBluetoothMonitor.swift" \
    "$PROJECT_DIR/Sources/EcoFlowConnectionMonitor.swift" \
    "$PROJECT_DIR/Sources/EcoFlowStationSlot.swift" \
    "$PROJECT_DIR/Sources/EcoFlowStationDiscovery.swift" \
    "$PROJECT_DIR/Tests/StationDiscoveryChecks.swift" \
    "$PROJECT_DIR/.build/ecoflow-crypto-tests.o" \
    -o "$PROJECT_DIR/.build/station-discovery-checks"
"$PROJECT_DIR/.build/station-discovery-checks"

# Independent physical observations and timers; no device or app interaction.
xcrun swiftc -parse-as-library -swift-version 5 \
    "$PROJECT_DIR/Sources/ReminderEngine.swift" \
    "$PROJECT_DIR/Sources/EcoFlowStationSlot.swift" \
    "$PROJECT_DIR/Sources/MultiStationReminderPolicy.swift" \
    "$PROJECT_DIR/Tests/MultiStationReminderChecks.swift" \
    -o "$PROJECT_DIR/.build/multi-station-reminder-checks"
"$PROJECT_DIR/.build/multi-station-reminder-checks"
