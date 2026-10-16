import Foundation

@main
private struct AutomaticUpdateChecks {
    @MainActor
    static func main() {
        checkPreferenceMigration()
        checkPreferenceChanges()
        checkDeferredInstallation()
        print("PASS automatic-update consent migration, opt-out, safe deferral, cancellation, and single installation")
    }

    private static func checkPreferenceMigration() {
        let domain = "NachoPower.AutomaticUpdateChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        func reset() { defaults.removePersistentDomain(forName: domain) }
        typealias Preferences = AutomaticUpdatePreferences

        check(Preferences.legacyChecksToMigrate(in: defaults) == nil,
              "fresh install has no implicit automatic-update permission")
        for legacy in [false, true] {
            reset()
            defaults.set(legacy, forKey: Preferences.legacyChecksKey)
            check(Preferences.legacyChecksToMigrate(in: defaults) == legacy,
                  "explicit check-only choice can migrate")
            check(defaults.object(forKey: Preferences.sparkleDownloadsKey) == nil,
                  "check-only permission cannot become permission to download and install")

            for existingChecks in [false, true] {
                for existingDownloads in [false, true] {
                    defaults.set(existingChecks, forKey: Preferences.sparkleChecksKey)
                    defaults.set(existingDownloads, forKey: Preferences.sparkleDownloadsKey)
                    check(Preferences.legacyChecksToMigrate(in: defaults) == nil,
                          "a previous Sparkle choice always wins over the older check-only setting")
                    check(defaults.bool(forKey: Preferences.sparkleChecksKey) == existingChecks
                          && defaults.bool(forKey: Preferences.sparkleDownloadsKey) == existingDownloads,
                          "migration lookup cannot rewrite existing opt-in or opt-out")
                }
            }
        }
        reset()
        defaults.set("not a Boolean", forKey: Preferences.legacyChecksKey)
        check(Preferences.legacyChecksToMigrate(in: defaults) == nil,
              "malformed legacy value grants no permission")
    }

    private static func checkPreferenceChanges() {
        var preferences = AutomaticUpdatePreferences(checks: false, downloads: false)
        preferences.setChecks(true)
        check(preferences == .init(checks: true, downloads: false),
              "enabling checks alone never enables installation")
        preferences.setDownloads(true)
        check(preferences == .init(checks: true, downloads: true),
              "explicit automatic-install opt-in enables its prerequisite checks")
        preferences.setChecks(false)
        check(preferences == .init(checks: false, downloads: false),
              "turning checks off also revokes future automatic-download permission")
        preferences.setChecks(true)
        check(!preferences.downloads, "re-enabling checks does not restore revoked installation consent")
        preferences.setDownloads(true)
        preferences.setDownloads(false)
        check(preferences == .init(checks: true, downloads: false),
              "users can retain check-only behavior after opting out of installation")
        preferences.setChecks(false)
        preferences.setDownloads(true)
        check(preferences == .init(checks: true, downloads: true),
              "explicit full automatic opt-in works from an entirely disabled state")
    }

    @MainActor
    private static func checkDeferredInstallation() {
        let safe = AutomaticInstallConditions(updaterRunning: true, automaticChecks: true,
            automaticDownloads: true, settingsVisible: false, catVisible: false, interactionActive: false)
        let pending = PendingAutomaticInstallation()
        var installations = 0
        check(!pending.isPending && !pending.attempt(when: safe) && !pending.installNow(),
              "no installer continuation means no installation")
        pending.prepare { installations += 1 }

        var stopped = safe; stopped.updaterRunning = false
        var checksDisabled = safe; checksDisabled.automaticChecks = false
        var downloadsDisabled = safe; downloadsDisabled.automaticDownloads = false
        var settingsOpen = safe; settingsOpen.settingsVisible = true
        var catActive = safe; catActive.catVisible = true
        var userActive = safe; userActive.interactionActive = true
        for (reason, blocked) in [
            ("updater stopped", stopped), ("checks opted out", checksDisabled),
            ("installation opted out", downloadsDisabled), ("settings open", settingsOpen),
            ("cat reminder active", catActive), ("user interaction active", userActive)
        ] {
            check(!pending.attempt(when: blocked) && pending.isPending && installations == 0,
                  "downloaded update remains deferred while \(reason)")
        }
        check(pending.attempt(when: safe) && installations == 1 && !pending.isPending,
              "once every blocker clears and consent remains enabled, install once")
        check(!pending.attempt(when: safe) && !pending.installNow() && installations == 1,
              "timer/menu duplicate triggers cannot repeat a consumed installation")

        pending.prepare { installations += 1 }
        check(!pending.attempt(when: downloadsDisabled) && installations == 1,
              "opting out after download prevents automatic relaunch")
        check(pending.attempt(when: safe) && installations == 2,
              "opting back in can resume a deferred downloaded update")

        pending.prepare { installations += 1 }
        pending.clear()
        check(!pending.isPending && !pending.attempt(when: safe) && !pending.installNow() && installations == 2,
              "clearing a stopped or aborted update prevents stale callbacks from installing")

        pending.prepare { installations += 100 }
        pending.prepare { installations += 1 }
        check(pending.installNow() && installations == 3,
              "replacing the staged continuation makes only the latest update eligible")

        pending.prepare {
            check(!pending.isPending && !pending.attempt(when: safe) && !pending.installNow(),
                  "continuation is consumed before calling code that may re-enter")
            installations += 1
        }
        check(pending.attempt(when: safe) && installations == 4, "reentrant callbacks cannot install twice")

        pending.prepare { installations += 1 }
        check(!pending.attempt(when: downloadsDisabled), "manual-install fixture has automatic updates disabled")
        check(pending.installNow() && installations == 5,
              "explicit manual installation remains available after automatic opt-out")
    }

    private static func check(_ condition: Bool, _ message: String) {
        precondition(condition, "FAIL \(message)")
    }
}
