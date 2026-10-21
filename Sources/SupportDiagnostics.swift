import Foundation
import CoreFoundation

/// Bounded, local-only support history. Nothing is uploaded. Every value passes
/// an allowlist before storage and again before export; arbitrary error text,
/// packet bytes, account identifiers, paths, and display identifiers are excluded.
final class SupportDiagnostics: @unchecked Sendable {
    static let shared = SupportDiagnostics(directory:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nacho Power/Diagnostics", isDirectory: true))

    static let categories: Set<String> = [
        "app", "connection", "bluetooth", "usb", "wifi", "telemetry",
        "reminder", "overlay", "updates", "diagnostics"
    ]
    static let events: Set<String> = [
        "launch", "terminate", "stop", "sleep", "wake", "monitoring_started", "monitoring_stopped",
        "configuration_saved", "attempt", "connected", "disconnected", "failed", "failure",
        "transport_changed", "refresh_requested", "phase_changed", "authenticated", "reconnect",
        "poll_requested", "poll_skipped", "telemetry_received", "write_started", "write_acknowledged",
        "snapshot", "status_changed", "ac_unknown", "ac_recovered", "stale",
        "device_found", "device_missing", "request", "response", "settings_changed", "decision",
        "started", "finished", "cancelled", "preview_started", "preview_finished",
        "configuration_changed", "display_changed", "shown", "hidden", "playback_failed",
        "check_started", "check_finished", "download_started", "download_finished",
        "install_pending", "install_started", "export_requested", "export_finished", "export",
        "error", "reconfigure", "account_discovery", "sign_in", "settings", "start", "finish",
        "cancel", "snooze", "preview", "appearance", "visibility"
    ]
    static let reasons: Set<String> = [
        "none", "unknown", "startup", "user_requested", "settings_changed", "sleep", "wake",
        "unavailable", "official_app_running", "remembered_station_missing", "not_connected", "connecting", "disconnected", "timeout", "cancelled",
        "unauthorized", "powered_off", "unsupported", "authentication", "invalid_packet",
        "invalid_response", "network", "http_error", "rate_limited", "read_failed", "write_failed",
        "write_pending", "queue_pending", "poll_interval", "polling_not_needed", "not_ready",
        "not_authenticated", "stream_stale", "voltage_stale", "voltage_missing", "voltage_ambiguous",
        "voltage_invalid", "explicit_flag", "input_voltage", "field_missing", "battery_missing",
        "no_devices", "multiple_devices", "device_missing", "device_removed", "display_removed",
        "display_added", "display_reordered", "fallback", "no_displays", "ac_connected",
        "ac_disconnected", "ac_unknown", "threshold", "disabled", "preview", "completed",
        "missing_assets", "decode_failed", "io_error", "other"
    ]

    private static let stringValues: [String: Set<String>] = [
        "transport": ["automatic", "usb", "bluetooth", "wifi", "none", "unknown"],
        "source": ["automatic", "usb", "bluetooth", "wifi", "none", "unknown"],
        "phase": ["idle", "scanning", "connecting", "services", "notifying", "publicKey", "sessionKey",
                  "authStatus", "authenticating", "ready", "awaitingStatus", "awaitingOwnerAcknowledgment",
                  "authenticated", "hidden", "intro", "loop", "dismissing", "monitoring", "pending",
                  "reminding", "waiting", "disabled", "preview", "unknown"],
        "reason": reasons,
        "blockingApp": ["ecoflow", "powermanager"],
        "selectionMode": ["automatic", "explicit", "remembered"],
        "acStatus": ["connected", "disconnected", "unknown"],
        "action": ["none", "start", "finish", "cancel", "hide", "show", "preview", "reconnect"],
        "corner": ["bottomLeft", "bottomRight", "topLeft", "topRight"],
        "side": ["left", "right"],
        "displayMode": ["main", "selected", "all", "fallback"],
        "architecture": ["arm64", "x86_64", "unknown"],
        "errorDomain": ["url", "bluetooth", "att", "cocoa", "posix", "osstatus", "other"],
        "deviceModel": ["DELTA", "DELTA 2", "DELTA 2 Max", "DELTA 3", "DELTA 3 Plus", "DELTA 3 Max",
                        "DELTA Max", "DELTA Pro", "DELTA Pro 3", "DELTA Pro Ultra", "RIVER", "RIVER 2",
                        "RIVER 2 Max", "RIVER 2 Pro", "RIVER 3", "RIVER 3 Plus", "unknown"]
    ]
    private static let booleans: Set<String> = [
        "acConnected", "authenticated", "writeInProgress", "hasBattery", "hasACFlag", "hasACStatus", "hasACVoltage",
        "hasACWatts", "hasTotalWatts", "enabled", "immediate", "fullScreen", "catVisible", "previewing",
        "suspended", "automaticChecks", "automaticDownloads", "isPrimary", "hasSavedAccount",
        "hasCloudCredentials", "hasSelectedStation", "hasError", "isStale", "isReady", "remindersEnabled",
        "timedReminders", "snoozed", "hasRememberedStation"
    ]
    private static let numberRanges: [String: ClosedRange<Double>] = [
        "batteryPercentage": 0...100, "threshold": 0...100,
        "acInputWatts": 0...100_000, "totalInputWatts": 0...100_000, "acInputVoltage": 0...1_000,
        "batteryAge": 0...604_800, "acVoltageAge": 0...604_800, "streamAge": 0...604_800,
        "observationAge": 0...604_800, "writeAge": 0...604_800, "duration": 0...604_800,
        "commandSet": 0...255, "commandID": 0...255, "payloadBytes": 0...65_536,
        "queueDepth": 0...65_536, "writeCount": 0...1_000_000, "retryCount": 0...1_000_000,
        "displayCount": 0...64, "catWidth": 1...32_768, "width": 0...32_768, "height": 0...32_768,
        "scale": 0.1...8, "rotation": 0...360, "osMajor": 0...999, "osMinor": 0...999,
        "osPatch": 0...999, "errorCode": -1_000_000...1_000_000, "httpStatus": 100...599,
        "loopCount": 0...1_000_000, "frameCount": 0...1_000_000,
        "intervalMinutes": 0...10_080, "secondsUntilReminder": 0...604_800,
        "deviceCount": 0...256, "usbDeviceCount": 0...256
    ]
    private static let integers: Set<String> = [
        "commandSet", "commandID", "payloadBytes", "queueDepth", "writeCount", "retryCount", "displayCount",
        "osMajor", "osMinor", "osPatch", "errorCode", "httpStatus", "loopCount", "frameCount",
        "deviceCount", "usbDeviceCount"
    ]
    private static let displayKeys: Set<String> = ["width", "height", "scale", "rotation", "isPrimary"]
    private let lock = NSLock()
    private let directory: URL
    private let maxFileBytes: Int
    private let clock: () -> Date
    private let formatter: ISO8601DateFormatter

    /// An explicit directory keeps deterministic tests separate from real logs.
    init(directory: URL, maxFileBytes: Int = 1_048_576, clock: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.maxFileBytes = max(1_024, min(maxFileBytes, 1_048_576))
        self.clock = clock
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    /// Logging failure must never interrupt power monitoring or app startup.
    func record(category: String, event: String, details: [String: Any] = [:]) {
        guard Self.categories.contains(category), Self.events.contains(event) else { return }
        let safeDetails = Self.sanitize(details)
        lock.lock()
        defer { lock.unlock() }
        do {
            try prepareStorage()
            let entry: [String: Any] = ["timestamp": formatter.string(from: clock()), "category": category,
                                        "event": event, "details": safeDetails]
            var line = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            line.append(0x0a)
            guard line.count <= maxFileBytes else { return }
            let current = directory.appendingPathComponent("events.jsonl")
            let previous = directory.appendingPathComponent("events.previous.jsonl")
            let size = (try? FileManager.default.attributesOfItem(atPath: current.path)[.size] as? NSNumber)?.intValue ?? 0
            if size + line.count > maxFileBytes {
                if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                if FileManager.default.fileExists(atPath: current.path) { try FileManager.default.moveItem(at: current, to: previous) }
            }
            if !FileManager.default.fileExists(atPath: current.path) {
                guard FileManager.default.createFile(atPath: current.path, contents: nil,
                                                     attributes: [.posixPermissions: 0o600]) else { return }
            }
            let handle = try FileHandle(forWritingTo: current)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            // Do not log an error about the logger, or retain path-bearing text.
        }
    }

    /// A single user-chosen text artifact includes readable context and JSONL
    /// events for support tools. Export never sends the report anywhere.
    func exportReport(to destination: URL, context: [String: Any] = [:]) throws {
        lock.lock()
        let report: Data
        do {
            try prepareStorage()
            let generated = formatter.string(from: clock())
            let metadata = Self.systemMetadata()
            let safeContext = Self.sanitize(context)
            var entries: [[String: Any]] = []
            for name in ["events.previous.jsonl", "events.jsonl"] {
                let file = directory.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                let data = try Data(contentsOf: file)
                for line in data.split(separator: 0x0a) {
                    guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                          let timestamp = object["timestamp"] as? String, timestamp.count <= 32,
                          let date = formatter.date(from: timestamp),
                          let category = object["category"] as? String, Self.categories.contains(category),
                          let event = object["event"] as? String, Self.events.contains(event) else { continue }
                    entries.append(["timestamp": formatter.string(from: date), "category": category, "event": event,
                                    "details": Self.sanitize(object["details"] as? [String: Any] ?? [:])])
                }
            }
            let info: [String: Any] = ["reportFormat": 1, "generatedAt": generated,
                                      "application": "Nacho Power", "system": metadata,
                                      "context": safeContext, "eventCount": entries.count]
            let prettyInfo = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
            var text = """
            Nacho Power support diagnostics
            Generated: \(generated)

            This report was exported locally at your request. Nothing was uploaded.
            It contains recent app events, connection states, power measurements,
            settings, and display dimensions. It excludes account details, device
            serial numbers, network addresses, credentials, raw Bluetooth payloads,
            and file paths. Review the report before choosing to share it.

            Context (JSON)
            \(String(decoding: prettyInfo, as: UTF8.self))

            Recent events (JSON Lines; oldest first)

            """
            for entry in entries {
                let line = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
                text += String(decoding: line, as: UTF8.self) + "\n"
            }
            report = Data(text.utf8)
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        try report.write(to: destination, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    /// Error messages can contain URLs, credentials, names, and paths. Keep only
    /// a small domain category and bounded numeric code, never localized text.
    static func errorDetails(_ error: Error) -> [String: Any] {
        let value = error as NSError
        let domains = [NSURLErrorDomain: "url", "CBErrorDomain": "bluetooth", "CBATTErrorDomain": "att",
                       NSCocoaErrorDomain: "cocoa", NSPOSIXErrorDomain: "posix", NSOSStatusErrorDomain: "osstatus"]
        return sanitize(["errorDomain": domains[value.domain] ?? "other", "errorCode": value.code])
    }

    private func prepareStorage() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        for name in ["events.jsonl", "events.previous.jsonl"] {
            let file = directory.appendingPathComponent(name)
            guard manager.fileExists(atPath: file.path) else { continue }
            let attributes = try manager.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            if (attributes[.size] as? NSNumber)?.intValue ?? 0 > maxFileBytes {
                // A corrupted or older oversized log cannot defeat the limit.
                try manager.removeItem(at: file)
            } else {
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }
    }

    static func sanitize(_ values: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in values {
            if let choices = stringValues[key], let string = value as? String, choices.contains(string) {
                result[key] = string
            } else if booleans.contains(key), let number = value as? NSNumber,
                      CFGetTypeID(number) == CFBooleanGetTypeID() {
                result[key] = number.boolValue
            } else if let range = numberRanges[key], let number = value as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID() {
                let numeric = number.doubleValue
                if numeric.isFinite, range.contains(numeric), !integers.contains(key) || numeric.rounded() == numeric {
                    result[key] = integers.contains(key) ? NSNumber(value: Int(numeric)) : NSNumber(value: numeric)
                }
            } else if key == "fieldIDs", let fields = value as? [Int] {
                result[key] = Array(Set(fields.filter { (0...65_535).contains($0) })).sorted().prefix(64).map { $0 }
            } else if key == "displays", let displays = value as? [[String: Any]] {
                result[key] = displays.prefix(16).map { display in
                    sanitize(display.filter { displayKeys.contains($0.key) })
                }
            }
        }
        return result
    }

    private static func systemMetadata() -> [String: Any] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        var result: [String: Any] = ["osMajor": os.majorVersion, "osMinor": os.minorVersion,
                                     "osPatch": os.patchVersion, "architecture": architecture]
        for (key, plistKey) in [("appVersion", "CFBundleShortVersionString"), ("appBuild", "CFBundleVersion")] {
            if let value = Bundle.main.object(forInfoDictionaryKey: plistKey) as? String,
               value.range(of: #"^[0-9]{1,4}(\.[0-9]{1,4}){0,3}$"#, options: .regularExpression) != nil {
                result[key] = value
            }
        }
        return result
    }
}

/// Limits repetitive observations without suppressing a different state/reason.
/// Keys are instrumentation constants; no user data is retained here.
struct SupportDiagnosticThrottle {
    private var recorded: [String: Date] = [:]

    mutating func shouldRecord(_ key: String, at date: Date, interval: TimeInterval = 30) -> Bool {
        if let previous = recorded[key] {
            let age = date.timeIntervalSince(previous)
            if age >= 0 && age < max(0, interval) { return false }
        }
        if recorded.count >= 256 { recorded.removeAll(keepingCapacity: true) }
        recorded[key] = date
        return true
    }

    mutating func reset() { recorded.removeAll(keepingCapacity: true) }
}
