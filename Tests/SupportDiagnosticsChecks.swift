import Foundation

/// These checks use only fresh temporary directories and synthetic data. They
/// never instantiate .shared, inspect real support history, or create windows.
@main
private struct SupportDiagnosticsChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NachoPower-DiagnosticsChecks-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        checkSanitization()
        checkThrottling()
        try checkPersistenceAndRotation(root.appendingPathComponent("rotation"))
        try checkConcurrentWrites(root.appendingPathComponent("concurrent"))
        try checkExport(root.appendingPathComponent("export"))
        try checkDamagedStorage(root.appendingPathComponent("damaged"))
        print("PASS support diagnostics privacy allowlists, bounded rotation, restart persistence, concurrent JSONL writes, private permissions, safe export, and damaged-storage handling")
    }

    private static let knownDate = Date(timeIntervalSince1970: 1_760_000_000)

    private static func checkThrottling() {
        var throttle = SupportDiagnosticThrottle()
        check(throttle.shouldRecord("poll", at: knownDate), "The first observation is retained")
        check(!throttle.shouldRecord("poll", at: knownDate.addingTimeInterval(29)),
              "Repetitive observations do not fill the bounded support history")
        check(throttle.shouldRecord("write_pending", at: knownDate.addingTimeInterval(1)),
              "A distinct failure or state is not hidden by routine throttling")
        check(throttle.shouldRecord("poll", at: knownDate.addingTimeInterval(30)),
              "A continued condition is recorded again at the interval boundary")
        check(throttle.shouldRecord("poll", at: knownDate.addingTimeInterval(31), interval: 0),
              "A state transition can bypass stable-state throttling")
        check(throttle.shouldRecord("poll", at: knownDate.addingTimeInterval(-1)),
              "Clock rollback does not suppress diagnostics indefinitely")
        throttle.reset()
        check(throttle.shouldRecord("poll", at: knownDate), "A new connection can record its first observation")
    }

    private static func checkSanitization() {
        let input: [String: Any] = [
            "transport": "bluetooth", "batteryPercentage": 87.5, "acInputVoltage": 121.2,
            "acConnected": true, "hasACVoltage": true, "acVoltageAge": 2.0,
            "commandSet": 254, "commandID": 22, "payloadBytes": 132,
            "fieldIDs": [68, 68, 202, -1, 100_000], "phase": "ready", "reason": "voltage_stale",
            "password": "secret-password", "serialNumber": "PRIVATE-SERIAL", "email": "person@example.com",
            "userID": "private-account", "token": "private-token", "sessionKey": "private-key",
            "rawPayload": [1, 2, 3], "ip": "192.168.1.10", "mac": "11:22:33:44:55:66",
            "path": "/Users/private-name/private-file", "message": "arbitrary private error text",
            "deviceModel": "DELTA 3 Plus", "errorDomain": "url", "errorCode": -1001,
            "timedReminders": true, "intervalMinutes": 10.0, "secondsUntilReminder": 599.0, "snoozed": false,
            "displays": [["width": 1080, "height": 1920, "scale": 1.0, "rotation": 90,
                          "isPrimary": false, "name": "Private monitor", "id": "private-display-uuid"]]
        ]
        let safe = SupportDiagnostics.sanitize(input)
        check(safe["transport"] as? String == "bluetooth" && safe["phase"] as? String == "ready",
              "Supported transport and protocol states remain useful")
        check(safe["batteryPercentage"] as? Double == 87.5 && safe["acInputVoltage"] as? Double == 121.2,
              "Power measurements survive sanitization")
        check(safe["acConnected"] as? Bool == true && safe["timedReminders"] as? Bool == true,
              "Boolean status and reminder settings remain useful")
        check(safe["fieldIDs"] as? [Int] == [68, 202], "Protocol field IDs are bounded and deduplicated")
        let sensitive: Set<String> = ["password", "serialNumber", "email", "userID", "token", "sessionKey",
                                      "rawPayload", "ip", "mac", "path", "message"]
        check(Set(safe.keys).isDisjoint(with: sensitive), "Sensitive or arbitrary fields are never retained")
        let display = (safe["displays"] as? [[String: Any]])?.first ?? [:]
        check(Set(display.keys) == Set(["width", "height", "scale", "rotation", "isPrimary"]),
              "Display context contains geometry and no display identity")

        let invalid: [String: Any] = [
            "transport": "https://private.example/token", "phase": "person@example.com",
            "reason": "/Users/private/path", "deviceModel": "DELTA 3 Plus PRIVATE-SERIAL",
            "batteryPercentage": Double.nan, "acInputWatts": Double.infinity, "acVoltageAge": -1,
            "payloadBytes": "123", "commandID": 22.5, "authenticated": 1,
            "writeCount": true, "errorDomain": "PRIVATE-ERROR-DOMAIN"
        ]
        check(SupportDiagnostics.sanitize(invalid).isEmpty,
              "Known keys cannot bypass privacy rules with arbitrary text, wrong types, or invalid numbers")
        let reconnect = SupportDiagnostics.sanitize([
            "reason": "official_app_running", "blockingApp": "ecoflow", "selectionMode": "remembered",
            "hasRememberedStation": true, "deviceCount": 2, "serialNumber": "PRIVATE-STATION"
        ])
        check(reconnect["reason"] as? String == "official_app_running" &&
              reconnect["blockingApp"] as? String == "ecoflow" &&
              reconnect["hasRememberedStation"] as? Bool == true &&
              reconnect["selectionMode"] as? String == "remembered" &&
              reconnect["deviceCount"] as? Int == 2 && reconnect["serialNumber"] == nil,
              "Reconnect diagnostics identify blockers and selection without station identities")
        check(SupportDiagnostics.sanitize(["blockingApp": "Private Client App", "selectionMode": "PRIVATE-SERIAL"]).isEmpty,
              "New reconnect fields accept only fixed categories, never arbitrary app names or identifiers")
        let error = NSError(domain: "private-domain@example.com", code: -1001,
                            userInfo: [NSLocalizedDescriptionKey: "password SECRET at /Users/private"])
        let normalized = SupportDiagnostics.errorDetails(error)
        check(normalized["errorDomain"] as? String == "other" && normalized["errorCode"] as? Int == -1001,
              "Error normalization retains a useful code without its private domain or message")
        check(SupportDiagnostics.errorDetails(NSError(domain: NSURLErrorDomain, code: -1009))["errorDomain"] as? String == "url",
              "A recognized system error domain has a stable safe category")
    }

    private static func checkPersistenceAndRotation(_ directory: URL) throws {
        let limit = 4_096
        let first = SupportDiagnostics(directory: directory, maxFileBytes: limit, clock: { knownDate })
        first.record(category: "app", event: "launch", details: ["writeCount": 0])
        let restarted = SupportDiagnostics(directory: directory, maxFileBytes: limit, clock: { knownDate })
        restarted.record(category: "app", event: "wake", details: ["writeCount": 1])
        try check(try readEvents(directory).count == 2, "A new logger instance preserves previous-launch history")
        for index in 2..<120 {
            restarted.record(category: "bluetooth", event: "telemetry_received", details: [
                "writeCount": index, "batteryPercentage": 87.0, "acInputVoltage": 121.0,
                "acVoltageAge": 0.1, "hasACVoltage": true, "reason": "input_voltage"
            ])
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        check(Set(names) == Set(["events.jsonl", "events.previous.jsonl"]), "Rotation creates exactly two bounded files")
        for name in names {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            check((attributes[.size] as? NSNumber)?.intValue ?? Int.max <= limit, "Each rotated file obeys the byte limit")
            check(((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777 == 0o600,
                  "Log files are private to the current user")
        }
        let folder = try FileManager.default.attributesOfItem(atPath: directory.path)
        check(((folder[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777 == 0o700,
              "The diagnostics directory is private")
        let retained = try readEvents(directory)
        let indexes = retained.compactMap { ($0["details"] as? [String: Any])?["writeCount"] as? Int }
        check(!indexes.isEmpty && indexes.last == 119 && indexes.first! > 0 && indexes == indexes.sorted(),
              "Rotation preserves a chronological recent history and discards old records")
        restarted.record(category: "PRIVATE-CATEGORY", event: "launch")
        restarted.record(category: "app", event: "PRIVATE-EVENT")
        try check(try readEvents(directory).count == retained.count, "Unknown event names cannot become a free-text logging channel")
    }

    private static func checkConcurrentWrites(_ directory: URL) throws {
        let log = SupportDiagnostics(directory: directory, clock: { knownDate })
        DispatchQueue.concurrentPerform(iterations: 150) { index in
            log.record(category: "bluetooth", event: "poll_requested", details: ["writeCount": index])
        }
        let records = try readEvents(directory)
        let indexes = records.compactMap { ($0["details"] as? [String: Any])?["writeCount"] as? Int }
        check(records.count == 150 && Set(indexes).count == 150,
              "Concurrent writers preserve every complete JSONL record without corruption")
    }

    private static func checkExport(_ directory: URL) throws {
        let log = SupportDiagnostics(directory: directory, clock: { knownDate })
        log.record(category: "connection", event: "snapshot", details: [
            "transport": "bluetooth", "batteryPercentage": 100.0, "acStatus": "unknown", "reason": "voltage_stale",
            "acVoltageAge": 6.2, "password": "DO-NOT-EXPORT-PASSWORD"
        ])
        let report = directory.appendingPathComponent("support-report.txt")
        check(!FileManager.default.fileExists(atPath: report.path), "Logging does not automatically export a report")

        // Even a malformed/older log cannot bypass the export privacy boundary.
        let injected: [String: Any] = ["timestamp": "2025-10-09T08:53:20.000Z", "category": "bluetooth",
            "event": "failure", "details": ["reason": "network", "password": "INJECTED-PASSWORD",
            "deviceModel": "INJECTED-PRIVATE-SERIAL", "errorDomain": "INJECTED-EMAIL@example.com"]]
        let unsafeEvent: [String: Any] = ["timestamp": "2025-10-09T08:53:20.000Z", "category": "app",
                                       "event": "INJECTED-PRIVATE-EVENT", "details": [:]]
        let current = directory.appendingPathComponent("events.jsonl")
        let handle = try FileHandle(forWritingTo: current)
        try handle.seekToEnd()
        for object in [injected, unsafeEvent] {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(0x0a)
            try handle.write(contentsOf: data)
        }
        try handle.write(contentsOf: Data("not JSON INJECTED-PRIVATE-LINE\n".utf8))
        try handle.close()
        try log.exportReport(to: report, context: [
            "transport": "bluetooth", "deviceModel": "DELTA 3 Plus", "authenticated": true,
            "displayMode": "selected", "fullScreen": true, "side": "left",
            "displays": [["width": 1080, "height": 1920, "scale": 1.0, "name": "PRIVATE-MONITOR"]],
            "serialNumber": "CONTEXT-PRIVATE-SERIAL", "path": "/Users/PRIVATE-NAME"
        ])
        let text = try String(contentsOf: report, encoding: .utf8)
        for forbidden in ["DO-NOT-EXPORT", "INJECTED-", "PRIVATE-MONITOR", "CONTEXT-PRIVATE", "/Users/PRIVATE"] {
            check(!text.contains(forbidden), "Export re-sanitizes stored and current context: \(forbidden)")
        }
        check(text.contains("voltage_stale") && text.contains("acVoltageAge") && text.contains("DELTA 3 Plus"),
              "The report retains actionable AC freshness and standardized model context")
        let contextStart = text.range(of: "Context (JSON)\n")!.upperBound
        let contextEnd = text.range(of: "\nRecent events (JSON Lines; oldest first)")!.lowerBound
        let info = try JSONSerialization.jsonObject(with: Data(text[contextStart..<contextEnd].utf8)) as! [String: Any]
        check(info["eventCount"] as? Int == 2, "The report exposes machine-readable context and only valid safe events")
        check((info["system"] as? [String: Any])?["architecture"] as? String != nil,
              "The report includes non-identifying system metadata")
        let attributes = try FileManager.default.attributesOfItem(atPath: report.path)
        check(((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777 == 0o600,
              "The user-exported report starts with private permissions")
    }

    private static func checkDamagedStorage(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let current = directory.appendingPathComponent("events.jsonl")
        try Data(repeating: 0x61, count: 20_000).write(to: current)
        let log = SupportDiagnostics(directory: directory, maxFileBytes: 1_024, clock: { knownDate })
        log.record(category: "app", event: "launch")
        try check(try Data(contentsOf: current).count <= 1_024 && readEvents(directory).count == 1,
              "An oversized existing file cannot defeat the disk bound")
        try FileManager.default.removeItem(at: current)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
        log.record(category: "app", event: "wake") // Logging must not throw or crash.
        do {
            try log.exportReport(to: directory.appendingPathComponent("unexpected.txt"))
            fail("Export must report inaccessible/non-file storage rather than silently claim success")
        } catch { }
    }

    private static func readEvents(_ directory: URL) throws -> [[String: Any]] {
        var records: [[String: Any]] = []
        for name in ["events.previous.jsonl", "events.jsonl"] {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let data = try Data(contentsOf: url)
            for line in data.split(separator: 0x0a) {
                records.append(try JSONSerialization.jsonObject(with: Data(line)) as! [String: Any])
            }
        }
        return records
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        if try !condition() { fail(message) }
    }
    private static func fail(_ message: String) -> Never {
        fputs("FAIL \(message)\n", stderr)
        exit(1)
    }
}
