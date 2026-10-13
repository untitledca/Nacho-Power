import Foundation

@main
struct DirectEcoFlowProbe {
    static func main() async {
        do {
            let sample = try await DirectEcoFlowMonitor().snapshot()
            print("Device: \(sample.deviceName)")
            print("Battery: \(sample.batteryPercentage.map { String($0) } ?? "unknown")%")
            print("AC connected: \(sample.acConnected.map { String($0) } ?? "unknown")")
            print("Dedicated AC input: \(sample.acInputWatts.map { String($0) } ?? "unknown") W")
            print("Total input: \(sample.totalInputWatts.map { String($0) } ?? "unknown") W")
            print("Source: \(sample.sourceDescription)")
        } catch { print(error.localizedDescription); exit(1) }
    }
}
