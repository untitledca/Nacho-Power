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
                .help("Checks GitHub once a day while Nacho Power is running. Updates are installed only when you choose to download and replace the app.")
            Text(statusText)
                .font(.system(size: 12))
                .foregroundStyle(updates.state == .unavailable ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
        case .notChecked: return "Daily checks let you know when a new GitHub installer is available."
        case .checking: return "Checking GitHub for the latest version…"
        case .current: return "You’re up to date."
        case .updateAvailable: return "A new version of Nacho Power is ready."
        case .unavailable: return updates.errorMessage ?? "Couldn’t check right now. Try again or open GitHub releases."
        }
    }
}
