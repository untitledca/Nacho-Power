import AppKit
import Foundation

/// Runs the real transparent AppKit panels and AVQueuePlayers against a changing
/// display inventory. The inventory is synthetic; the video and window behavior
/// are production code, and this executable never starts a power connection.
@main
private struct MultiDisplayOverlaySmoke {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 3 else {
            fputs("Usage: multi-display-smoke <asset directory> <JSON output>\n", stderr)
            exit(64)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let smoke = DisplaySmoke(
            directory: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true),
            output: URL(fileURLWithPath: CommandLine.arguments[2]))
        smoke.run()
        app.run()
    }
}

@MainActor
private final class DisplaySmoke {
    private let primary = OverlayDisplay(id: "test-primary", name: "Test primary",
        frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: NSRect(x: 0, y: 24, width: 1440, height: 850))
    private let external = OverlayDisplay(id: "test-external", name: "Test external",
        frame: NSRect(x: -1920, y: 120, width: 1920, height: 1080),
        visibleFrame: NSRect(x: -1920, y: 144, width: 1920, height: 1030))
    private let portrait = OverlayDisplay(id: "test-portrait", name: "Test portrait",
        frame: NSRect(x: 1440, y: -600, width: 1080, height: 1920),
        visibleFrame: NSRect(x: 1440, y: -576, width: 1080, height: 1870))
    private var inventory: [OverlayDisplay] = []
    private var overlay: CatOverlayController!
    private let output: URL
    private let started = Date()
    private var entries: [[String: Any]] = []
    private var visibility: [Bool] = []
    private var dismissals = 0
    private var stage = 0
    private var expectedFraction = 0.0
    private var finishRequestedAt: Date?
    private var observedPreviewLoopCounts: [String: Int] = [:]
    private var timer: Timer?

    init(directory: URL, output: URL) {
        self.output = output
        inventory = [primary, external]
        overlay = CatOverlayController(assetDirectory: directory, displays: { [weak self] in
            self?.inventory ?? []
        })
    }

    func run() {
        overlay.onPlaybackError = { [self] in fail($0) }
        overlay.onVisibilityChanged = { [self] in visibility.append($0) }
        overlay.onDismissalFinished = { [self] in dismissed() }
        configure(selection: external.id, fullScreen: true, side: .left, corner: .bottomRight)
        overlay.startReminder()
        record("selected external display, full-screen From Left")
        timer = Timer(timeInterval: 0.02, repeats: true) { [self] _ in
            MainActor.assumeIsolated { sample() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func sample() {
        if Date().timeIntervalSince(started) > 100 { fail("timed out at stage \(stage)") }
        for row in rows where row["visible"] as? Bool == true { verifyWindowFlags(row) }
        switch stage {
        case 0:
            guard ready(ids: [external.id], side: .left, phase: .intro), fraction(external.id) > 0.035 else { return }
            verifyFullFrames([external])
            expectedFraction = fraction(external.id)
            configure(selection: external.id, fullScreen: true, side: .right, corner: .bottomLeft)
            stage = 1
        case 1:
            guard ready(ids: [external.id], side: .right, phase: .intro) else { return }
            checkProgress(external.id, expected: expectedFraction)
            let before = row(external.id)
            configure(selection: external.id, fullScreen: true, side: .right, corner: .topLeft)
            check(row(external.id)["playbackGeneration"] as? Int == before["playbackGeneration"] as? Int,
                  "changing a corner must not restart explicitly selected full-screen direction")
            expectedFraction = fraction(external.id)
            configure(selection: "all", fullScreen: true, side: .right, corner: .topLeft)
            record("full-screen direction ignores corner; expand to all displays")
            stage = 2
        case 2:
            guard ready(ids: [primary.id, external.id], side: .right, phase: .intro) else { return }
            verifyFullFrames([primary, external])
            checkProgress(primary.id, expected: fraction(external.id))
            let generations = generationMap()
            inventory = [external, primary]
            overlay.refreshDisplays()
            check(generationMap() == generations, "reordering displays restarted a player or lost stable identity")
            configure(selection: external.id, fullScreen: true, side: .right, corner: .topLeft)
            check(ids == Set([external.id]), "selecting one display retained an unwanted panel")
            expectedFraction = fraction(external.id)
            inventory = [primary]
            overlay.refreshDisplays()
            record("display order preserves UUID; missing selected display falls back")
            stage = 3
        case 3:
            guard ready(ids: [primary.id], side: .right, phase: .intro) else { return }
            checkProgress(primary.id, expected: expectedFraction)
            verifyFullFrames([primary])
            expectedFraction = fraction(primary.id)
            inventory = [primary, external]
            overlay.refreshDisplays()
            stage = 4
        case 4:
            guard ready(ids: [external.id], side: .right, phase: .intro) else { return }
            checkProgress(external.id, expected: expectedFraction)
            expectedFraction = fraction(external.id)
            configure(selection: "all", fullScreen: false, side: .right, corner: .bottomLeft)
            record("selected display restored; corner mode uses its own left-side assets")
            stage = 5
        case 5:
            guard ready(ids: [primary.id, external.id], side: .left, phase: .intro) else { return }
            checkProgress(external.id, expected: expectedFraction)
            verifyCornerFrames([primary, external], corner: .bottomLeft)
            let generations = generationMap()
            configure(selection: "all", fullScreen: false, side: .right, corner: .topLeft)
            check(generationMap() == generations, "same-side vertical position change replaced a player queue")
            verifyCornerFrames([primary, external], corner: .topLeft)
            configure(selection: "all", fullScreen: true, side: .left, corner: .topRight)
            check(generationMap() == generations, "same effective side full-screen toggle restarted playback")
            verifyFullFrames([primary, external])
            stage = 6
        case 6:
            guard ready(ids: [primary.id, external.id], side: .left, phase: .loop), fraction(external.id) > 0.05 else { return }
            expectedFraction = fraction(external.id)
            inventory.append(portrait)
            overlay.refreshDisplays()
            record("new portrait display joins an existing loop")
            stage = 7
        case 7:
            guard ready(ids: [primary.id, external.id, portrait.id], side: .left, phase: .loop) else { return }
            checkProgress(portrait.id, expected: fraction(external.id))
            verifyFullFrames([primary, external, portrait])
            check(visibility == [true], "changing display selection disrupted aggregate visibility")
            finishRequestedAt = Date()
            stage = 8
            overlay.finishReminder()
            check(overlay.playbackState == .dismissing, "finish did not begin the aggregate pop")
            for display in [primary, external, portrait] {
                let state = row(display.id)
                check(state["playerRate"] as? Float == 0 && state["hasPopAnimation"] as? Bool == true,
                      "\(display.name) did not freeze and pop immediately")
            }
            // A settings change or a display disappearing during dismissal cannot
            // create a new playing panel or restart an intro.
            configure(selection: external.id, fullScreen: true, side: .right, corner: .topRight)
            inventory = [primary, portrait]
            overlay.refreshDisplays()
            check(overlay.playbackState == .dismissing || overlay.playbackState == .hidden,
                  "display change during the pop restarted playback")
            for state in rows {
                check(state["playerRate"] as? Float == 0, "display change during the pop restarted a video")
            }
            record("all screens frozen immediately; selection and unplug during pop")
        case 9:
            guard ready(ids: [primary.id, external.id, portrait.id], side: .left, phase: .intro) else { return }
            check(overlay.isPreviewing, "preview ownership was lost")
            verifyFullFrames([primary, external, portrait])
            record("all-display preview started")
            stage = 10
        case 10:
            for state in rows {
                guard let id = state["displayID"] as? String else { continue }
                observedPreviewLoopCounts[id] = max(observedPreviewLoopCounts[id] ?? 0,
                                                  state["loopCount"] as? Int ?? 0)
            }
            if overlay.playbackState == .dismissing {
                finishRequestedAt = finishRequestedAt ?? Date()
                for state in rows {
                    check(state["playerRate"] as? Float == 0, "natural preview completion left another screen playing")
                }
                record("natural two-loop preview dismissal")
                stage = 11
            }
        default: break
        }
    }

    private func dismissed() {
        dismissals += 1
        check(!overlay.isVisible && overlay.playbackState == .hidden,
              "dismissal completion occurred before every panel was hidden")
        check(finishRequestedAt.map { Date().timeIntervalSince($0) < 0.65 } == true,
              "the pop did not finish promptly")
        if stage == 8 {
            check(dismissals == 1 && visibility == [true, false], "first dismissal callback was duplicated")
            record("PASS selected, all, reorder, hot-plug, geometry, direction, and one pop completion")
            // Wait longer than a pop before starting the next preview, detecting
            // stray completions from surfaces removed during that pop.
            stage = 12
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
                check(dismissals == 1, "a removed display produced a delayed second completion")
                inventory = [primary, external, portrait]
                configure(selection: "all", fullScreen: true, side: .left, corner: .bottomRight)
                finishRequestedAt = nil
                stage = 9
                overlay.preview()
            }
        } else if stage == 11 {
            check(dismissals == 2 && visibility == [true, false, true, false],
                  "preview did not produce exactly one aggregate visibility lifecycle")
            check(Set(observedPreviewLoopCounts.keys) == Set([primary.id, external.id, portrait.id]),
                  "a preview surface never reached its loop")
            check(observedPreviewLoopCounts.values.allSatisfy { $0 >= 1 },
                  "the preview stopped before its second loop on a display")
            record("PASS actual playback and natural preview across three displays")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
                check(dismissals == 2, "preview produced duplicate dismissal callbacks")
                print("PASS multi-display selected/all, stable identity, fallback/restore, geometry, direction, hot-plug synchronization, interaction flags, and preview/pop lifecycle")
                exit(0)
            }
        } else {
            fail("unexpected or duplicate dismissal at stage \(stage)")
        }
    }

    private func configure(selection: String, fullScreen: Bool, side: OverlayVideoSide, corner: OverlayCorner) {
        overlay.updateAppearance(width: 320, corner: corner, fullScreen: fullScreen,
                                 fullScreenSide: side, displaySelection: selection)
    }

    private var rows: [[String: Any]] { overlay.diagnostics["displays"] as? [[String: Any]] ?? [] }
    private var ids: Set<String> { Set(rows.compactMap { $0["displayID"] as? String }) }
    private func row(_ id: String) -> [String: Any] {
        guard let row = rows.first(where: { $0["displayID"] as? String == id }) else {
            fail("missing diagnostic row for \(id)")
        }
        return row
    }
    private func fraction(_ id: String) -> Double { row(id)["playbackFraction"] as? Double ?? 0 }
    private func generationMap() -> [String: Int] {
        Dictionary(uniqueKeysWithValues: rows.map {
            ($0["displayID"] as? String ?? "missing", $0["playbackGeneration"] as? Int ?? -1)
        })
    }
    private func ready(ids expected: [String], side: OverlayVideoSide, phase: CatOverlayController.PlaybackState) -> Bool {
        guard ids == Set(expected), overlay.playbackState == phase else { return false }
        return rows.allSatisfy {
            $0["activeSide"] as? String == side.rawValue &&
            $0["playbackState"] as? String == phase.rawValue &&
            $0["playerRate"] as? Float == 1 && $0["videoReady"] as? Bool == true &&
            $0["currentVideo"] as? String == (phase == .intro ? side.intro : side.loop) + ".mov"
        }
    }
    private func verifyWindowFlags(_ state: [String: Any]) {
        check(state["ignoresMouseEvents"] as? Bool == true && state["opaque"] as? Bool == false &&
              state["canBecomeKey"] as? Bool == false && state["canBecomeMain"] as? Bool == false &&
              state["movable"] as? Bool == false && state["muted"] as? Bool == true &&
              state["allSpaces"] as? Bool == true && state["fullscreenAuxiliary"] as? Bool == true &&
              state["mirrored"] as? Bool == false,
              "a panel intercepts interaction, plays audio, mirrors an asset, or has incorrect window behavior")
    }
    private func verifyFullFrames(_ displays: [OverlayDisplay]) {
        for display in displays { checkFrame(row(display.id), expected: display.frame) }
    }
    private func verifyCornerFrames(_ displays: [OverlayDisplay], corner: OverlayCorner) {
        for display in displays {
            let available = display.visibleFrame
            let width: CGFloat = 320
            let height = width * 9 / 16
            let x = corner.videoSide == .left ? available.minX + 16 : available.maxX - width - 16
            let y = corner == .bottomLeft || corner == .bottomRight
                ? available.minY + 16 : available.maxY - height - 16
            checkFrame(row(display.id), expected: NSRect(x: x, y: y, width: width, height: height))
        }
    }
    private func checkFrame(_ state: [String: Any], expected: NSRect) {
        let actual = NSRectFromString(state["windowFrame"] as? String ?? "")
        check(abs(actual.minX - expected.minX) < 1 && abs(actual.minY - expected.minY) < 1 &&
              abs(actual.width - expected.width) < 1 && abs(actual.height - expected.height) < 1,
              "incorrect frame for \(state["displayID"] ?? "display"): \(actual), expected \(expected)")
    }
    private func checkProgress(_ id: String, expected: Double) {
        check(abs(fraction(id) - expected) < 0.12,
              "\(id) lost phase progress: expected \(expected), found \(fraction(id))")
    }
    private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fail(message) }
    }
    private func record(_ event: String) {
        var entry = overlay.diagnostics
        entry["event"] = event
        entry["elapsed"] = Date().timeIntervalSince(started)
        entry["stage"] = stage
        entry["visibilityEvents"] = visibility
        entry["dismissals"] = dismissals
        entries.append(entry)
        if let data = try? JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output, options: .atomic)
        }
    }
    private func fail(_ message: String) -> Never {
        record("ERROR: " + message)
        fputs("FAIL \(message)\n", stderr)
        exit(1)
    }
}
