import AppKit
import Foundation

@main struct OverlaySmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let previewMode = CommandLine.arguments.contains("--preview")
        let interruptIntro = CommandLine.arguments.contains("--interrupt-intro")
        let restartDuringPop = CommandLine.arguments.contains("--restart-during-pop")
        let overlay = CatOverlayController(assetDirectory: directory)
        overlay.updateAppearance(width: 320, corner: .bottomRight, fullScreen: false)
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
