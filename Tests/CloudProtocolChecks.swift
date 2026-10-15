import Foundation
import Darwin

@main private enum CloudProtocolChecks {
    private static func check(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL \(message)\n", stderr); exit(1) }
    }
    static func main() throws {
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
        print("PASS official cloud signature and telemetry presence/range checks")
    }
}
