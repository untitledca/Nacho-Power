import AppKit
import Foundation

@main struct OverlaySmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let previewMode = CommandLine.arguments.contains("--preview")
        let overlay = CatOverlayController(assetDirectory: directory)
        var entries: [[String: Any]] = []
        let started = Date()
        var finishing = false
        var sawReadyVideo = false
        var sawMiddle = false
        var sawOutro = false
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
        overlay.onOutroFinished = {
            record("outro finished")
            guard sawReadyVideo, sawMiddle, sawOutro, !overlay.isVisible, overlay.playbackState == .hidden else {
                record("ERROR: incomplete playback or teardown")
                exit(3)
            }
            exit(0)
        }
        if previewMode { overlay.preview() } else { overlay.startReminder() }
        record(previewMode ? "preview started" : "started")
        let flags = overlay.diagnostics
        guard flags["ignoresMouseEvents"] as? Bool == true, flags["opaque"] as? Bool == false,
              flags["canBecomeKey"] as? Bool == false, flags["canBecomeMain"] as? Bool == false,
              flags["movable"] as? Bool == false else {
            record("ERROR: overlay intercepts interaction or is opaque")
            exit(4)
        }
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                record("sample")
                sawReadyVideo = sawReadyVideo || overlay.diagnostics["videoReady"] as? Bool == true
                sawMiddle = sawMiddle || overlay.playbackState == .middle
                sawOutro = sawOutro || overlay.playbackState == .outro
                let loops = overlay.diagnostics["loopCount"] as? Int ?? 0
                if !previewMode, loops >= 2, !finishing {
                    finishing = true
                    overlay.finishReminder()
                    record("finish requested")
                }
                if Date().timeIntervalSince(started) > 35 {
                    record("ERROR: timed out")
                    exit(2)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        app.run()
    }
}
