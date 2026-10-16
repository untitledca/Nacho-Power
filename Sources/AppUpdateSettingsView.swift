import SwiftUI

struct AppUpdateSettingsView: View {
    @ObservedObject var updates: AutomaticAppUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("App updates").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("Version \(updates.currentVersion)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Toggle("Check automatically for updates", isOn: Binding(
                get: { updates.automaticallyChecksForUpdates },
                set: { updates.setAutomaticChecks($0) }
            ))
                .toggleStyle(.switch)
                .help("Checks on launch when due and daily while Nacho Power is running.")
            Toggle("Download and install updates automatically", isOn: Binding(
                get: { updates.automaticallyInstallsUpdates },
                set: { updates.setAutomaticInstallation($0) }
            ))
                .toggleStyle(.switch)
                .help("Also enables automatic checks. Downloads verified updates, then installs and relaunches when Settings is closed and no cat is showing.")
            Text("Checks daily while running and on launch when due. Automatic installation downloads the update, then relaunches Nacho Power when Settings is closed and the cat is hidden. Your settings are kept.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(updates.statusText)
                .font(.system(size: 12))
                .foregroundStyle(updates.state == .unavailable ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let checked = updates.lastCheckedAt {
                Text("Last checked: \(checked.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack {
                Button(updates.state == .checking ? "Checking…" : "Check for Updates") {
                    updates.checkForUpdates()
                }.disabled(!updates.canCheckForUpdates)
                Spacer()
                if updates.hasPendingInstallation {
                    Button("Install & Relaunch") { updates.installPendingUpdate() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Link("Release notes", destination: AutomaticAppUpdater.releasesURL)
                }
            }
            Text("macOS may request permission if the app cannot be replaced automatically.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
