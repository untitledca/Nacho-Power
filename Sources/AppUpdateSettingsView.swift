import SwiftUI

struct AppUpdateSettingsView: View {
    @ObservedObject var updates: AppUpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("App updates").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("Version \(updates.currentVersion)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Toggle("Check automatically for updates", isOn: $updates.automaticallyChecksForUpdates)
                .toggleStyle(.switch)
                .help("Turning this on checks GitHub immediately. After that, Nacho Power checks daily while running and on launch when a check is due.")
            Text("When enabled, checks now, on launch when due, and daily while Nacho Power is running. You choose when to download and install.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(statusText)
                .font(.system(size: 12))
                .foregroundStyle(updates.state == .unavailable ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let checked = updates.lastCheckedAt {
                Text("Last checked: \(checked.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack {
                Button(updates.state == .checking ? "Checking…" : "Check for Updates") {
                    Task { await updates.checkForUpdates() }
                }.disabled(updates.state == .checking)
                Spacer()
                if updates.state == .updateAvailable, let release = updates.latestRelease {
                    Link("Download \(release.version)", destination: release.downloadURL)
                        .buttonStyle(.borderedProminent)
                } else {
                    Link("GitHub releases", destination: AppUpdateChecker.releasesURL)
                }
            }
            if updates.state == .updateAvailable, let release = updates.latestRelease {
                Text("Download the installer, quit Nacho Power, then replace the app in Applications. Your settings are kept.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link("What’s new", destination: release.releaseURL).font(.system(size: 11))
            }
        }
    }

    private var statusText: String {
        switch updates.state {
        case .notChecked: return "No update check yet."
        case .checking: return "Checking GitHub for the latest version…"
        case .current: return "You’re up to date."
        case .updateAvailable: return "A new version of Nacho Power is ready."
        case .unavailable: return updates.errorMessage ?? "Couldn’t check right now. Try again or open GitHub releases."
        }
    }
}
