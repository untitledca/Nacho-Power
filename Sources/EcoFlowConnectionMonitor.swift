import Foundation
import AppKit
import Security
import CryptoKit

enum EcoFlowTransport: String, CaseIterable, Sendable {
    case automatic, usb, bluetooth, wifi
    var title: String {
        switch self { case .automatic: return "Automatic"; case .usb: return "USB"; case .bluetooth: return "Bluetooth"; case .wifi: return "Wi-Fi (cloud)" }
    }
}
enum EcoFlowCloudRegion: String, CaseIterable, Sendable {
    case global, europe, america
    var title: String { switch self { case .global: return "Global"; case .europe: return "Europe"; case .america: return "Americas" } }
    var host: String { switch self { case .global: return "api.ecoflow.com"; case .europe: return "api-e.ecoflow.com"; case .america: return "api-a.ecoflow.com" } }
}
struct EcoFlowConnectionConfiguration: Equatable, Sendable {
    var transport: EcoFlowTransport = .automatic
    var userID = ""
    var serialNumber = ""
    var cloudRegion: EcoFlowCloudRegion = .global
    var accessKey = ""
    var secretKey = ""
    var stationSlot: EcoFlowStationSlot = .primary
    var cloudConfigured: Bool { !serialNumber.isEmpty && !accessKey.isEmpty && !secretKey.isEmpty }
}

enum EcoFlowCredentialStore {
    private static let service = "com.untitledca.EcoFlowCat.connections"
    static func read(_ key: String) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: key,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func write(_ value: String, for key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: key]
        if value.isEmpty { SecItemDelete(query as CFDictionary); return }
        let update: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query.merging(update) { _, value in value }
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(addition as CFDictionary, nil) == errSecSuccess else {
                throw EcoFlowWirelessError.message("Could not save connection credentials in macOS Keychain.")
            }
        } else if status != errSecSuccess {
            throw EcoFlowWirelessError.message("Could not update connection credentials in macOS Keychain.")
        }
    }
}

@MainActor
final class EcoFlowConnectionMonitor {
    typealias TransportSnapshot = (EcoFlowTransport, EcoFlowConnectionConfiguration) async throws -> PowerTelemetry
    typealias DiagnosticRecorder = (String, String, [String: Any]) -> Void
    private let usb = DirectEcoFlowMonitor()
    private let bluetooth = EcoFlowBluetoothMonitor()
    private let cloud = EcoFlowCloudMonitor()
    private var diagnosticThrottle = SupportDiagnosticThrottle()
    private var diagnosticOutcomes: [EcoFlowTransport: String] = [:]
    private var diagnosticStationSlot = EcoFlowStationSlot.primary
    private var generation = 0
    private let transportSnapshot: TransportSnapshot?
    private let blockingApp: (() -> String?)?
    private let diagnosticRecorder: DiagnosticRecorder?

    /// Injectable I/O keeps lifecycle regression tests entirely local. Normal
    /// app construction uses the concrete transports and production recorder.
    init(transportSnapshot: TransportSnapshot? = nil, blockingApp: (() -> String?)? = nil,
         diagnosticRecorder: DiagnosticRecorder? = nil) {
        self.transportSnapshot = transportSnapshot
        self.blockingApp = blockingApp
        self.diagnosticRecorder = diagnosticRecorder
    }

    /// Classify only known app families. Never put arbitrary process names or
    /// bundle identifiers in support reports. This cannot detect another Mac
    /// or phone using the station's Bluetooth connection.
    nonisolated static func blockingAppKind(name: String, bundleIdentifier: String) -> String? {
        let name = name.lowercased()
        let bundle = bundleIdentifier.lowercased()
        if name == "ecoflow" || bundle == "com.ef.ecoflow" || bundle == "com.ecoflow" { return "ecoflow" }
        if name == "powermanager" || bundle.contains("powermanager") { return "powermanager" }
        return nil
    }
    private static var runningBlockingApp: String? {
        NSWorkspace.shared.runningApplications.compactMap {
            blockingAppKind(name: $0.localizedName ?? "", bundleIdentifier: $0.bundleIdentifier ?? "")
        }.sorted().first
    }
    func snapshot(configuration: EcoFlowConnectionConfiguration) async throws -> PowerTelemetry {
        let requestGeneration = generation
        try requireCurrent(requestGeneration)
        diagnosticStationSlot = configuration.stationSlot
        let detectedBlockingApp: String?
        if let blockingApp { detectedBlockingApp = blockingApp() }
        else { detectedBlockingApp = Self.runningBlockingApp }
        if let blockingApp = detectedBlockingApp {
            bluetooth.stop()
            if diagnosticThrottle.shouldRecord("official_app_running:" + blockingApp, at: Date()) {
                record(category: "connection", event: "failure",
                    details: ["transport": configuration.transport.rawValue, "reason": "official_app_running",
                              "blockingApp": blockingApp, "stationSlot": configuration.stationSlot.rawValue])
            }
            throw EcoFlowWirelessError.message("Quit the EcoFlow app / PowerManager so Nacho Power can connect to the DELTA.")
        }
        switch configuration.transport {
        case .usb:
            bluetooth.stop(); return try await read(.usb, configuration: configuration, generation: requestGeneration)
        case .bluetooth:
            return try await read(.bluetooth, configuration: configuration, generation: requestGeneration)
        case .wifi:
            bluetooth.stop(); return try await read(.wifi, configuration: configuration, generation: requestGeneration)
        case .automatic:
            do {
                let value = try await read(.usb, configuration: configuration, generation: requestGeneration)
                try requireCurrent(requestGeneration)
                bluetooth.stop(); return value
            } catch {
                try requireCurrent(requestGeneration)
                if error is CancellationError { throw error }
                if !configuration.userID.isEmpty {
                    do { return try await read(.bluetooth, configuration: configuration, generation: requestGeneration) }
                    catch {
                        try requireCurrent(requestGeneration)
                        if error is CancellationError || !configuration.cloudConfigured { throw error }
                    }
                }
                try requireCurrent(requestGeneration)
                if configuration.cloudConfigured {
                    return try await read(.wifi, configuration: configuration, generation: requestGeneration)
                }
                throw EcoFlowWirelessError.message("Connect the DELTA by USB, or sign in under Connection settings for Bluetooth.")
            }
        }
    }
    func stop() {
        generation &+= 1
        bluetooth.stop(); usb.stop()
    }

    private func requireCurrent(_ requestGeneration: Int) throws {
        try Task.checkCancellation()
        guard requestGeneration == generation else { throw CancellationError() }
    }

    private func read(_ transport: EcoFlowTransport, configuration: EcoFlowConnectionConfiguration,
                      generation requestGeneration: Int) async throws -> PowerTelemetry {
        try await observedSnapshot(transport, generation: requestGeneration) {
            if let transportSnapshot { return try await transportSnapshot(transport, configuration) }
            switch transport {
            case .usb: return try await usb.snapshot(serialNumber: configuration.serialNumber)
            case .bluetooth: return try await bluetooth.snapshot(configuration: configuration)
            case .wifi: return try await cloud.snapshot(configuration: configuration)
            case .automatic: throw EcoFlowWirelessError.message("Choose a concrete EcoFlow connection transport.")
            }
        }
    }

    private func record(category: String, event: String, details: [String: Any]) {
        if let diagnosticRecorder { diagnosticRecorder(category, event, details) }
        else { SupportDiagnostics.shared.record(category: category, event: event, details: details) }
    }

    /// Observe existing attempts without changing their order, result, cadence,
    /// or error. Stable outcomes produce one compact record per 30 seconds.
    private func observedSnapshot(_ transport: EcoFlowTransport, generation requestGeneration: Int,
                                  operation: () async throws -> PowerTelemetry) async throws -> PowerTelemetry {
        do {
            try requireCurrent(requestGeneration)
            let value = try await operation()
            try requireCurrent(requestGeneration)
            let ac = value.acConnected.map { $0 ? "connected" : "disconnected" } ?? "unknown"
            let outcome = "success:" + ac
            let changed = diagnosticOutcomes[transport] != outcome
            diagnosticOutcomes[transport] = outcome
            if diagnosticThrottle.shouldRecord(transport.rawValue, at: Date(), interval: changed ? 0 : 30) {
                var details: [String: Any] = ["transport": transport.rawValue, "stationSlot": diagnosticStationSlot.rawValue, "acStatus": ac,
                    "hasBattery": value.batteryPercentage != nil, "hasACStatus": value.acConnected != nil,
                    "hasACWatts": value.acInputWatts != nil, "hasTotalWatts": value.totalInputWatts != nil,
                    "observationAge": max(0, Date().timeIntervalSince(value.timestamp))]
                if let battery = value.batteryPercentage { details["batteryPercentage"] = battery }
                if let watts = value.acInputWatts { details["acInputWatts"] = watts }
                if let watts = value.totalInputWatts { details["totalInputWatts"] = watts }
                if let connected = value.acConnected { details["acConnected"] = connected }
                record(category: transport.rawValue, event: "snapshot", details: details)
            }
            return value
        } catch {
            try requireCurrent(requestGeneration)
            if error is CancellationError { throw error }
            let reason = Self.diagnosticErrorReason(error)
            let outcome = "failure:" + reason
            let changed = diagnosticOutcomes[transport] != outcome
            diagnosticOutcomes[transport] = outcome
            if diagnosticThrottle.shouldRecord(transport.rawValue, at: Date(), interval: changed ? 0 : 30) {
                var details = SupportDiagnostics.errorDetails(error)
                details["transport"] = transport.rawValue
                details["stationSlot"] = diagnosticStationSlot.rawValue
                details["reason"] = reason
                record(category: transport.rawValue, event: "failure", details: details)
            }
            throw error
        }
    }

    private static func diagnosticErrorReason(_ error: Error) -> String {
        if let usb = error as? DirectEcoFlowError {
            switch usb {
            case .noDevice: return "no_devices"
            case .multipleDevices: return "multiple_devices"
            case .unsupportedDevice: return "unsupported"
            case .invalidReport: return "invalid_response"
            case .serialTimeout: return "timeout"
            case .powerManagerRunning, .serialBusy, .unavailable: return "unavailable"
            }
        }
        if let wireless = error as? EcoFlowWirelessError {
            switch wireless {
            case .authentication: return "authentication"
            case .invalidPacket: return "invalid_packet"
            case .unsupportedDevice: return "unsupported"
            case .message: return "other"
            }
        }
        if (error as NSError).domain == NSURLErrorDomain { return "network" }
        return "other"
    }
}

/// GET-only EcoFlow Developer API transport. Wi-Fi on these models reaches the
/// EcoFlow cloud; this class does not claim an undocumented direct LAN protocol.
actor EcoFlowCloudMonitor {
    private var latest: PowerTelemetry?
    private var previousConfiguration: EcoFlowConnectionConfiguration?
    private var lastAttempt = Date.distantPast
    private var lastError: Error?

    func snapshot(configuration: EcoFlowConnectionConfiguration) async throws -> PowerTelemetry {
        guard configuration.cloudConfigured else {
            throw EcoFlowWirelessError.message("Wi-Fi cloud needs the DELTA serial number and EcoFlow Developer access/secret keys in Connection settings.")
        }
        if previousConfiguration != configuration {
            latest = nil; lastAttempt = .distantPast; lastError = nil; previousConfiguration = configuration
        }
        // A modest request cadence avoids hammering the service. Never refresh a
        // cached reading's timestamp merely because the app polls it again.
        if Date().timeIntervalSince(lastAttempt) < 5 {
            if let lastError { throw lastError }
            if let latest { return latest }
        }
        lastAttempt = Date()
        do {
            let list = try await request(path: "/device/list", parameters: [:], configuration: configuration)
            guard let devices = list["data"] as? [[String: Any]],
                  let device = devices.first(where: { ($0["sn"] as? String)?.uppercased() == configuration.serialNumber.uppercased() }),
                  (device["online"] as? NSNumber)?.intValue == 1 else {
                throw EcoFlowWirelessError.message("The DELTA is offline in EcoFlow cloud. Connect it to Wi-Fi, or use Bluetooth / USB.")
            }
            let result = try await request(path: "/device/quota/all", parameters: ["sn": configuration.serialNumber], configuration: configuration)
            guard let data = result["data"] as? [String: Any] else { throw EcoFlowWirelessError.invalidPacket }
            let telemetry = try Self.telemetry(data: data, name: device["deviceName"] as? String ?? "EcoFlow DELTA", now: Date())
            latest = telemetry; lastError = nil; return telemetry
        } catch { latest = nil; lastError = error; throw error }
    }

    static func signedHeaders(parameters: [String: String], accessKey: String, secretKey: String,
                              nonce: String, timestamp: String) -> [String: String] {
        let query = parameters.keys.sorted().map { "\($0)=\(parameters[$0]!)" }.joined(separator: "&")
        let string = (query.isEmpty ? "" : query + "&") + "accessKey=\(accessKey)&nonce=\(nonce)&timestamp=\(timestamp)"
        let signature = HMAC<SHA256>.authenticationCode(for: Data(string.utf8), using: SymmetricKey(data: Data(secretKey.utf8)))
        return ["accessKey": accessKey, "nonce": nonce, "timestamp": timestamp,
                "sign": signature.map { String(format: "%02x", $0) }.joined()]
    }
    private func request(path: String, parameters: [String: String], configuration: EcoFlowConnectionConfiguration) async throws -> [String: Any] {
        var components = URLComponents()
        components.scheme = "https"; components.host = configuration.cloudRegion.host
        components.path = "/iot-open/sign" + path
        if !parameters.isEmpty { components.queryItems = parameters.keys.sorted().map { URLQueryItem(name: $0, value: parameters[$0]) } }
        guard let url = components.url else { throw EcoFlowWirelessError.invalidPacket }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = Self.signedHeaders(parameters: parameters, accessKey: configuration.accessKey,
            secretKey: configuration.secretKey, nonce: String(Int.random(in: 100000...999999)),
            timestamp: String(Int64(Date().timeIntervalSince1970 * 1000)))
        return try await EcoFlowAccount.perform(request)
    }
    static func telemetry(data: [String: Any], name: String, now: Date) throws -> PowerTelemetry {
        func number(_ keys: [String], range: ClosedRange<Double>) -> Double? {
            for key in keys {
                if let value = data[key] as? NSNumber, range.contains(value.doubleValue), value.doubleValue.isFinite { return value.doubleValue }
            }
            return nil
        }
        let battery = number(["cmsBattSoc", "bmsBattSoc", "pd.soc"], range: 0...100)
        let ac = number(["powGetAcIn", "inv.inputWatts"], range: 0...100_000)
        let total = number(["powInSumW", "pd.wattsInSum"], range: 0...100_000)
        let flag = number(["plugInInfoAcChargerFlag"], range: 0...1)
        let connected: Bool? = flag == 1 ? true : (flag == 0 ? false : nil)
        guard battery != nil else { throw EcoFlowWirelessError.message("EcoFlow cloud returned no supported battery reading. Use Bluetooth or USB for this device.") }
        return PowerTelemetry(deviceName: name, batteryPercentage: battery, acInputWatts: ac,
            totalInputWatts: total, acConnected: connected,
            sourceDescription: "Wi-Fi · EcoFlow cloud (may be delayed)", timestamp: now)
    }
}

enum EcoFlowAccount {
    /// The password is used only for this HTTPS request and is never persisted.
    /// Only the returned account identifier is needed for subsequent offline BLE.
    static func signIn(email: String, password: String, region: EcoFlowCloudRegion) async throws -> String {
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else {
            throw EcoFlowWirelessError.message("Enter your EcoFlow email and password.")
        }
        var request = URLRequest(url: URL(string: "https://\(region.host)/auth/login")!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "scene": "IOT_APP", "appVersion": "1.0.0", "userType": "ECOFLOW",
            "oauth": ["bundleId": "com.ef.EcoFlow"], "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
            "password": Data(password.utf8).base64EncodedString()])
        let response = try await perform(request)
        guard let data = response["data"] as? [String: Any], let user = data["user"] as? [String: Any] else {
            throw EcoFlowWirelessError.message("EcoFlow sign-in did not return an account user ID.")
        }
        let identifier = (user["userId"] as? String) ?? (user["userId"] as? NSNumber)?.stringValue
        guard let identifier, !identifier.isEmpty else { throw EcoFlowWirelessError.authentication }
        return identifier
    }
    fileprivate static func perform(_ request: URLRequest) async throws -> [String: Any] {
        // Ephemeral sessions avoid caching credentials, cookies, or auth tokens.
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw EcoFlowWirelessError.message("EcoFlow cloud request failed. Check your connection and account region.")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw EcoFlowWirelessError.invalidPacket }
        let code = (json["code"] as? String) ?? (json["code"] as? NSNumber)?.stringValue
        guard code == "0" else {
            // Do not echo arbitrary server response bodies, account info or tokens.
            throw EcoFlowWirelessError.message("EcoFlow rejected the request (code \(code ?? "unknown")). Check your credentials, region, and device API access.")
        }
        return json
    }
}
