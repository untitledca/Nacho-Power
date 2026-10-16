import AppKit
import CoreGraphics

struct OverlayDisplay: Identifiable, Equatable {
    let id: String
    let name: String
    let frame: NSRect
    let visibleFrame: NSRect

    /// AppKit lists the primary display first. Unlike NSScreen.main, this does
    /// not change when the Settings window moves to another display.
    @MainActor
    static var availableDisplays: [OverlayDisplay] {
        let screens = NSScreen.screens
        let nameCounts = Dictionary(grouping: screens, by: \.localizedName).mapValues(\.count)
        var seenNames: [String: Int] = [:]
        return screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            let id: String
            if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
                id = CFUUIDCreateString(nil, uuid) as String
            } else {
                id = "display-\(displayID)"
            }
            let ordinal = seenNames[screen.localizedName, default: 0] + 1
            seenNames[screen.localizedName] = ordinal
            let name = nameCounts[screen.localizedName, default: 0] > 1
                ? "\(screen.localizedName) (\(ordinal))" : screen.localizedName
            return OverlayDisplay(id: id, name: name, frame: screen.frame, visibleFrame: screen.visibleFrame)
        }
    }
}

enum OverlayDisplaySelection {
    static let main = "main"
    static let all = "all"
    static let defaultsKey = "animationDisplaySelection"
    static let displayNameDefaultsKey = "animationDisplayName"

    static func selectedDisplays(for selection: String, from displays: [OverlayDisplay]) -> [OverlayDisplay] {
        if selection == all { return displays }
        if let display = displays.first(where: { $0.id == selection }) { return [display] }
        return Array(displays.prefix(1))
    }

    /// Old releases saved a screen index. Resolve it once so later display
    /// rearrangements do not move the cat to a different physical monitor.
    static func initialSelection(defaults: UserDefaults, displays: [OverlayDisplay]) -> String {
        if let saved = defaults.string(forKey: defaultsKey), !saved.isEmpty { return saved }
        let previousIndex = defaults.integer(forKey: "animationDisplay")
        let selection = previousIndex > 0 && displays.indices.contains(previousIndex)
            ? displays[previousIndex].id : main
        defaults.set(selection, forKey: defaultsKey)
        if let display = displays.first(where: { $0.id == selection }) {
            defaults.set(display.name, forKey: displayNameDefaultsKey)
        }
        return selection
    }
}
