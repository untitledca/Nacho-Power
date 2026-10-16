import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem!
    private var model: AppModel!
    private var settingsWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var menuIsOpen = false
    private var dockLogo: NSImage?
    private var lastDockStatus: DockPowerStatus?
    private var dockRefreshTimer: Timer?
    private let updates = AutomaticAppUpdater()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let updateMenuItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateMenuItem.target = self
        appMenu.addItem(updateMenuItem)
        appMenu.addItem(makeSupportMenuItem())
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Nacho Power", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApplication.shared.mainMenu = mainMenu
        let assetDirectory = Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Assets")
        model = AppModel(assetDirectory: assetDirectory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let logoURL = Bundle.main.url(forResource: "NachoPowerLogo", withExtension: "png"),
           let logo = NSImage(contentsOf: logoURL) {
            dockLogo = logo
        }
        statusItem.button?.setAccessibilityLabel("Nacho Power")
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        model.onStatusChanged = { [weak self] in
            guard let self else { return }
            updatePowerIndicators()
            if !menuIsOpen { updateMenu() }
            scheduleAutomaticInstallationReview()
        }
        updatePowerIndicators()
        updateMenu()
        updates.onChange = { [weak self] in
            guard let self else { return }
            if !menuIsOpen { updateMenu() }
        }
        updates.installationContext = { [weak self] in
            guard let self, let model else { return (true, true, true) }
            return (settingsWindow?.isVisible == true, model.isCatVisible,
                    menuIsOpen || NSApplication.shared.modalWindow != nil)
        }
        updates.start()
        // A stalled transport must not leave an old green/red percentage in
        // the Dock indefinitely. Rendering is cached until the state changes.
        dockRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePowerIndicators() }
        }
        model.startMonitoring()
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.suspend() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.resume() }
        })
        if !UserDefaults.standard.bool(forKey: "hasLaunched") || CommandLine.arguments.contains("--settings") {
            showSettings()
            UserDefaults.standard.set(true, forKey: "hasLaunched")
        }
        if CommandLine.arguments.contains("--preview") { model.previewCat() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        dockRefreshTimer?.invalidate()
        updates.stop()
        model?.stop()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }
    func menuWillOpen(_ menu: NSMenu) { updateMenu(); menuIsOpen = true }
    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        scheduleAutomaticInstallationReview()
    }

    func windowWillClose(_ notification: Notification) {
        // isVisible can still be true in windowWillClose. Inspect it after the
        // close finishes, rather than accidentally leaving the update deferred.
        scheduleAutomaticInstallationReview()
    }

    private func scheduleAutomaticInstallationReview() {
        DispatchQueue.main.async { [weak self] in self?.updates.reevaluateAutomaticInstallation() }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates) { return updates.canCheckForUpdates }
        if menuItem.action == #selector(installUpdate) { return updates.hasPendingInstallation }
        return true
    }

    private func updateMenu() {
        guard let menu = statusItem?.menu, let model else { return }
        menu.removeAllItems()
        addDisabled("Nacho Power", to: menu)
        addDisabled(model.phaseDescription, to: menu)
        if model.isConnected {
            addDisabled("Battery \(model.batteryText)   ·   Input \(model.inputText)", to: menu)
        }
        if updates.hasPendingInstallation {
            let install = NSMenuItem(title: "Install Update & Relaunch…", action: #selector(installUpdate), keyEquivalent: "")
            install.target = self
            install.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: "Update ready")
            menu.addItem(install)
        } else if let version = updates.availableVersion, updates.state == .updateAvailable {
            let available = NSMenuItem(title: "Update available · \(version)…", action: #selector(checkForUpdates), keyEquivalent: "")
            available.target = self
            available.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: "Update available")
            menu.addItem(available)
        }
        menu.addItem(.separator())
        let enabled = NSMenuItem(title: "Enable reminders", action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.state = model.enabled ? .on : .off
        enabled.target = self
        menu.addItem(enabled)
        let preview = NSMenuItem(title: model.isPreviewing ? "End preview" : "Preview cat", action: #selector(previewCat), keyEquivalent: "")
        preview.target = self
        menu.addItem(preview)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let check = NSMenuItem(title: updates.state == .checking ? "Checking for Updates…" : "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        check.isEnabled = updates.canCheckForUpdates
        menu.addItem(check)
        menu.addItem(makeSupportMenuItem())
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Nacho Power", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func updatePowerIndicators() {
        guard let model else { return }
        let status = DockPowerStatus(telemetry: model.telemetry, isConnected: model.isConnected)
        statusItem.button?.toolTip = "\(status.accessibilityDescription) · \(model.phaseDescription)"
        statusItem.button?.setAccessibilityLabel(status.accessibilityDescription)
        guard status != lastDockStatus else { return }
        lastDockStatus = status
        NSApplication.shared.applicationIconImage = DockStatusIcon.image(for: status, logo: dockLogo)
        NSApplication.shared.dockTile.display()
        statusItem.button?.image = DockStatusIcon.menuBarImage(for: status)
        statusItem.button?.attributedTitle = NSAttributedString(string: " \(status.percentageText)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: DockStatusIcon.color(for: status.acState)
        ])
        statusItem.button?.imagePosition = .imageLeading
    }

    private func addDisabled(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @objc private func toggleEnabled() { model.enabled.toggle() }
    @objc private func previewCat() {
        if model.isPreviewing { model.endPreview() } else { model.previewCat() }
    }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    private func makeSupportMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Support Nacho Power", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Support Nacho Power")
        addDisabled("Optional one-time support · App stays free", to: submenu)
        for option in AppSupportLinks.options {
            let amount = NSMenuItem(title: "\(option.label)…", action: #selector(openSupport(_:)), keyEquivalent: "")
            amount.target = self
            amount.representedObject = option.checkoutURL
            amount.toolTip = "Opens QuickBooks in your browser. Review and confirm payment there."
            submenu.addItem(amount)
        }
        item.submenu = submenu
        return item
    }

    @objc private func openSupport(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func installUpdate() { updates.installPendingUpdate() }

    @objc private func checkForUpdates() { updates.checkForUpdates() }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView(model: model, updates: updates))
            let window = NSWindow(contentViewController: controller)
            window.title = "Nacho Power"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("EcoFlowCatSettings")
            window.center()
            settingsWindow = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
