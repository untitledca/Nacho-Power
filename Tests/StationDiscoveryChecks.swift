import Foundation

/// Synthetic inventories and independent session states only: no discovery
/// object, CoreBluetooth manager, USB enumeration, Keychain, or app is started.
@main
private enum StationDiscoveryChecks {
    static func main() throws {
        typealias Station = EcoFlowDiscoveredStation
        let alpha = Station(serialNumber: "P351ALPHA12345678", name: "EcoFlow DELTA 3 Plus", transport: .bluetooth)
        let bravo = Station(serialNumber: "P351BRAVO87654321", name: "EcoFlow DELTA 3 Plus", transport: .bluetooth)
        var stations = Station.merging(bravo, into: [])
        stations = Station.merging(alpha, into: stations)
        stations = Station.merging(alpha, into: stations)
        check(stations.count == 2 && Set(stations.map(\.id)).count == 2,
              "Two stations remain distinct while duplicate advertisements merge")
        check(alpha.userDisplayName.contains("345678") && !alpha.userDisplayName.contains(alpha.serialNumber),
              "The picker label shows a short identifying suffix rather than the full serial")
        stations = Station.merging(.init(serialNumber: " p351alpha12345678 \n", name: "EcoFlow USB", transport: .usb), into: stations)
        let merged = stations.first { $0.id == alpha.id }
        check(stations.count == 2 && merged?.transport == .usb && merged?.name == alpha.name,
              "USB and Bluetooth sightings of the same station produce one entry with its readable model")
        let usbFirst = Station.merging(alpha, into: [.init(serialNumber: alpha.id, name: "EcoFlow USB", transport: .usb)])
        check(usbFirst.count == 1 && usbFirst[0].transport == .usb && usbFirst[0].name == alpha.name,
              "Discovery order does not change USB preference or the Bluetooth model name")
        check(Station.merging(.init(serialNumber: "  ", name: "Unknown USB", transport: .usb), into: stations) == stations,
              "Unidentified devices cannot become an unsafe empty-serial picker selection")

        var primary = EcoFlowConnectionConfiguration()
        primary.serialNumber = alpha.serialNumber
        var secondary = primary
        secondary.serialNumber = bravo.serialNumber
        secondary.stationSlot = .secondary
        check(primary.stationSlot == .primary && secondary.stationSlot == .secondary && primary != secondary,
              "Each configuration has an independent target and bounded diagnostic slot")

        var firstSession = EcoFlowBluetoothSessionState()
        var secondSession = EcoFlowBluetoothSessionState()
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        firstSession.authenticate(at: time)
        secondSession.authenticate(at: time)
        firstSession.ingest(.init(battery: 80, acInputVoltage: 121), at: time)
        secondSession.ingest(.init(battery: 25, acInputVoltage: 0), at: time)
        check(firstSession.snapshot(deviceName: "first", at: time)?.acConnected == true &&
              secondSession.snapshot(deviceName: "second", at: time)?.acConnected == false,
              "Simultaneous session measurements cannot cross station boundaries")
        firstSession.reset()
        check(firstSession.snapshot(deviceName: "first", at: time) == nil &&
              secondSession.snapshot(deviceName: "second", at: time)?.batteryPercentage == 25,
              "Disconnecting one station does not clear the other's authenticated readings")
        print("PASS station discovery merging, private picker labels, USB preference, independent targets and session isolation")
    }

    private static func check(_ condition: Bool, _ message: String) {
        precondition(condition, "FAIL \(message)")
    }
}
