import AppKit
import Foundation

@main struct OverlaySmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        if CommandLine.arguments.contains("--switch-sides") {
            SideSwitchSmoke(directory: directory, output: output).run()
            app.run()
            return
        }
        let cornerName = CommandLine.arguments.first(where: { $0.hasPrefix("--corner=") })?.dropFirst("--corner=".count)
        let corner = cornerName.flatMap { OverlayCorner(rawValue: String($0)) } ?? .bottomRight
        let previewMode = CommandLine.arguments.contains("--preview")
        let interruptIntro = CommandLine.arguments.contains("--interrupt-intro")
        let restartDuringPop = CommandLine.arguments.contains("--restart-during-pop")
        let overlay = CatOverlayController(assetDirectory: directory)
        overlay.updateAppearance(width: 320, corner: corner, fullScreen: false)
        var entries: [[String: Any]] = []
        let started = Date()
        var finishRequestedAt: Date?
        var sawReadyVideo = false
        var sawLoop = false
        var sawPop = false
        var didRestart = false
        func record(_ event: String) {
            var row = overlay.diagnostics
            row["event"] = event
            row["elapsed"] = Date().timeIntervalSince(started)
            entries.append(row)
            if let data = try? JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output, options: .atomic)
            }
        }
        overlay.onPlaybackError = { error in
            record("ERROR: \(error)")
            exit(1)
        }
        overlay.onDismissalFinished = {
            record("pop finished")
            let promptly = finishRequestedAt.map { Date().timeIntervalSince($0) < 0.6 } ?? false
            guard sawReadyVideo, sawPop, (interruptIntro || sawLoop), promptly,
                  (!restartDuringPop || didRestart), !overlay.isVisible, overlay.playbackState == .hidden else {
                record("ERROR: incomplete playback, delayed dismissal, or teardown failure")
                exit(3)
            }
            exit(0)
        }
        if previewMode { overlay.preview() } else { overlay.startReminder() }
        record(previewMode ? "preview started" : "started")
        let flags = overlay.diagnostics
        guard flags["ignoresMouseEvents"] as? Bool == true, flags["opaque"] as? Bool == false,
              flags["canBecomeKey"] as? Bool == false, flags["canBecomeMain"] as? Bool == false,
              flags["movable"] as? Bool == false, flags["muted"] as? Bool == true else {
            record("ERROR: overlay intercepts interaction, is opaque, or has audio")
            exit(4)
        }
        var sampleCount = 0
        let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated {
                sampleCount += 1
                if sampleCount % 10 == 0 { record("sample") }
                sawReadyVideo = sawReadyVideo || overlay.diagnostics["videoReady"] as? Bool == true
                sawLoop = sawLoop || overlay.playbackState == .loop
                if overlay.playbackState == .intro || overlay.playbackState == .loop {
                    let expectedVideo = overlay.playbackState == .intro ? corner.videoSide.intro : corner.videoSide.loop
                    guard overlay.diagnostics["activeSide"] as? String == corner.videoSide.rawValue,
                          overlay.diagnostics["currentVideo"] as? String == expectedVideo + ".mov",
                          overlay.diagnostics["mirrored"] as? Bool == false else {
                        record("ERROR: wrong side asset or mirrored playback")
                        exit(7)
                    }
                }
                if overlay.playbackState == .dismissing {
                    sawPop = true
                    if finishRequestedAt == nil { finishRequestedAt = Date() }
                    guard overlay.diagnostics["playerRate"] as? Float == 0,
                          overlay.diagnostics["hasPopAnimation"] as? Bool == true else {
                        record("ERROR: pop did not stop playback immediately")
                        exit(5)
                    }
                    if restartDuringPop, !didRestart,
                       let requested = finishRequestedAt, Date().timeIntervalSince(requested) > 0.05 {
                        overlay.startReminder()
                        didRestart = true
                        finishRequestedAt = nil
                        sawPop = false
                        sawLoop = false
                        record("new reminder interrupted previous pop")
                    }
                }
                let loops = overlay.diagnostics["loopCount"] as? Int ?? 0
                let introReady = interruptIntro && sawReadyVideo && Date().timeIntervalSince(started) > 0.6
                if !previewMode, finishRequestedAt == nil, introReady || loops >= 1 {
                    if interruptIntro, overlay.playbackState != .intro {
                        record("ERROR: intro finished before interruption test")
                        exit(6)
                    }
                    finishRequestedAt = Date()
                    overlay.finishReminder()
                    record("finish requested")
                }
                if Date().timeIntervalSince(started) > 120 {
                    record("ERROR: timed out")
                    exit(2)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        app.run()
    }
}

/// Exercises actual queue replacements, timing, preview ownership, and the pop.
/// Uses each orientation's real duration, so different-length clips are covered.
@MainActor private final class SideSwitchSmoke {
    private let overlay: CatOverlayController
    private let output: URL
    private let started = Date()
    private var entries: [[String: Any]] = []
    private var visibilityEvents: [Bool] = []
    private var step = 0
    private var expectedFraction = 0.0
    private var finishRequestedAt: Date?
    private var timer: Timer?

    init(directory: URL, output: URL) {
        self.output = output
        overlay = CatOverlayController(assetDirectory: directory)
    }

    func run() {
        overlay.onPlaybackError = { [self] in fail($0) }
        overlay.onVisibilityChanged = { [self] in visibilityEvents.append($0) }
        overlay.onDismissalFinished = { [self] in
            guard step == 7, !overlay.isVisible,
                  visibilityEvents == [true, false],
                  finishRequestedAt.map({ Date().timeIntervalSince($0) < 0.6 }) == true else {
                fail("side changes disrupted visibility, dismissal, or preview lifecycle")
            }
            record("PASS side switching and dismissal")
            exit(0)
        }
        move(to: .bottomRight)
        overlay.preview()
        record("right intro started")
        timer = Timer(timeInterval: 0.02, repeats: true) { [self] _ in
            MainActor.assumeIsolated { sample() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func sample() {
        if Date().timeIntervalSince(started) > 120 { fail("side switching timed out at step \(step)") }
        if overlay.diagnostics["mirrored"] as? Bool == true { fail("asset was horizontally mirrored") }
        switch step {
        case 0:
            guard ready(.right, .intro), elapsed > 0.5 else { return }
            expectedFraction = fraction
            move(to: .bottomLeft)
            step = 1
        case 1:
            guard ready(.left, .intro) else { return }
            verifySwap("intro_left.mov", phase: .intro)
            verifyVerticalMove(to: .topLeft)
            expectedFraction = fraction
            move(to: .topRight)
            step = 2
        case 2:
            guard ready(.right, .intro) else { return }
            verifySwap("intro.mov", phase: .intro)
            record("right intro progress restored")
            step = 3
        case 3:
            guard ready(.right, .loop), elapsed > 0.5 else { return }
            expectedFraction = fraction
            move(to: .topLeft)
            step = 4
        case 4:
            guard ready(.left, .loop) else { return }
            verifySwap("looping_left.mov", phase: .loop)
            verifyVerticalMove(to: .bottomLeft)
            expectedFraction = fraction
            move(to: .bottomRight)
            step = 5
        case 5:
            guard ready(.right, .loop) else { return }
            verifySwap("loop.mov", phase: .loop)
            // A rapid left→right→left request must settle on the final selection.
            expectedFraction = fraction
            move(to: .topLeft)
            move(to: .topRight)
            move(to: .bottomLeft)
            step = 6
        case 6:
            guard ready(.left, .loop) else { return }
            verifySwap("looping_left.mov", phase: .loop)
            guard overlay.isPreviewing, visibilityEvents == [true] else { fail("swaps ended the preview") }
            finishRequestedAt = Date()
            overlay.finishReminder()
            move(to: .bottomRight)
            guard overlay.playbackState == .dismissing,
                  overlay.diagnostics["activeSide"] as? String == "left",
                  overlay.diagnostics["playerRate"] as? Float == 0,
                  overlay.diagnostics["hasPopAnimation"] as? Bool == true else {
                fail("a side change during the pop restarted playback or replaced its frozen frame")
            }
            record("pop retains left frame after selecting right")
            step = 7
        default: break
        }
    }

    private var elapsed: Double { overlay.diagnostics["playbackTime"] as? Double ?? 0 }
    private var fraction: Double { overlay.diagnostics["playbackFraction"] as? Double ?? 0 }
    private func move(to corner: OverlayCorner) {
        overlay.updateAppearance(width: 320, corner: corner, fullScreen: false)
    }
    private func ready(_ side: OverlayVideoSide, _ phase: CatOverlayController.PlaybackState) -> Bool {
        overlay.playbackState == phase && overlay.diagnostics["activeSide"] as? String == side.rawValue &&
        overlay.diagnostics["playerRate"] as? Float == 1 && overlay.diagnostics["videoReady"] as? Bool == true
    }
    private func verifySwap(_ filename: String, phase: CatOverlayController.PlaybackState) {
        guard overlay.playbackState == phase,
              overlay.diagnostics["currentVideo"] as? String == filename,
              abs(fraction - expectedFraction) < 0.12,
              overlay.isPreviewing, visibilityEvents == [true] else {
            fail("asset swap changed stage/progress/preview: expected \(filename) at fraction \(expectedFraction), got \(fraction)")
        }
        record("switched to \(filename)")
    }
    private func verifyVerticalMove(to corner: OverlayCorner) {
        let old = overlay.diagnostics
        move(to: corner)
        guard overlay.diagnostics["playbackGeneration"] as? Int == old["playbackGeneration"] as? Int,
              overlay.diagnostics["currentVideo"] as? String == old["currentVideo"] as? String,
              overlay.diagnostics["playerRate"] as? Float == 1 else {
            fail("moving vertically restarted the current clip")
        }
        record("same-side vertical move preserves queue")
    }
    private func record(_ event: String) {
        var entry = overlay.diagnostics
        entry["event"] = event
        entry["elapsed"] = Date().timeIntervalSince(started)
        entries.append(entry)
        if let data = try? JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output, options: .atomic)
        }
    }
    private func fail(_ error: String) -> Never {
        record("ERROR: " + error)
        fputs("FAIL \(error)\n", stderr)
        exit(8)
    }
}
