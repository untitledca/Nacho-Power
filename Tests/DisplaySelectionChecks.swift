import AppKit
import Foundation

@main
private struct DisplaySelectionChecks {
    static func main() {
        let primary = display("primary", "Built-in display")
        let external = display("external-uuid", "Studio display")
        let other = display("other-uuid", "Studio display")
        let displays = [primary, external, other]
        typealias Selection = OverlayDisplaySelection

        check(Selection.selectedDisplays(for: Selection.main, from: displays) == [primary],
              "Main display resolves to the primary screen")
        check(Selection.selectedDisplays(for: Selection.all, from: displays) == displays,
              "All displays selects every attached display")
        check(Selection.selectedDisplays(for: external.id, from: displays) == [external],
              "An individual display resolves by its stable ID")
        check(Selection.selectedDisplays(for: external.id, from: [other, primary, external]) == [external],
              "An individual selection is unaffected by display ordering or duplicate names")
        check(Selection.selectedDisplays(for: external.id, from: [primary, other]) == [primary],
              "An unavailable selected display temporarily falls back to the primary display")
        check(Selection.selectedDisplays(for: external.id, from: displays) == [external],
              "A reconnected selected display is restored")
        for selection in [Selection.main, Selection.all, external.id] {
            check(Selection.selectedDisplays(for: selection, from: []).isEmpty,
                  "An empty display inventory is safe for \(selection)")
        }

        let domain = "NachoPower.DisplaySelectionChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        func reset() { defaults.removePersistentDomain(forName: domain) }
        check(Selection.initialSelection(defaults: defaults, displays: displays) == Selection.main,
              "A fresh installation keeps the previous primary-display behavior")
        check(defaults.string(forKey: Selection.defaultsKey) == Selection.main,
              "The initial display choice is persisted")

        for index in [0, -1, 9] {
            reset()
            defaults.set(index, forKey: "animationDisplay")
            check(Selection.initialSelection(defaults: defaults, displays: displays) == Selection.main,
                  "An absent, negative, or out-of-range legacy screen index safely uses the primary display")
        }
        reset()
        defaults.set(1, forKey: "animationDisplay")
        check(Selection.initialSelection(defaults: defaults, displays: displays) == external.id,
              "An existing secondary-display choice migrates to its stable ID")
        check(defaults.string(forKey: Selection.displayNameDefaultsKey) == external.name,
              "The selected display name is retained for a disconnected-display explanation")
        check(Selection.initialSelection(defaults: defaults, displays: [other, primary, external]) == external.id,
              "Migration runs once instead of reinterpreting the old index after display order changes")

        for saved in [Selection.main, Selection.all, external.id, "unplugged-display-uuid"] {
            reset()
            defaults.set(1, forKey: "animationDisplay")
            defaults.set(saved, forKey: Selection.defaultsKey)
            check(Selection.initialSelection(defaults: defaults, displays: [primary]) == saved,
                  "An explicit saved choice survives launch even when its display is unavailable")
            check(defaults.string(forKey: Selection.defaultsKey) == saved,
                  "Resolving a missing display never overwrites the user's selection")
        }
        print("PASS display selection, stable identity, duplicate names, hot-plug fallback, and preference migration")
    }

    private static func display(_ id: String, _ name: String) -> OverlayDisplay {
        OverlayDisplay(id: id, name: name, frame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
                       visibleFrame: NSRect(x: 0, y: 24, width: 1920, height: 1032))
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL \(message)\n", stderr)
            exit(1)
        }
    }
}
