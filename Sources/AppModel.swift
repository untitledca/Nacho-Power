import AppKit
import Combine
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: "remindersEnabled"); applySettings() }
    }
    @Published var immediate: Bool {
        didSet { defaults.set(immediate, forKey: "immediateTrigger"); applySettings() }
    }
    @Published var threshold: Double {
        didSet { defaults.set(threshold, forKey: "batteryThreshold"); applySettings() }
    }
    @Published var timedReminders: Bool {
        didSet {
            defaults.set(timedReminders, forKey: "timedReminders")
            applySettings()
            updateAppearance()
        }
    }
    @Published var reminderIntervalMinutes: Double {
        didSet {
            defaults.set(reminderIntervalMinutes, forKey: "reminderIntervalMinutes")
            applySettings()
        }
    }
    @Published var catWidth: Double {
        didSet { defaults.set(catWidth, forKey: "catWidth"); updateAppearance() }
    }
    @Published var corner: OverlayCorner {
        didSet { defaults.set(corner.rawValue, forKey: "catCorner"); updateAppearance() }
    }
    @Published var fullScreen: Bool {
        didSet { defaults.set(fullScreen, forKey: "fullScreenAnimation"); updateAppearance() }
    }
    @Published var fullScreenSide: OverlayVideoSide {
        didSet { defaults.set(fullScreenSide.rawValue, forKey: "fullScreenAnimationSide"); updateAppearance() }
    }
    @Published var displaySelection: String {
        didSet {
            defaults.set(displaySelection, forKey: OverlayDisplaySelection.defaultsKey)
            rememberSelectedDisplayName()
            updateAppearance()
        }
    }
    @Published private(set) var availableDisplays: [OverlayDisplay]
    @Published var transport: EcoFlowTransport = .automatic
    @Published var bluetoothUserID = ""
    @Published var serialNumber = ""
    @Published var secondStationEnabled = false {
        didSet {
            if secondStationEnabled && !oldValue { prepareSecondStationSelection() }
        }
    }
    @Published var secondSerialNumber = ""
    @Published var secondTransport: EcoFlowTransport = .automatic
    @Published var cloudRegion: EcoFlowCloudRegion = .global
    @Published var cloudAccessKey = ""
    @Published var cloudSecretKey = ""
    @Published private(set) var connectionSettingsMessage: String?
    @Published private(set) var isSigningIn = false
    @Published private(set) var isFindingAccount = false
    @Published private(set) var bluetoothSetupMessage = "Checking for your existing EcoFlow sign-in…"
    @Published private(set) var telemetry: PowerTelemetry?
    @Published private(set) var connectionError: String?
    @Published private(set) var secondTelemetry: PowerTelemetry?
    @Published private(set) var secondConnectionError: String?
    @Published private(set) var secondLastSuccessfulRead: Date?
    @Published private(set) var playbackError: String?
    @Published private(set) var assetWarning: String?
    @Published private(set) var isPreviewing = false
    @Published private(set) var isCatVisible = false
    @Published private(set) var phaseDescription = "Checking EcoFlow connections…"
    @Published private(set) var lastSuccessfulRead: Date?

    var onStatusChanged: (() -> Void)?
    private let defaults: UserDefaults
    private let monitor = EcoFlowConnectionMonitor()
    private let secondMonitor = EcoFlowConnectionMonitor()
    private var appliedConfiguration = EcoFlowConnectionConfiguration()
    private var appliedSecondConfiguration: EcoFlowConnectionConfiguration?
    private let overlay: CatOverlayController
    private var engine = MultiStationReminderPolicy()
    private var pollingTask: Task<Void, Never>?
    private var secondPollingTask: Task<Void, Never>?
    private var staleDataTask: Task<Void, Never>?
    private var suspended = false
    private var isStopped = true
    private var monitoringGeneration = 0
    private var secondMonitoringGeneration = 0
    private var isPolling = false
    private var secondIsPolling = false
    private var screenObserver: NSObjectProtocol?
    private var lastDiagnosticState: [String: String] = [:]
    private var lastDiagnosticSample: [String: Date] = [:]

    init(assetDirectory: URL, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["remindersEnabled": true,
                                     "immediateTrigger": true,
                                     "batteryThreshold": 50.0,
                                     "timedReminders": false,
                                     "reminderIntervalMinutes": 5.0,
                                     "catWidth": 540.0,
                                     "fullScreenAnimation": true,
                                     "animationDisplay": 0,
                                     "catCorner": OverlayCorner.bottomRight.rawValue])
        transport = EcoFlowTransport(rawValue: defaults.string(forKey: "connectionTransport") ?? "") ?? .automatic
        bluetoothUserID = EcoFlowCredentialStore.read("bluetoothUserID")
        serialNumber = defaults.string(forKey: "deviceSerialNumber") ?? ""
        secondStationEnabled = defaults.bool(forKey: "secondStationEnabled")
        secondSerialNumber = defaults.string(forKey: "secondDeviceSerialNumber") ?? ""
        secondTransport = EcoFlowTransport(rawValue: defaults.string(forKey: "secondConnectionTransport") ?? "") ?? .automatic
        cloudRegion = EcoFlowCloudRegion(rawValue: defaults.string(forKey: "cloudRegion") ?? "") ?? .global
        cloudAccessKey = EcoFlowCredentialStore.read("cloudAccessKey")
        cloudSecretKey = EcoFlowCredentialStore.read("cloudSecretKey")
        enabled = defaults.bool(forKey: "remindersEnabled")
        immediate = defaults.bool(forKey: "immediateTrigger")
        threshold = min(100, max(1, defaults.double(forKey: "batteryThreshold")))
        timedReminders = defaults.bool(forKey: "timedReminders")
        let savedInterval = defaults.double(forKey: "reminderIntervalMinutes")
        reminderIntervalMinutes = savedInterval.isFinite ? min(60, max(1, savedInterval.rounded())) : 5
        catWidth = min(1000, max(240, defaults.double(forKey: "catWidth")))
        let savedCorner = OverlayCorner(rawValue: defaults.string(forKey: "catCorner") ?? "") ?? .bottomRight
        corner = savedCorner
        fullScreen = defaults.bool(forKey: "fullScreenAnimation")
        let savedFullScreenSide = OverlayVideoSide(rawValue: defaults.string(forKey: "fullScreenAnimationSide") ?? "") ?? savedCorner.videoSide
        fullScreenSide = savedFullScreenSide
        defaults.set(savedFullScreenSide.rawValue, forKey: "fullScreenAnimationSide")
        let displays = OverlayDisplay.availableDisplays
        availableDisplays = displays
        displaySelection = OverlayDisplaySelection.initialSelection(defaults: defaults, displays: displays)
        overlay = CatOverlayController(assetDirectory: assetDirectory)
        appliedConfiguration = connectionConfiguration
        if secondStationEnabled {
            do {
                let configurations = try validatedConnectionConfigurations()
                appliedConfiguration = configurations.primary
                appliedSecondConfiguration = configurations.secondary
                serialNumber = configurations.primary.serialNumber
                _ = engine.setSecondStationEnabled(configurations.secondary != nil)
            } catch {
                // Corrupt or incomplete secondary settings cannot stop the
                // existing primary station from reconnecting at startup.
                secondConnectionError = error.localizedDescription
                connectionSettingsMessage = error.localizedDescription
            }
        }
        assetWarning = Self.readAssetWarning(in: assetDirectory)
        overlay.onPlaybackError = { [weak self] message in
            SupportDiagnostics.shared.record(category: "overlay", event: "playback_failed", details: ["reason": "decode_failed"])
            self?.playbackError = message
            self?.isPreviewing = false
            self?.engine.cancel()
            self?.refreshStatus()
        }
        overlay.onVisibilityChanged = { [weak self] visible in
            guard let self else { return }
            isCatVisible = visible
            SupportDiagnostics.shared.record(category: "overlay", event: visible ? "shown" : "hidden")
            if !visible {
                isPreviewing = false
            }
            refreshStatus()
        }
        overlay.onDismissalFinished = { [weak self] in
            guard let self else { return }
            execute(engine.dismissalDidFinish())
            refreshStatus()
        }
        overlay.onSnoozeRequested = { [weak self] in self?.snoozeCat() }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.availableDisplays = OverlayDisplay.availableDisplays
                self.rememberSelectedDisplayName()
                self.updateAppearance()
            }
        }
        rememberSelectedDisplayName()
        updateAppearance()
        applySettings()
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    var selectedDisplayIsUnavailable: Bool {
        displaySelection != OverlayDisplaySelection.main && displaySelection != OverlayDisplaySelection.all
            && !availableDisplays.contains(where: { $0.id == displaySelection })
    }

    var unavailableDisplayName: String {
        defaults.string(forKey: OverlayDisplaySelection.displayNameDefaultsKey) ?? "Selected display"
    }

    private func rememberSelectedDisplayName() {
        if let display = availableDisplays.first(where: { $0.id == displaySelection }) {
            defaults.set(display.name, forKey: OverlayDisplaySelection.displayNameDefaultsKey)
        }
    }

    var batteryText: String { Self.batteryText(telemetry) }
    var inputText: String { Self.inputText(telemetry) }
    var powerText: String { Self.powerText(telemetry, error: connectionError) }
    var isConnected: Bool { connectionError == nil && telemetry != nil }
    var secondBatteryText: String { Self.batteryText(secondTelemetry) }
    var secondInputText: String { Self.inputText(secondTelemetry) }
    var secondPowerText: String { Self.powerText(secondTelemetry, error: secondConnectionError) }
    var monitorsSecondStation: Bool { appliedSecondConfiguration != nil }
    var secondIsConnected: Bool { monitorsSecondStation && secondConnectionError == nil && secondTelemetry != nil }
    var secondPhaseDescription: String {
        guard monitorsSecondStation else { return secondStationEnabled ? "Choose a second station" : "Second station is off" }
        return secondConnectionError == nil && secondTelemetry != nil ? "Monitoring power" : "Waiting for EcoFlow"
    }

    private static func batteryText(_ reading: PowerTelemetry?) -> String {
        reading?.batteryPercentage.map { "\(Int($0.rounded()))%" } ?? "—"
    }

    private static func inputText(_ reading: PowerTelemetry?) -> String {
        guard let watts = reading?.totalInputWatts, watts.isFinite else { return "—" }
        return watts.formatted(.number.precision(.fractionLength(0))) + " W"
    }

    private static func powerText(_ reading: PowerTelemetry?, error: String?) -> String {
        guard error == nil, let reading else { return "Waiting for an EcoFlow connection" }
        if reading.acConnected == false { return "On battery · AC disconnected" }
        if reading.acConnected == true,
           let watts = reading.acInputWatts ?? reading.totalInputWatts, watts > 0 {
            return "AC connected · input power detected"
        }
        if reading.acConnected == true { return "AC connected · not drawing power" }
        return "AC status unavailable"
    }
    var bluetoothAccountReady: Bool { !bluetoothUserID.isEmpty }
    var conditionText: String {
        let condition = immediate ? "AC power is disconnected" : "AC is disconnected and battery is below \(Int(threshold.rounded()))%"
        return timedReminders
            ? "Wait \(reminderIntervalText) while \(condition), then show the cat."
            : "Start when \(condition)."
    }
    var reminderIntervalText: String {
        let minutes = Int(reminderIntervalMinutes.rounded())
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
    /// The slider's zero position is the original continuous reminder mode.
    /// Keep the last nonzero interval in storage when switching to Immediately.
    var reminderDelayMinutes: Double {
        get { timedReminders ? reminderIntervalMinutes : 0 }
        set {
            guard newValue.isFinite else { return }
            let minutes = min(60, max(0, newValue.rounded()))
            if minutes == 0 {
                if timedReminders { timedReminders = false }
            } else {
                if reminderIntervalMinutes != minutes { reminderIntervalMinutes = minutes }
                if !timedReminders { timedReminders = true }
            }
        }
    }
    var reminderDelayText: String {
        timedReminders ? "After \(reminderIntervalText)" : "Immediately"
    }
    var canSnooze: Bool { timedReminders && isCatVisible && !isPreviewing && engine.phase == .active }

    /// Explicit safe fields only. Never export account, device, or display names/IDs.
    var diagnosticContext: [String: Any] { diagnosticContext(station: .primary) }

    private func diagnosticContext(station: EcoFlowStationSlot) -> [String: Any] {
        let configuration = station == .primary ? appliedConfiguration : (appliedSecondConfiguration ?? appliedConfiguration)
        let reading = station == .primary ? telemetry : secondTelemetry
        let error = station == .primary ? connectionError : secondConnectionError
        var details: [String: Any] = [
            "transport": configuration.transport.rawValue,
            "stationSlot": station.rawValue,
            "monitoredStationCount": appliedSecondConfiguration == nil ? 1 : 2,
            "hasSavedAccount": !configuration.userID.isEmpty,
            "hasCloudCredentials": !configuration.accessKey.isEmpty && !configuration.secretKey.isEmpty,
            "hasSelectedStation": !configuration.serialNumber.isEmpty,
            "enabled": enabled, "immediate": immediate, "threshold": threshold,
            "timedReminders": timedReminders, "intervalMinutes": reminderIntervalMinutes,
            "snoozed": engine.isSnoozed, "catVisible": isCatVisible, "previewing": isPreviewing,
            "suspended": suspended, "fullScreen": fullScreen, "catWidth": catWidth,
            "corner": corner.rawValue, "side": fullScreenSide.rawValue,
            "displayMode": displaySelection == OverlayDisplaySelection.all ? "all" :
                (displaySelection == OverlayDisplaySelection.main ? "main" : (selectedDisplayIsUnavailable ? "fallback" : "selected")),
            "displayCount": NSScreen.screens.count,
            "displays": NSScreen.screens.map { screen -> [String: Any] in
                var values: [String: Any] = ["width": screen.frame.width, "height": screen.frame.height,
                                             "scale": screen.backingScaleFactor, "isPrimary": screen == NSScreen.screens.first]
                if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                    values["rotation"] = CGDisplayRotation(CGDirectDisplayID(id.uint32Value))
                }
                return values
            },
            "hasError": error != nil,
            "acStatus": reading?.acConnected.map { $0 ? "connected" : "disconnected" } ?? "unknown"
        ]
        if let reading {
            details["batteryPercentage"] = reading.batteryPercentage
            details["acInputWatts"] = reading.acInputWatts
            details["totalInputWatts"] = reading.totalInputWatts
            details["observationAge"] = max(0, Date().timeIntervalSince(reading.timestamp))
            let source = reading.sourceDescription.lowercased()
            details["source"] = source.contains("bluetooth") ? "bluetooth" : (source.contains("usb") ? "usb" : "wifi")
        }
        if let deadline = engine.nextReminderAt {
            details["secondsUntilReminder"] = max(0, deadline - Date.timeIntervalSinceReferenceDate)
        }
        return details
    }

    func snoozeCat() {
        if isPreviewing { endPreview(); return }
        guard canSnooze else { return }
        SupportDiagnostics.shared.record(category: "reminder", event: "snooze", details: ["intervalMinutes": reminderIntervalMinutes])
        execute(engine.snooze(at: Date.timeIntervalSinceReferenceDate))
        refreshStatus()
    }

    func startMonitoring() {
        guard pollingTask == nil else { return }
        isStopped = false
        SupportDiagnostics.shared.record(category: "app", event: "monitoring_started", details: diagnosticContext)
        monitoringGeneration += 1
        secondMonitoringGeneration += 1
        pollingTask = Task { [weak self] in
            await self?.prepareBluetoothAccount()
            while !Task.isCancelled {
                guard let self, !self.isStopped else { break }
                if !self.suspended { await self.poll(station: .primary) }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { break }
            }
        }
        // Independent tasks ensure a slow/offline station never holds up the
        // other station's reads or reconnection loop.
        secondPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.isStopped else { break }
                if !self.suspended { await self.poll(station: .secondary) }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { break }
            }
        }
        // Snapshot I/O can stall independently of the main actor. This timer
        // still hides reminders whose last source reading has expired.
        staleDataTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.isStopped else { break }
                if !self.suspended && !self.isPreviewing {
                    let hadCountdown = self.engine.nextReminderAt != nil
                    let command = self.engine.tick(at: Date.timeIntervalSinceReferenceDate)
                    self.execute(command)
                    if command != .none || hadCountdown || self.engine.nextReminderAt != nil { self.refreshStatus() }
                }
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
            }
        }
    }

    func stop() {
        SupportDiagnostics.shared.record(category: "app", event: "monitoring_stopped")
        isStopped = true
        monitoringGeneration += 1
        secondMonitoringGeneration += 1
        pollingTask?.cancel()
        pollingTask = nil
        secondPollingTask?.cancel()
        secondPollingTask = nil
        staleDataTask?.cancel()
        staleDataTask = nil
        monitor.stop()
        secondMonitor.stop()
        _ = engine.cancel()
        overlay.hide()
    }

    func suspend() {
        SupportDiagnostics.shared.record(category: "app", event: "sleep")
        suspended = true
        monitoringGeneration += 1
        secondMonitoringGeneration += 1
        monitor.stop()
        secondMonitor.stop()
        telemetry = nil
        secondTelemetry = nil
        connectionError = "Sleeping"
        secondConnectionError = appliedSecondConfiguration == nil ? nil : "Sleeping"
        refreshStatus()
        _ = engine.cancel()
        overlay.hide()
    }

    func resume() {
        guard !isStopped else { return }
        suspended = false
        SupportDiagnostics.shared.record(category: "app", event: "wake")
        monitoringGeneration += 1
        secondMonitoringGeneration += 1
        connectionError = "Refreshing after wake…"
        secondConnectionError = appliedSecondConfiguration == nil ? nil : "Refreshing after wake…"
        telemetry = nil
        secondTelemetry = nil
        refreshStatus()
    }

    func previewCat() {
        SupportDiagnostics.shared.record(category: "overlay", event: "preview_started", details: diagnosticContext)
        _ = engine.cancel()
        overlay.hide()
        playbackError = nil
        overlay.preview()
        // preview() hides its previous panel first. Set this after those
        // synchronous visibility callbacks, and keep it true through dismissal.
        isPreviewing = overlay.isVisible && playbackError == nil
        refreshStatus()
    }

    func endPreview() {
        guard isPreviewing else { return }
        overlay.finishReminder()
        phaseDescription = "Hiding cat…"
    }

    private var connectionConfiguration: EcoFlowConnectionConfiguration {
        var configuration = EcoFlowConnectionConfiguration()
        configuration.transport = transport
        configuration.userID = bluetoothUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.serialNumber = serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.cloudRegion = cloudRegion
        configuration.accessKey = cloudAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.secretKey = cloudSecretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return configuration
    }

    /// Bluetooth stations often stop advertising while connected. Surface the
    /// authenticated target once when enabling the second-station editor, so a
    /// live primary selection remains visible without another discovery scan.
    private func prepareSecondStationSelection() {
        guard serialNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let key = EcoFlowWirelessProtocol.stationAccountKey(bluetoothUserID) else { return }
        let remembered = EcoFlowCredentialStore.read(key).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !remembered.isEmpty { serialNumber = remembered }
    }

    private func validatedConnectionConfigurations() throws -> (primary: EcoFlowConnectionConfiguration, secondary: EcoFlowConnectionConfiguration?) {
        var first = connectionConfiguration
        if secondStationEnabled && first.serialNumber.isEmpty,
           let key = EcoFlowWirelessProtocol.stationAccountKey(first.userID) {
            first.serialNumber = EcoFlowCredentialStore.read(key)
        }
        let selections = try MultiStationSelection.validated(primary: first.serialNumber,
                                                            secondary: secondSerialNumber,
                                                            secondEnabled: secondStationEnabled)
        first.serialNumber = selections.primary
        first.stationSlot = .primary
        guard secondStationEnabled else { return (first, nil) }
        var second = first
        second.stationSlot = .secondary
        second.transport = secondTransport
        second.serialNumber = selections.secondary
        return (first, second)
    }

    func saveConnectionSettings() {
        do {
            // Validate all selections before persisting or stopping a working
            // primary connection. An invalid secondary edit is harmless.
            let configurations = try validatedConnectionConfigurations()
            try EcoFlowCredentialStore.write(bluetoothUserID.trimmingCharacters(in: .whitespacesAndNewlines), for: "bluetoothUserID")
            try EcoFlowCredentialStore.write(cloudAccessKey.trimmingCharacters(in: .whitespacesAndNewlines), for: "cloudAccessKey")
            try EcoFlowCredentialStore.write(cloudSecretKey.trimmingCharacters(in: .whitespacesAndNewlines), for: "cloudSecretKey")
            defaults.set(transport.rawValue, forKey: "connectionTransport")
            serialNumber = configurations.primary.serialNumber
            defaults.set(serialNumber, forKey: "deviceSerialNumber")
            defaults.set(cloudRegion.rawValue, forKey: "cloudRegion")
            defaults.set(secondStationEnabled, forKey: "secondStationEnabled")
            secondSerialNumber = secondSerialNumber.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            defaults.set(secondSerialNumber, forKey: "secondDeviceSerialNumber")
            defaults.set(secondTransport.rawValue, forKey: "secondConnectionTransport")
            let primaryChanged = configurations.primary != appliedConfiguration
            let secondaryChanged = configurations.secondary != appliedSecondConfiguration
            appliedConfiguration = configurations.primary
            appliedSecondConfiguration = configurations.secondary
            if primaryChanged {
                monitoringGeneration += 1
                monitor.stop()
                telemetry = nil
                connectionError = "Connecting…"
                execute(engine.reset(station: .primary))
            }
            if secondaryChanged {
                secondMonitoringGeneration += 1
                secondMonitor.stop()
                secondTelemetry = nil
                secondConnectionError = appliedSecondConfiguration == nil ? nil : "Connecting…"
                execute(engine.reset(station: .secondary))
            }
            execute(engine.setSecondStationEnabled(appliedSecondConfiguration != nil))
            SupportDiagnostics.shared.record(category: "connection", event: "configuration_saved", details: diagnosticContext)
            connectionSettingsMessage = appliedSecondConfiguration == nil
                ? "Saved. Checking your connection…" : "Saved. Checking both stations independently…"
            refreshStatus()
            refreshNow()
        } catch {
            connectionSettingsMessage = error.localizedDescription
            SupportDiagnostics.shared.record(category: "connection", event: "failed", details: SupportDiagnostics.errorDetails(error))
        }
    }

    private func prepareBluetoothAccount() async {
        guard !isFindingAccount else { return }
        if !bluetoothUserID.isEmpty {
            bluetoothSetupMessage = "Your EcoFlow account is ready. Bluetooth reconnects automatically."
            return
        }
        isFindingAccount = true
        defer { isFindingAccount = false }
        let identifier = await EcoFlowAccountDiscovery.discover()
        guard !isStopped, !Task.isCancelled else { return }
        guard bluetoothUserID.isEmpty else { return }
        guard let identifier else {
            bluetoothSetupMessage = "Sign in once below to enable automatic Bluetooth."
            return
        }
        do {
            try EcoFlowCredentialStore.write(identifier, for: "bluetoothUserID")
            bluetoothUserID = identifier
            appliedConfiguration.userID = identifier
            if appliedSecondConfiguration != nil { appliedSecondConfiguration?.userID = identifier }
            bluetoothSetupMessage = "Found your EcoFlow sign-in. Bluetooth connects automatically."
        } catch {
            bluetoothSetupMessage = error.localizedDescription
        }
    }

    func findEcoFlowAccount() {
        Task { [weak self] in
            await self?.prepareBluetoothAccount()
            self?.refreshNow()
        }
    }

    func signInForBluetooth(email: String, password: String) async {
        guard !isSigningIn else { return }
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            bluetoothUserID = try await EcoFlowAccount.signIn(email: email, password: password, region: cloudRegion)
            bluetoothSetupMessage = "Signed in. Bluetooth reconnects automatically."
            saveConnectionSettings()
        } catch {
            connectionSettingsMessage = error.localizedDescription
        }
    }

    func refreshNow() {
        Task { [weak self] in await self?.poll(station: .primary) }
        Task { [weak self] in await self?.poll(station: .secondary) }
    }

    private func applySettings() {
        SupportDiagnostics.shared.record(category: "reminder", event: "settings_changed", details: [
            "enabled": enabled, "immediate": immediate, "threshold": threshold,
            "timedReminders": timedReminders, "intervalMinutes": reminderIntervalMinutes])
        let command = engine.updateSettings(enabled: enabled,
                                            trigger: immediate ? .immediate : .belowBattery(threshold),
                                            interval: timedReminders ? reminderIntervalMinutes * 60 : nil,
                                            at: Date.timeIntervalSinceReferenceDate)
        if !enabled && isPreviewing {
            // Preview keeps the policy engine canceled, so disabling cannot
            // rely on an engine .cancel command to hide this manual playback.
            _ = engine.cancel()
            overlay.hide()
            isPreviewing = false
        } else {
            execute(command)
        }
        refreshStatus()
    }

    private func updateAppearance() {
        SupportDiagnostics.shared.record(category: "overlay", event: "appearance", details: diagnosticContext)
        overlay.updateAppearance(width: CGFloat(catWidth), corner: corner,
                                 fullScreen: fullScreen, fullScreenSide: fullScreenSide,
                                 displaySelection: displaySelection,
                                 clickToSnooze: timedReminders)
    }

    private func poll(station: EcoFlowStationSlot) async {
        // Each lane shares its own periodic/manual read, never the other
        // station's in-flight snapshot or generation.
        guard !isStopped, !suspended, !Task.isCancelled else { return }
        let selectedMonitor: EcoFlowConnectionMonitor
        let configuration: EcoFlowConnectionConfiguration
        let requestGeneration: Int
        switch station {
        case .primary:
            guard !isPolling else { return }
            isPolling = true
            selectedMonitor = monitor
            configuration = appliedConfiguration
            requestGeneration = monitoringGeneration
        case .secondary:
            guard !secondIsPolling, let second = appliedSecondConfiguration else { return }
            secondIsPolling = true
            selectedMonitor = secondMonitor
            configuration = second
            requestGeneration = secondMonitoringGeneration
        }
        defer {
            if station == .primary { isPolling = false } else { secondIsPolling = false }
        }
        do {
            let reading = try await selectedMonitor.snapshot(configuration: configuration)
            guard pollIsCurrent(station: station, generation: requestGeneration) else { return }
            if station == .primary {
                telemetry = reading
                connectionError = nil
                lastSuccessfulRead = reading.timestamp
            } else {
                secondTelemetry = reading
                secondConnectionError = nil
                secondLastSuccessfulRead = reading.timestamp
            }
            recordDiagnosticSample(station: station)
            if !isPreviewing {
                execute(engine.ingest(ReminderSample(acInputWatts: reading.reminderInputWatts,
                                                     batteryPercentage: reading.batteryPercentage,
                                                     acConnected: reading.acConnected),
                                      station: station, at: reading.timestamp.timeIntervalSinceReferenceDate))
            }
        } catch {
            guard pollIsCurrent(station: station, generation: requestGeneration) else { return }
            if station == .primary {
                connectionError = error.localizedDescription
                telemetry = nil
            } else {
                secondConnectionError = error.localizedDescription
                secondTelemetry = nil
            }
            recordDiagnosticSample(station: station, error: error)
            if !isPreviewing {
                execute(engine.ingest(ReminderSample(acInputWatts: nil, batteryPercentage: nil),
                                      station: station, at: Date.timeIntervalSinceReferenceDate))
                execute(engine.tick(at: Date.timeIntervalSinceReferenceDate))
            }
        }
        refreshStatus()
    }

    private func pollIsCurrent(station: EcoFlowStationSlot, generation: Int) -> Bool {
        guard !isStopped, !suspended, !Task.isCancelled else { return false }
        return station == .primary ? generation == monitoringGeneration
            : appliedSecondConfiguration != nil && generation == secondMonitoringGeneration
    }

    private func execute(_ command: ReminderCommand) {
        if command != .none {
            SupportDiagnostics.shared.record(category: "reminder", event: "decision", details: [
                "action": command == .start ? "start" : (command == .finish ? "finish" : "cancel"),
                "timedReminders": timedReminders, "intervalMinutes": reminderIntervalMinutes])
        }
        switch command {
        case .none: break
        case .start:
            playbackError = nil
            overlay.startReminder()
        case .finish: overlay.finishReminder()
        case .cancel: overlay.hide()
        }
    }

    private func recordDiagnosticSample(station: EcoFlowStationSlot, error: Error? = nil) {
        var details = diagnosticContext(station: station)
        if let error { details.merge(SupportDiagnostics.errorDetails(error)) { _, new in new } }
        let state = "\(details["acStatus"] ?? "unknown")/\(details["source"] ?? "none")/\(error != nil)"
        let now = Date()
        let slot = station.rawValue
        guard state != lastDiagnosticState[slot] || now.timeIntervalSince(lastDiagnosticSample[slot] ?? .distantPast) >= 15 else { return }
        lastDiagnosticState[slot] = state
        lastDiagnosticSample[slot] = now
        SupportDiagnostics.shared.record(category: "telemetry", event: error == nil ? "snapshot" : "failed", details: details)
    }

    private func refreshStatus() {
        if playbackError != nil { phaseDescription = "Video needs attention" }
        else if isPreviewing { phaseDescription = "Previewing intro → loop → pop" }
        else if !enabled { phaseDescription = "Reminders paused" }
        else if connectionError != nil && !secondIsConnected && engine.phase == .idle { phaseDescription = "Waiting for EcoFlow" }
        else {
            switch engine.phase {
            case .idle:
                if timedReminders, let deadline = engine.nextReminderAt {
                    let seconds = max(0, Int(ceil(deadline - Date.timeIntervalSinceReferenceDate)))
                    let remaining = "\(seconds / 60)m \(seconds % 60)s"
                    phaseDescription = engine.isSnoozed ? "Snoozed · next cat in \(remaining)" : "Next cat in \(remaining)"
                } else if (telemetry?.acConnected == false || secondTelemetry?.acConnected == false) && !immediate {
                    phaseDescription = "Waiting for battery below \(Int(threshold.rounded()))%"
                } else { phaseDescription = appliedSecondConfiguration == nil ? "Monitoring power" : "Monitoring two stations" }
            case .active: phaseDescription = timedReminders ? "Cat reminder active · click to snooze" : "Cat reminder active"
            case .dismissing: phaseDescription = engine.isSnoozed ? "Snoozed · hiding cat" : "Hiding cat…"
            }
        }
        onStatusChanged?()
    }

    private struct AssetValidationSummary: Decodable {
        let validForTransparentOverlay: Bool
        let warnings: [String]?
    }

    private static func readAssetWarning(in directory: URL) -> String? {
        let url = directory.appendingPathComponent("video-validation.json")
        guard let data = try? Data(contentsOf: url),
              let report = try? JSONDecoder().decode(AssetValidationSummary.self, from: data),
              !report.validForTransparentOverlay else { return nil }
        let warnings = (report.warnings ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return warnings.isEmpty
            ? "The supplied cat videos need transparent backgrounds before they can overlay the desktop."
            : warnings.joined(separator: "\n")
    }
}
