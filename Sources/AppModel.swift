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
    @Published var catWidth: Double {
        didSet { defaults.set(catWidth, forKey: "catWidth"); updateAppearance() }
    }
    @Published var corner: OverlayCorner {
        didSet { defaults.set(corner.rawValue, forKey: "catCorner"); updateAppearance() }
    }
    @Published var fullScreen: Bool {
        didSet { defaults.set(fullScreen, forKey: "fullScreenAnimation"); updateAppearance() }
    }
    @Published var screenIndex: Int {
        didSet { defaults.set(screenIndex, forKey: "animationDisplay"); updateAppearance() }
    }
    @Published private(set) var telemetry: PowerTelemetry?
    @Published private(set) var connectionError: String?
    @Published private(set) var playbackError: String?
    @Published private(set) var assetWarning: String?
    @Published private(set) var isPreviewing = false
    @Published private(set) var isCatVisible = false
    @Published private(set) var phaseDescription = "Checking EcoFlow USB…"
    @Published private(set) var lastSuccessfulRead: Date?

    var onStatusChanged: (() -> Void)?
    private let defaults: UserDefaults
    private let monitor = DirectEcoFlowMonitor()
    private let overlay: CatOverlayController
    private var engine = ReminderEngine()
    private var pollingTask: Task<Void, Never>?
    private var staleDataTask: Task<Void, Never>?
    private var suspended = false
    private var isStopped = true
    private var monitoringGeneration = 0
    private var isPolling = false

    init(assetDirectory: URL, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["remindersEnabled": true,
                                     "immediateTrigger": false,
                                     "batteryThreshold": 50.0,
                                     "catWidth": 540.0,
                                     "fullScreenAnimation": true,
                                     "animationDisplay": 0,
                                     "catCorner": OverlayCorner.bottomRight.rawValue])
        enabled = defaults.bool(forKey: "remindersEnabled")
        immediate = defaults.bool(forKey: "immediateTrigger")
        threshold = min(100, max(1, defaults.double(forKey: "batteryThreshold")))
        catWidth = min(1000, max(240, defaults.double(forKey: "catWidth")))
        corner = OverlayCorner(rawValue: defaults.string(forKey: "catCorner") ?? "") ?? .bottomRight
        fullScreen = defaults.bool(forKey: "fullScreenAnimation")
        screenIndex = max(0, defaults.integer(forKey: "animationDisplay"))
        overlay = CatOverlayController(assetDirectory: assetDirectory)
        assetWarning = Self.readAssetWarning(in: assetDirectory)
        overlay.onPlaybackError = { [weak self] message in
            self?.playbackError = message
            self?.isPreviewing = false
            self?.engine.cancel()
            self?.refreshStatus()
        }
        overlay.onVisibilityChanged = { [weak self] visible in
            guard let self else { return }
            isCatVisible = visible
            if !visible {
                isPreviewing = false
            }
            refreshStatus()
        }
        overlay.onOutroFinished = { [weak self] in
            guard let self else { return }
            engine.outroDidFinish()
            refreshStatus()
        }
        updateAppearance()
        applySettings()
    }

    var batteryText: String { telemetry?.batteryPercentage.map { "\(Int($0.rounded()))%" } ?? "—" }
    var inputText: String {
        guard let watts = telemetry?.totalInputWatts, watts.isFinite else { return "—" }
        return watts.formatted(.number.precision(.fractionLength(0))) + " W"
    }
    var powerText: String {
        guard connectionError == nil, let telemetry else { return "Waiting for an EcoFlow USB connection" }
        if telemetry.acConnected == false { return "On battery · AC disconnected" }
        if telemetry.acConnected == true,
           let watts = telemetry.acInputWatts ?? telemetry.totalInputWatts, watts > 0 {
            return "AC connected · input power detected"
        }
        if telemetry.acConnected == true { return "AC connected · waiting for input" }
        return "AC status unavailable"
    }
    var isConnected: Bool { connectionError == nil && telemetry != nil }
    var conditionText: String {
        immediate ? "Start when AC power is absent."
            : "Start when AC power is absent and battery is below \(Int(threshold.rounded()))%."
    }

    func startMonitoring() {
        guard pollingTask == nil else { return }
        isStopped = false
        monitoringGeneration += 1
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.isStopped else { break }
                if !self.suspended { await self.poll() }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { break }
            }
        }
        // Snapshot I/O can stall independently of the main actor. This timer
        // still hides reminders whose last source reading has expired.
        staleDataTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.isStopped else { break }
                if !self.suspended && !self.isPreviewing {
                    let command = self.engine.tick(at: Date.timeIntervalSinceReferenceDate)
                    self.execute(command)
                    if command != .none { self.refreshStatus() }
                }
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
            }
        }
    }

    func stop() {
        isStopped = true
        monitoringGeneration += 1
        pollingTask?.cancel()
        pollingTask = nil
        staleDataTask?.cancel()
        staleDataTask = nil
        _ = engine.cancel()
        overlay.hide()
    }

    func suspend() {
        suspended = true
        monitoringGeneration += 1
        _ = engine.cancel()
        overlay.hide()
    }

    func resume() {
        guard !isStopped else { return }
        suspended = false
        monitoringGeneration += 1
        connectionError = "Refreshing after wake…"
        telemetry = nil
        refreshStatus()
    }

    func previewCat() {
        _ = engine.cancel()
        overlay.hide()
        playbackError = nil
        overlay.preview()
        // preview() hides its previous panel first. Set this after those
        // synchronous visibility callbacks, and keep it true through the outro.
        isPreviewing = overlay.isVisible && playbackError == nil
        refreshStatus()
    }

    func endPreview() {
        guard isPreviewing else { return }
        overlay.finishReminder()
        phaseDescription = "Playing outro…"
    }

    func refreshNow() {
        Task { [weak self] in await self?.poll() }
    }

    private func applySettings() {
        let command = engine.updateSettings(enabled: enabled,
                                            trigger: immediate ? .immediate : .belowBattery(threshold),
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
        overlay.updateAppearance(width: CGFloat(catWidth), corner: corner,
                                 screenIndex: screenIndex, fullScreen: fullScreen)
    }

    private func poll() async {
        // Manual and periodic refreshes share one outstanding snapshot. This
        // avoids queued reads and prevents one observation counting twice.
        guard !isStopped, !suspended, !isPolling, !Task.isCancelled else { return }
        isPolling = true
        let requestGeneration = monitoringGeneration
        defer { isPolling = false }
        do {
            let reading = try await monitor.snapshot()
            guard !isStopped, !suspended, !Task.isCancelled,
                  requestGeneration == monitoringGeneration else { return }
            telemetry = reading
            connectionError = nil
            lastSuccessfulRead = reading.timestamp
            if !isPreviewing {
                execute(engine.ingest(ReminderSample(acInputWatts: reading.reminderInputWatts,
                                                     batteryPercentage: reading.batteryPercentage,
                                                     acConnected: reading.acConnected),
                                      at: reading.timestamp.timeIntervalSinceReferenceDate))
            }
        } catch {
            guard !isStopped, !suspended, !Task.isCancelled,
                  requestGeneration == monitoringGeneration else { return }
            connectionError = error.localizedDescription
            telemetry = nil
            if !isPreviewing {
                execute(engine.ingest(ReminderSample(acInputWatts: nil, batteryPercentage: nil),
                                      at: Date.timeIntervalSinceReferenceDate))
                execute(engine.tick(at: Date.timeIntervalSinceReferenceDate))
            }
        }
        refreshStatus()
    }

    private func execute(_ command: ReminderCommand) {
        switch command {
        case .none: break
        case .start:
            playbackError = nil
            overlay.startReminder()
        case .finish: overlay.finishReminder()
        case .cancel: overlay.hide()
        }
    }

    private func refreshStatus() {
        if playbackError != nil { phaseDescription = "Video needs attention" }
        else if isPreviewing { phaseDescription = "Previewing intro → loop → outro" }
        else if !enabled { phaseDescription = "Reminders paused" }
        else if connectionError != nil { phaseDescription = "Waiting for EcoFlow USB" }
        else {
            switch engine.phase {
            case .idle:
                if telemetry?.acConnected == false && !immediate {
                    phaseDescription = "Waiting for battery below \(Int(threshold.rounded()))%"
                } else { phaseDescription = "Monitoring power" }
            case .active: phaseDescription = "Cat reminder active"
            case .outro: phaseDescription = "AC restored · playing outro"
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
