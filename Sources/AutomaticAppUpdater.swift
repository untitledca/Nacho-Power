import AppKit
import Combine
import Sparkle

enum AutomaticAppUpdateState: Equatable {
    case idle, checking, current, updateAvailable, downloading, ready, installing, unavailable
}

@MainActor
final class AutomaticAppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let releasesURL = URL(string: "https://github.com/untitledca/Nacho-Power/releases")!

    @Published private(set) var state: AutomaticAppUpdateState = .idle
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyInstallsUpdates = false
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var availableVersion: String?
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasPendingInstallation = false
    @Published private(set) var currentStatus = "No new compatible update was found."

    let currentVersion: String
    var onChange: (() -> Void)?
    /// Read at installation time, not at download time: the user may have
    /// opened Settings or a new power reminder may have appeared meanwhile.
    var installationContext: () -> (settingsVisible: Bool, catVisible: Bool, interactionActive: Bool) = {
        (true, true, true)
    }

    private var controller: SPUStandardUpdaterController!
    private var observations: [NSKeyValueObservation] = []
    private let pendingInstallation = PendingAutomaticInstallation()
    private var isStarted = false
    private var isApplyingPreferences = false

    init(defaults: UserDefaults = .standard) {
        currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        let updater = controller.updater
        if let legacyChecks = AutomaticUpdatePreferences.legacyChecksToMigrate(in: defaults) {
            // The old checkbox only authorized checking, never installation.
            updater.automaticallyChecksForUpdates = legacyChecks
        }
        observations = [
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshSettings() }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshSettings() }
            },
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshSettings() }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshSettings() }
            }
        ]
    }

    func start() {
        guard !isStarted else { return }
        do {
            // Use the underlying supported start API so configuration errors can
            // be reported in Settings as well as in the standard updater UI.
            try controller.updater.start()
            isStarted = true
            refreshSettings()
        } catch {
            showError(error)
        }
    }

    func stop() {
        isStarted = false
        pendingInstallation.clear()
        hasPendingInstallation = false
    }

    func setAutomaticChecks(_ enabled: Bool) {
        var preferences = currentPreferences
        preferences.setChecks(enabled)
        apply(preferences)
    }

    func setAutomaticInstallation(_ enabled: Bool) {
        var preferences = currentPreferences
        preferences.setDownloads(enabled)
        apply(preferences)
    }

    func checkForUpdates() {
        guard isStarted, controller.updater.canCheckForUpdates else { return }
        errorMessage = nil
        controller.checkForUpdates(nil)
    }

    func installPendingUpdate() {
        guard isStarted, pendingInstallation.isPending else { return }
        // This explicit button is also available after automatic installation
        // was turned off while an update was already prepared by Sparkle.
        state = .installing
        hasPendingInstallation = false
        onChange?()
        pendingInstallation.installNow()
    }

    func reevaluateAutomaticInstallation() {
        guard pendingInstallation.isPending else { return }
        let context = installationContext()
        let conditions = AutomaticInstallConditions(
            updaterRunning: isStarted,
            automaticChecks: controller.updater.automaticallyChecksForUpdates,
            automaticDownloads: controller.updater.automaticallyDownloadsUpdates,
            settingsVisible: context.settingsVisible,
            catVisible: context.catVisible,
            interactionActive: context.interactionActive
        )
        guard conditions.permitsAutomaticInstall else { return }
        state = .installing
        hasPendingInstallation = false
        onChange?()
        pendingInstallation.attempt(when: conditions)
    }

    var statusText: String {
        switch state {
        case .idle: return "No update check yet."
        case .checking: return "Checking for updates…"
        case .current: return currentStatus
        case .updateAvailable: return "Nacho Power \(availableVersion ?? "update") is available."
        case .downloading: return "Downloading and preparing the update…"
        case .ready:
            return automaticallyChecksForUpdates && automaticallyInstallsUpdates
                ? "Update downloaded. It will install and relaunch when Settings is closed and the cat is hidden."
                : "Update already downloaded. It will install when you quit, or choose Install & Relaunch."
        case .installing: return "Installing the update and relaunching Nacho Power…"
        case .unavailable: return errorMessage ?? "Couldn’t check for updates. Try again."
        }
    }

    private var currentPreferences: AutomaticUpdatePreferences {
        AutomaticUpdatePreferences(checks: controller.updater.automaticallyChecksForUpdates,
                                   downloads: controller.updater.automaticallyDownloadsUpdates)
    }

    private func apply(_ preferences: AutomaticUpdatePreferences) {
        let updater = controller.updater
        isApplyingPreferences = true
        // Turn downloading off first when disabling. Turn checks on before
        // enabling downloads because Sparkle ties availability to checking.
        if !preferences.downloads && updater.automaticallyDownloadsUpdates {
            updater.automaticallyDownloadsUpdates = false
        }
        if updater.automaticallyChecksForUpdates != preferences.checks {
            updater.automaticallyChecksForUpdates = preferences.checks
        }
        if updater.automaticallyDownloadsUpdates != preferences.downloads {
            updater.automaticallyDownloadsUpdates = preferences.downloads
        }
        isApplyingPreferences = false
        refreshSettings()
    }

    private func refreshSettings() {
        guard !isApplyingPreferences else { return }
        let updater = controller.updater
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyInstallsUpdates = updater.automaticallyDownloadsUpdates
        canCheckForUpdates = isStarted && updater.canCheckForUpdates
        lastCheckedAt = updater.lastUpdateCheckDate
        onChange?()
        // KVO also catches choices made in Sparkle's own update window.
        reevaluateAutomaticInstallation()
    }

    private func showError(_ error: Error) {
        pendingInstallation.clear()
        hasPendingInstallation = false
        errorMessage = error.localizedDescription
        state = .unavailable
        onChange?()
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        errorMessage = nil
        state = .checking
        onChange?()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
        state = .updateAvailable
        onChange?()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        availableVersion = nil
        errorMessage = nil
        let reason = ((error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue
        switch reason {
        case Int(SPUNoUpdateFoundReason.onLatestVersion.rawValue),
             Int(SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue):
            currentStatus = "You’re up to date."
        case Int(SPUNoUpdateFoundReason.systemIsTooOld.rawValue):
            currentStatus = "The newer release requires a newer version of macOS."
        case Int(SPUNoUpdateFoundReason.systemIsTooNew.rawValue),
             Int(SPUNoUpdateFoundReason.hardwareDoesNotSupportARM64.rawValue):
            currentStatus = "No newer release is compatible with this Mac."
        default:
            currentStatus = "No new compatible update was found."
        }
        state = .current
        onChange?()
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        state = .downloading
        onChange?()
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        availableVersion = item.displayVersionString
        state = .ready
        // Returning true retains this Sparkle session until its continuation is
        // invoked. Sparkle still installs on a normal quit in either case.
        pendingInstallation.prepare(install: immediateInstallHandler)
        hasPendingInstallation = true
        onChange?()
        // Run after returning true, and after any window visibility callbacks
        // in this run-loop have completed.
        DispatchQueue.main.async { [weak self] in self?.reevaluateAutomaticInstallation() }
        return true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        state = .installing
        onChange?()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error {
            let nsError = error as NSError
            if nsError.domain == SUSparkleErrorDomain && nsError.code == SUError.noUpdateError.rawValue {
                updaterDidNotFindUpdate(updater, error: error)
            } else if nsError.domain == SUSparkleErrorDomain && nsError.code == SUError.installationCanceledError.rawValue {
                pendingInstallation.clear()
                hasPendingInstallation = false
                state = availableVersion == nil ? .idle : .updateAvailable
            } else {
                showError(error)
            }
        } else if state == .checking {
            state = .idle
        } else if state == .downloading {
            // A cancelled download can finish without an error.
            state = .updateAvailable
        }
        refreshSettings()
    }
}
