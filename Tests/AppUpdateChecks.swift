import Foundation

@main
private struct AppUpdateChecks {
    @MainActor
    static func main() async throws {
        check(AppVersion("v1.2") == AppVersion("1.2.0.0"), "missing and trailing zero components compare equally")
        check(AppVersion("1.10")! > AppVersion("1.9.99")!, "multidigit components compare numerically")
        check(AppVersion("2")! > AppVersion("1.99999.99999")!, "major version takes precedence")
        check(AppVersion("1.0002.03") == AppVersion("1.2.3"), "zero padding cannot alter version ordering")
        check(AppVersion("1.999999999999999999999999999999")! > AppVersion("1.99999999999999999999999999999")!, "large numeric components never overflow")
        for value in ["", "v", "1..2", ".1", "1.", "1.2-beta", "1.2+build", " 1.2", "1.2\n", "-1.2", "1.٢", "v1/2", "V1.2"] {
            check(AppVersion(value) == nil, "malformed/prerelease version rejected: \(value)")
        }

        let valid = try fixture()
        let release = try AppRelease.decode(valid)
        check(release.version == "1.3.0", "v prefix stripped for display and asset selection")
        check(release.downloadURL.absoluteString == "https://github.com/untitledca/Nacho-Power/releases/download/v1.3.0/Nacho-Power-1.3.0-universal.dmg", "only matching universal installer selected")
        let cases: [(String, [String: Any])] = [
            ("draft", ["draft": true]),
            ("prerelease", ["prerelease": true]),
            ("suffix despite stable flag", ["tag_name": "v1.3.0-rc.1"]),
            ("wrong release repository", ["html_url": "https://github.com/elsewhere/Nacho-Power/releases/tag/v1.3.0"]),
            ("wrong release host", ["html_url": "https://github.com.attacker.test/untitledca/Nacho-Power/releases/tag/v1.3.0"]),
            ("release query", ["html_url": release.releaseURL.absoluteString + "?next=evil"]),
            ("wrong release tag", ["html_url": "https://github.com/untitledca/Nacho-Power/releases/tag/v1.4.0"]),
            ("missing installer", ["assets": []]),
            ("wrong installer name", ["assets": [asset(name: "Nacho-Power-1.3.0-arm64.dmg")]]),
            ("wrong installer URL", ["assets": [asset(url: "https://attacker.test/Nacho-Power-1.3.0-universal.dmg")]]),
            ("wrong installer tag", ["assets": [asset(url: "https://github.com/untitledca/Nacho-Power/releases/download/v0.1/Nacho-Power-1.3.0-universal.dmg")]]),
            ("credential-bearing URL", ["assets": [asset(url: "https://attacker@github.com/untitledca/Nacho-Power/releases/download/v1.3.0/Nacho-Power-1.3.0-universal.dmg")]]),
            ("incomplete upload", ["assets": [asset(state: "new")]]),
            ("empty installer", ["assets": [asset(size: 0)]]),
            ("ambiguous installers", ["assets": [asset(), asset()]]),
        ]
        for (description, replacement) in cases {
            do {
                _ = try AppRelease.decode(fixture(replacement))
                fatalError("FAIL accepted \(description)")
            } catch { }
        }
        do {
            _ = try AppRelease.decode(Data("not json".utf8))
            fatalError("FAIL accepted malformed response")
        } catch { }

        let domain = "EcoFlowCat.UpdateChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        func reset() { defaults.removePersistentDomain(forName: domain) }
        let clock = TestClock()
        let success = MockTransport(data: valid)
        let checker = AppUpdateChecker(currentVersion: "1.2.0", defaults: defaults, now: { clock.now }, fetch: { try await success.send($0) })
        check(checker.automaticallyChecksForUpdates, "automatic checks default enabled")
        await checker.checkAutomaticallyIfDue()
        check(checker.state == .updateAvailable && checker.latestRelease == release, "newer release produces in-app update state")
        check(checker.lastCheckedAt == clock.now && checker.errorMessage == nil, "successful check timestamp and clean error state")
        let requests = await success.requests
        check(requests.count == 1 && requests[0].url == AppRelease.apiURL, "single fixed public endpoint")
        check(requests[0].value(forHTTPHeaderField: "Authorization") == nil, "update checks never send credentials")
        check(requests[0].cachePolicy == .reloadIgnoringLocalCacheData && requests[0].timeoutInterval == 20, "fresh bounded metadata request")
        await checker.checkAutomaticallyIfDue()
        check(await success.requestCount == 1, "same-day automatic check throttled")

        let reopened = AppUpdateChecker(currentVersion: "1.2.0", defaults: defaults, now: { clock.now }, fetch: { try await success.send($0) })
        check(reopened.state == .updateAvailable && reopened.latestRelease == release, "validated successful result restored after relaunch")
        await reopened.checkAutomaticallyIfDue()
        check(await success.requestCount == 1, "same-day launch shares persisted throttle")
        clock.now.addTimeInterval(AppUpdateChecker.checkInterval)
        await reopened.checkAutomaticallyIfDue()
        check(await success.requestCount == 2, "automatic check runs again after one day")
        reopened.automaticallyChecksForUpdates = false
        clock.now.addTimeInterval(AppUpdateChecker.checkInterval)
        await reopened.checkAutomaticallyIfDue()
        check(await success.requestCount == 2, "disabled automatic checks never contact GitHub")
        await reopened.checkForUpdates()
        check(await success.requestCount == 3, "manual check works while automatic checks disabled")
        let disabled = AppUpdateChecker(currentVersion: "1.3.0", defaults: defaults)
        check(!disabled.automaticallyChecksForUpdates && disabled.state == .current, "preference persists and cache is compared with updated installed version")
        let ahead = AppUpdateChecker(currentVersion: "2.0.0", defaults: defaults)
        check(ahead.state == .current, "older public release never suggests a downgrade")

        reset()
        let offline = MockTransport(data: valid, error: URLError(.notConnectedToInternet))
        let failed = AppUpdateChecker(currentVersion: "1.2.0", defaults: defaults, now: { clock.now }, fetch: { try await offline.send($0) })
        await failed.checkAutomaticallyIfDue()
        check(failed.state == .unavailable && failed.errorMessage?.contains("Internet connection") == true, "offline check has useful retry guidance")
        check(failed.lastCheckedAt == nil && failed.latestRelease == nil, "offline does not pretend version is current")
        await failed.checkAutomaticallyIfDue()
        check(await offline.requestCount == 1, "failed automatic attempts also throttle")
        await failed.checkForUpdates()
        check(await offline.requestCount == 2, "manual retry bypasses failed-attempt throttle")
        await offline.setError(nil)
        await failed.checkForUpdates()
        check(failed.state == .updateAvailable && failed.errorMessage == nil, "manual retry recovers from offline")

        for status in [403, 429, 404, 500] {
            reset()
            let transport = MockTransport(data: valid, status: status)
            let instance = AppUpdateChecker(currentVersion: "1.2.0", defaults: defaults, fetch: { try await transport.send($0) })
            await instance.checkForUpdates()
            check(instance.state == .unavailable && instance.latestRelease == nil, "HTTP \(status) never advertises an installer")
            check(instance.errorMessage != nil, "HTTP \(status) supplies recovery explanation")
            if status == 403 || status == 429 { check(instance.errorMessage!.contains("limiting"), "rate limit guidance") }
        }
        reset()
        let invalid = MockTransport(data: valid, responseURL: URL(string: "https://attacker.test/releases")!)
        let invalidResponse = AppUpdateChecker(currentVersion: "1.2.0", defaults: defaults, fetch: { try await invalid.send($0) })
        await invalidResponse.checkForUpdates()
        check(invalidResponse.state == .unavailable, "response from different URL rejected")
        reset()
        let unknown = AppUpdateChecker(currentVersion: "Unknown", defaults: defaults, fetch: { _ in fatalError("Unknown installed version must not query") })
        await unknown.checkForUpdates()
        check(unknown.state == .unavailable, "unknown installed version never guesses current status")

        reset()
        let gate = MockTransport(data: valid, paused: true)
        let concurrent = AppUpdateChecker(currentVersion: "1.2.0", defaults: defaults, fetch: { try await gate.send($0) })
        let auto = Task { await concurrent.checkAutomaticallyIfDue() }
        await gate.waitForRequest()
        check(concurrent.state == .checking, "in-flight check is visible")
        let manual = Task { await concurrent.checkForUpdates() }
        let secondManual = Task { await concurrent.checkForUpdates() }
        for _ in 0..<20 { await Task.yield() }
        check(await gate.requestCount == 1, "manual and automatic callers coalesce while in flight")
        await gate.resume()
        await auto.value
        await manual.value
        await secondManual.value
        check(await gate.requestCount == 1 && concurrent.state == .updateAvailable, "coalesced callers share the completed result")

        reset()
        let manualGate = MockTransport(data: valid, paused: true)
        let manualFirst = AppUpdateChecker(currentVersion: "1.2.0", defaults: defaults, fetch: { try await manualGate.send($0) })
        var consistentStates = true
        manualFirst.onChange = {
            if manualFirst.state == .updateAvailable {
                consistentStates = consistentStates && manualFirst.latestRelease == release && manualFirst.errorMessage == nil
            }
        }
        let firstManual = Task { await manualFirst.checkForUpdates() }
        await manualGate.waitForRequest()
        let joiningAuto = Task { await manualFirst.checkAutomaticallyIfDue() }
        for _ in 0..<20 { await Task.yield() }
        check(await manualGate.requestCount == 1, "automatic caller joins an active manual check")
        await manualGate.resume()
        await firstManual.value
        await joiningAuto.value
        check(await manualGate.requestCount == 1 && manualFirst.state == .updateAvailable, "manual-first coalescing shares completion")
        check(consistentStates, "menu callbacks see coherent published result properties")
        manualFirst.onChange = nil

        print("PASS update version comparison, release/installer validation, recovery, persistence, daily scheduling, and concurrent checks")
    }

    private static func check(_ condition: Bool, _ message: String) {
        precondition(condition, "FAIL \(message)")
    }
    private static func asset(name: String = "Nacho-Power-1.3.0-universal.dmg",
                              url: String = "https://github.com/untitledca/Nacho-Power/releases/download/v1.3.0/Nacho-Power-1.3.0-universal.dmg",
                              state: String = "uploaded", size: Int = 1000) -> [String: Any] {
        ["name": name, "browser_download_url": url, "state": state, "size": size]
    }
    private static func fixture(_ replacements: [String: Any] = [:]) throws -> Data {
        var values: [String: Any] = [
            "tag_name": "v1.3.0", "html_url": "https://github.com/untitledca/Nacho-Power/releases/tag/v1.3.0",
            "draft": false, "prerelease": false, "assets": [asset()]
        ]
        values.merge(replacements) { _, replacement in replacement }
        return try JSONSerialization.data(withJSONObject: values)
    }
}

@MainActor private final class TestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

private actor MockTransport {
    let data: Data
    let status: Int
    let responseURL: URL
    var error: Error?
    var paused: Bool
    private(set) var requests: [URLRequest] = []
    var requestCount: Int { requests.count }
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var responseWaiters: [CheckedContinuation<Void, Never>] = []

    init(data: Data, status: Int = 200, responseURL: URL = AppRelease.apiURL, error: Error? = nil, paused: Bool = false) {
        self.data = data
        self.status = status
        self.responseURL = responseURL
        self.error = error
        self.paused = paused
    }
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        requestWaiters.forEach { $0.resume() }
        requestWaiters.removeAll()
        if paused { await withCheckedContinuation { responseWaiters.append($0) } }
        if let error { throw error }
        return (data, HTTPURLResponse(url: responseURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
    func waitForRequest() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }
    func resume() {
        paused = false
        responseWaiters.forEach { $0.resume() }
        responseWaiters.removeAll()
    }
    func setError(_ value: Error?) { error = value }
}
