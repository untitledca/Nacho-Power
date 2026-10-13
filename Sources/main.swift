import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var model: AppModel!
    private var settingsWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var menuIsOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit EcoFlow Cat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApplication.shared.mainMenu = mainMenu
        let assetDirectory = Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Assets")
        model = AppModel(assetDirectory: assetDirectory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let logoURL = Bundle.main.url(forResource: "EcoFlowCatLogo", withExtension: "png"),
           let logo = NSImage(contentsOf: logoURL) {
            logo.size = NSSize(width: 22, height: 22)
            logo.isTemplate = false
            statusItem.button?.image = logo
        } else {
            statusItem.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "EcoFlow Cat")
            statusItem.button?.image?.isTemplate = true
        }
        statusItem.button?.setAccessibilityLabel("EcoFlow Cat")
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        model.onStatusChanged = { [weak self] in
            guard let self else { return }
            statusItem.button?.toolTip = "EcoFlow Cat · \(model.phaseDescription)"
            if !menuIsOpen { updateMenu() }
        }
        updateMenu()
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

    func applicationWillTerminate(_ notification: Notification) { model?.stop() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }
    func menuWillOpen(_ menu: NSMenu) { updateMenu(); menuIsOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }

    private func updateMenu() {
        guard let menu = statusItem?.menu, let model else { return }
        menu.removeAllItems()
        addDisabled("EcoFlow Cat", to: menu)
        addDisabled(model.phaseDescription, to: menu)
        if model.isConnected {
            addDisabled("Battery \(model.batteryText)   ·   Input \(model.inputText)", to: menu)
        }
        statusItem.button?.toolTip = "EcoFlow Cat · \(model.phaseDescription)"
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
        let quit = NSMenuItem(title: "Quit EcoFlow Cat", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
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

    @objc private func showSettings() {
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView(model: model))
            let window = NSWindow(contentViewController: controller)
            window.title = "EcoFlow Cat"
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
