import Foundation

/// Keeps migration from the older check-only setting separate from consent to
/// download an update, replace the application, and relaunch it.
struct AutomaticUpdatePreferences: Equatable {
    static let legacyChecksKey = "automaticallyChecksForUpdates"
    static let sparkleChecksKey = "SUEnableAutomaticChecks"
    static let sparkleDownloadsKey = "SUAutomaticallyUpdate"

    var checks: Bool
    var downloads: Bool

    static func legacyChecksToMigrate(in defaults: UserDefaults) -> Bool? {
        guard defaults.object(forKey: sparkleChecksKey) == nil else { return nil }
        return defaults.object(forKey: legacyChecksKey) as? Bool
    }

    mutating func setChecks(_ enabled: Bool) {
        checks = enabled
        if !enabled { downloads = false }
    }

    mutating func setDownloads(_ enabled: Bool) {
        downloads = enabled
        if enabled { checks = true }
    }
}

struct AutomaticInstallConditions {
    var updaterRunning: Bool
    var automaticChecks: Bool
    var automaticDownloads: Bool
    var settingsVisible: Bool
    var catVisible: Bool
    var interactionActive: Bool

    var permitsAutomaticInstall: Bool {
        updaterRunning && automaticChecks && automaticDownloads
            && !settingsVisible && !catVisible && !interactionActive
    }
}

/// Sparkle owns the download and installer. We retain only its supported
/// continuation while the user is editing settings or a cat reminder is active.
@MainActor
final class PendingAutomaticInstallation {
    private var install: (() -> Void)?
    var isPending: Bool { install != nil }

    func prepare(install: @escaping () -> Void) { self.install = install }

    @discardableResult
    func attempt(when conditions: AutomaticInstallConditions) -> Bool {
        guard conditions.permitsAutomaticInstall else { return false }
        return installNow()
    }

    @discardableResult
    func installNow() -> Bool {
        guard let action = install else { return false }
        install = nil
        action()
        return true
    }

    func clear() { install = nil }
}
