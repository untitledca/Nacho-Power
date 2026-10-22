import Foundation
import Darwin

@main private enum CloudProtocolChecks {
    private static func check(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL \(message)\n", stderr); exit(1) }
    }
    @MainActor static func main() async throws {
        check(EcoFlowConnectionMonitor.blockingAppKind(name: "EcoFlow", bundleIdentifier: "com.ef.EcoFlow") == "ecoflow",
              "The local official EcoFlow app has a stable diagnostic category")
        check(EcoFlowConnectionMonitor.blockingAppKind(name: "PowerManager", bundleIdentifier: "vendor.PowerManager") == "powermanager",
              "The local PowerManager blocker has its own category")
        check(EcoFlowConnectionMonitor.blockingAppKind(name: "Unrelated Client", bundleIdentifier: "example.client") == nil,
              "Unrelated apps are not reported as known connection blockers")
        // Public worked example in EcoFlow Developer API signing documentation.
        // These are example strings, not the user's account credentials.
        let headers = EcoFlowCloudMonitor.signedHeaders(
            parameters: ["params.cmdSet": "11", "params.eps": "0", "params.id": "24", "sn": "123456789"],
            accessKey: "Fp4SvIprYSDPXtYJidEtUAd1o", secretKey: "WIbFEKre0s6sLnh4ei7SPUeYnptHG6V",
            nonce: "345164", timestamp: "1671171709428")
        check(headers["sign"] == "07c13b65e037faf3b153d51613638fa80003c4c38d2407379a7f52851af1473e", "official HMAC signing vector")

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let full = try EcoFlowCloudMonitor.telemetry(data: ["cmsBattSoc": 100, "powGetAcIn": 0,
            "powInSumW": 450, "plugInInfoAcChargerFlag": 1], name: "Fixture DELTA", now: now)
        check(full.batteryPercentage == 100 && full.acConnected == true && full.acInputWatts == 0,
              "full battery connected at zero AC watts")
        check(full.totalInputWatts == 450 && full.timestamp == now, "separate solar-inclusive total and reading timestamp")
        let missing = try EcoFlowCloudMonitor.telemetry(data: ["cmsBattSoc": 50], name: "Fixture DELTA", now: now)
        check(missing.acConnected == nil && missing.acInputWatts == nil && missing.totalInputWatts == nil,
              "omitted fields cannot invent unplugged or zero-watt data")
        let unplugged = try EcoFlowCloudMonitor.telemetry(data: ["cmsBattSoc": 50, "powInSumW": 150,
            "plugInInfoAcChargerFlag": 0], name: "Fixture DELTA", now: now)
        check(unplugged.acConnected == false && unplugged.totalInputWatts == 150, "solar input does not imply AC power")
        let invalid = try EcoFlowCloudMonitor.telemetry(data: ["cmsBattSoc": 50, "powGetAcIn": Double.nan,
            "powInSumW": -1, "plugInInfoAcChargerFlag": 0.5], name: "Fixture DELTA", now: now)
        check(invalid.acConnected == nil && invalid.acInputWatts == nil && invalid.totalInputWatts == nil,
              "invalid flags and watts remain unknown")
        var rejected = false
        do { _ = try EcoFlowCloudMonitor.telemetry(data: ["cmsBattSoc": 101], name: "Fixture DELTA", now: now) }
        catch { rejected = true }
        check(rejected, "out-of-range battery cannot become a valid cloud reading")
        try await stoppedAttemptChecks()
        print("PASS official cloud signature and telemetry presence/range checks")
    }

    /// The real monitor's routing and stop() run with suspended fake I/O and
    /// an in-memory recorder. No device, network, Keychain, or support log opens.
    @MainActor private static func stoppedAttemptChecks() async throws {
        var config = EcoFlowConnectionConfiguration()
        config.userID = "fixture-owner"
        config.serialNumber = "P351OLD1234567890"
        config.accessKey = "fixture-access"
        config.secretKey = "fixture-secret"
        let sample = PowerTelemetry(deviceName: "Fixture", batteryPercentage: 73,
            acInputWatts: 0, totalInputWatts: 0, acConnected: true,
            sourceDescription: "Fixture", timestamp: Date(timeIntervalSince1970: 1_800_000_000))

        let heldUSB = HeldRead()
        var usbCalls: [EcoFlowTransport] = []
        let usbMonitor = EcoFlowConnectionMonitor(transportSnapshot: { transport, _ in
            usbCalls.append(transport)
            if transport == .usb { return try await heldUSB.read() }
            return sample
        }, blockingApp: { nil }, diagnosticRecorder: { _, _, _ in })
        let oldUSB = Task { try await usbMonitor.snapshot(configuration: config) }
        await heldUSB.waitUntilEntered()
        usbMonitor.stop()
        var newer = config
        newer.transport = .bluetooth
        newer.serialNumber = "P351NEW1234567890"
        let newerResult = try await usbMonitor.snapshot(configuration: newer)
        check(newerResult.batteryPercentage == 73, "A new generation can complete while the old USB read is pending")
        heldUSB.fail(DirectEcoFlowError.noDevice)
        await requireCancellation(oldUSB, "Stopping during USB must cancel the old automatic attempt")
        check(usbCalls == [.usb, .bluetooth],
              "Old USB failure cannot revive Bluetooth or cloud after stop, or interfere with the new generation")

        let heldBluetooth = HeldRead()
        var bluetoothCalls: [EcoFlowTransport] = []
        let bluetoothMonitor = EcoFlowConnectionMonitor(transportSnapshot: { transport, _ in
            bluetoothCalls.append(transport)
            if transport == .usb { throw DirectEcoFlowError.noDevice }
            if transport == .bluetooth { return try await heldBluetooth.read() }
            return sample
        }, blockingApp: { nil }, diagnosticRecorder: { _, _, _ in })
        let oldBluetooth = Task { try await bluetoothMonitor.snapshot(configuration: config) }
        await heldBluetooth.waitUntilEntered()
        bluetoothMonitor.stop()
        heldBluetooth.fail(EcoFlowWirelessError.message("Fixture disconnected"))
        await requireCancellation(oldBluetooth, "Stopping during Bluetooth must cancel the old automatic attempt")
        check(bluetoothCalls == [.usb, .bluetooth], "Old Bluetooth failure cannot start cloud fallback after stop")

        let heldCloud = HeldRead()
        var cloudEvents = 0
        let cloudMonitor = EcoFlowConnectionMonitor(transportSnapshot: { _, _ in try await heldCloud.read() },
            blockingApp: { nil }, diagnosticRecorder: { _, _, _ in cloudEvents += 1 })
        var cloudConfig = config
        cloudConfig.transport = .wifi
        let oldCloud = Task { try await cloudMonitor.snapshot(configuration: cloudConfig) }
        await heldCloud.waitUntilEntered()
        cloudMonitor.stop()
        heldCloud.succeed(sample)
        await requireCancellation(oldCloud, "A late cloud result from a stopped generation is discarded")
        check(cloudEvents == 0, "A stale result cannot be logged as a current successful station reading")

        var cancelledCalls: [EcoFlowTransport] = []
        let cancelledMonitor = EcoFlowConnectionMonitor(transportSnapshot: { transport, _ in
            cancelledCalls.append(transport)
            throw CancellationError()
        }, blockingApp: { nil }, diagnosticRecorder: { _, _, _ in })
        let cancelled = Task { try await cancelledMonitor.snapshot(configuration: config) }
        await requireCancellation(cancelled, "A transport's CancellationError propagates without falling through")
        check(cancelledCalls == [.usb], "Cancellation does not count as an ordinary USB failure eligible for fallback")
        print("PASS stopped USB/Bluetooth fallback cancellation, late cloud result rejection, and independent new generations")
    }

    @MainActor private static func requireCancellation(_ task: Task<PowerTelemetry, Error>, _ message: String) async {
        do { _ = try await task.value; check(false, message) }
        catch is CancellationError { }
        catch { check(false, message + ": unexpected error") }
    }
}

@MainActor
private final class HeldRead {
    private var entered = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<PowerTelemetry, Error>?

    func read() async throws -> PowerTelemetry {
        entered = true
        enteredContinuation?.resume(); enteredContinuation = nil
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func fail(_ error: Error) { continuation?.resume(throwing: error); continuation = nil }
    func succeed(_ reading: PowerTelemetry) { continuation?.resume(returning: reading); continuation = nil }
}
