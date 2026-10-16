import AppKit
import Foundation

/// An isolated host for the real production updater. It never starts a power
/// transport or opens the installed Nacho Power application.
@MainActor
final class AutomaticInstallerSmokeDelegate: NSObject, NSApplicationDelegate {
    private let updates = AutomaticAppUpdater()
    private var settingsVisible = true
    private var catVisible = true
    private var scheduledDeferralChecks = false
    private var reportedFailure = false
    private var previousState: AutomaticAppUpdateState?
    private var deadline: Timer?

    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String }
    private var logURL: URL { URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "SmokeLogPath") as! String) }
    private var expectedFailure: Bool { Bundle.main.object(forInfoDictionaryKey: "SmokeExpectedFailure") as? Bool ?? false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        record("launched", extra: ["bundlePath": Bundle.main.bundlePath])
        if version == "2" {
            record("replacementRelaunched")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            return
        }
        updates.installationContext = { [weak self] in
            guard let self else { return (true, true, true) }
            return (self.settingsVisible, self.catVisible, false)
        }
        updates.onChange = { [weak self] in self?.stateChanged() }
        updates.setAutomaticInstallation(true)
        updates.start()
        record("started", extra: ["checks": updates.automaticallyChecksForUpdates,
                                   "automaticInstallation": updates.automaticallyInstallsUpdates])
        deadline = Timer.scheduledTimer(withTimeInterval: 100, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.record("timedOut", extra: ["status": self?.updates.statusText ?? "unknown"])
                NSApp.terminate(nil)
            }
        }
    }

    private func stateChanged() {
        if previousState != updates.state {
            previousState = updates.state
            record("state", extra: ["state": String(describing: updates.state), "status": updates.statusText])
        }
        if updates.state == .unavailable, !reportedFailure {
            reportedFailure = true
            record("updateRejected", extra: ["error": updates.errorMessage ?? "unknown", "expected": expectedFailure])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
        }
        guard updates.state == .ready, !scheduledDeferralChecks else { return }
        scheduledDeferralChecks = true
        record("downloadValidatedAndPrepared")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.record("settingsDeferralVerified", extra: ["pending": self.updates.hasPendingInstallation,
                                                            "stillOriginalVersion": self.version == "1"])
            self.settingsVisible = false
            self.updates.reevaluateAutomaticInstallation()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                self.record("catDeferralVerified", extra: ["pending": self.updates.hasPendingInstallation,
                                                           "stillOriginalVersion": self.version == "1"])
                self.catVisible = false
                self.record("safeToInstall")
                self.updates.reevaluateAutomaticInstallation()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { record("terminating") }

    private func record(_ event: String, extra: [String: Any] = [:]) {
        var row = extra
        row["event"] = event
        row["version"] = version
        row["pid"] = ProcessInfo.processInfo.processIdentifier
        row["time"] = Date().timeIntervalSince1970
        guard var data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        data.append(0x0a)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        guard let file = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? file.close() }
        try? file.seekToEnd()
        try? file.write(contentsOf: data)
    }
}

@main
struct AutomaticInstallerSmoke {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AutomaticInstallerSmokeDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
