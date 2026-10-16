import Combine
import Foundation

/// Release versions are numeric components, optionally prefixed by `v`.
/// Compare as decimal strings so even an oversized component cannot overflow.
struct AppVersion: Comparable {
    let components: [String]

    init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        guard !value.isEmpty, value.count <= 128 else { return nil }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 8, parts.allSatisfy({ part in
            !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) }
        }) else { return nil }
        var normalized = parts.map { part -> String in
            let digits = part.drop(while: { $0 == "0" })
            return digits.isEmpty ? "0" : String(digits)
        }
        while normalized.count > 1, normalized.last == "0" { normalized.removeLast() }
        components = normalized
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : "0"
            let right = index < rhs.components.count ? rhs.components[index] : "0"
            if left.count != right.count { return left.count < right.count }
            if left != right { return left.lexicographicallyPrecedes(right) }
        }
        return false
    }
}

struct AppRelease: Equatable {
    let version: String
    let releaseURL: URL
    let downloadURL: URL

    static let releasesURL = URL(string: "https://github.com/untitledca/Nacho-Power/releases/latest")!
    static let apiURL = URL(string: "https://api.github.com/repos/untitledca/Nacho-Power/releases/latest")!

    static func decode(_ data: Data) throws -> AppRelease {
        guard data.count <= 2_000_000,
              let release = try? JSONDecoder().decode(GitHubRelease.self, from: data),
              !release.draft, !release.prerelease,
              AppVersion(release.tagName) != nil else {
            throw AppUpdateError.invalidRelease
        }
        let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        let base = "https://github.com/untitledca/Nacho-Power/releases"
        let expectedPage = "\(base)/tag/\(release.tagName)"
        let expectedName = "Nacho-Power-\(version)-universal.dmg"
        let expectedDownload = "\(base)/download/\(release.tagName)/\(expectedName)"
        // Exact URLs exclude other hosts/repositories, credentials, ports,
        // query parameters, redirects disguised as links, and traversal.
        guard release.htmlURL == expectedPage,
              let pageURL = URL(string: expectedPage) else {
            throw AppUpdateError.invalidRelease
        }
        let installers = release.assets.filter { $0.name == expectedName }
        guard installers.count == 1, let installer = installers.first,
              installer.state == "uploaded", installer.size > 0,
              installer.browserDownloadURL == expectedDownload,
              let downloadURL = URL(string: expectedDownload) else {
            throw AppUpdateError.missingInstaller
        }
        return AppRelease(version: version, releaseURL: pageURL, downloadURL: downloadURL)
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", htmlURL = "html_url", draft, prerelease, assets
        }
    }
    private struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String
        let state: String
        let size: Int64
        enum CodingKeys: String, CodingKey {
            case name, browserDownloadURL = "browser_download_url", state, size
        }
    }
}

enum AppUpdateState: Equatable {
    case notChecked, checking, current, updateAvailable, unavailable
}

enum AppUpdateError: Error, LocalizedError {
    case invalidRelease, missingInstaller, invalidResponse, rateLimited, noRelease, server(Int), invalidCurrentVersion

    var errorDescription: String? {
        switch self {
        case .invalidRelease: return "GitHub returned an unrecognized release. You can check the releases page instead."
        case .missingInstaller: return "The latest release’s Mac installer is not ready. Try again later or visit GitHub Releases."
        case .invalidResponse: return "The update server returned an unexpected response. Try again or visit GitHub Releases."
        case .rateLimited: return "GitHub is limiting update checks. Try again later or visit GitHub Releases."
        case .noRelease: return "No published release was found. You can check GitHub Releases instead."
        case .server(let status): return "GitHub could not check for updates (HTTP \(status)). Try again later."
        case .invalidCurrentVersion: return "This copy’s version could not be read. Please check GitHub Releases."
        }
    }
}

/// Update checks only read public release metadata. Installation and opening
/// either validated URL remain explicit user actions in the application UI.
@MainActor
final class AppUpdateChecker: ObservableObject {
    typealias Fetch = (URLRequest) async throws -> (Data, URLResponse)
    typealias AutomaticScheduler = @MainActor (@escaping () -> Void) -> () -> Void

    static let releasesURL = AppRelease.releasesURL
    static let automaticPreferenceKey = "automaticallyChecksForUpdates"
    static let lastAttemptPreferenceKey = "appUpdateLastAttempt"
    static let lastSuccessPreferenceKey = "appUpdateLastSuccess"
    static let cachedReleasePreferenceKey = "appUpdateCachedRelease"
    static let checkInterval: TimeInterval = 24 * 60 * 60

    @Published private(set) var state: AppUpdateState = .notChecked
    @Published private(set) var latestRelease: AppRelease?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastCheckedAt: Date?
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            guard automaticallyChecksForUpdates != oldValue else { return }
            defaults.set(automaticallyChecksForUpdates, forKey: Self.automaticPreferenceKey)
            onChange?()
            if automaticallyChecksForUpdates && isStarted {
                // Opting in is an explicit request to begin checking now, even
                // if a recent manual check or failed attempt is on record.
                Task { [weak self] in
                    guard let self, self.isStarted, self.automaticallyChecksForUpdates else { return }
                    await self.checkForUpdates()
                }
            }
        }
    }
    let currentVersion: String
    var onChange: (() -> Void)?

    private let defaults: UserDefaults
    private let fetch: Fetch
    private let now: () -> Date
    private let scheduleAutomaticChecks: AutomaticScheduler
    private var checkTask: Task<Void, Never>?
    private var cancelAutomaticSchedule: (() -> Void)?
    private var isStarted = false

    init(currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown",
         defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init,
         scheduleAutomaticChecks: @escaping AutomaticScheduler = AppUpdateChecker.scheduleTimer,
         fetch: @escaping Fetch = AppUpdateChecker.fetchLatestRelease) {
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.now = now
        self.scheduleAutomaticChecks = scheduleAutomaticChecks
        self.fetch = fetch
        automaticallyChecksForUpdates = defaults.object(forKey: Self.automaticPreferenceKey) as? Bool ?? false
        if let checked = defaults.object(forKey: Self.lastSuccessPreferenceKey) as? Date,
           let data = defaults.data(forKey: Self.cachedReleasePreferenceKey),
           let release = try? AppRelease.decode(data),
           let installed = AppVersion(currentVersion), let available = AppVersion(release.version) {
            latestRelease = release
            lastCheckedAt = checked
            state = available > installed ? .updateAvailable : .current
        }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        // Revisit the due time while the app stays open, including after sleep.
        cancelAutomaticSchedule = scheduleAutomaticChecks { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isStarted else { return }
                await self.checkAutomaticallyIfDue()
            }
        }
        Task { [weak self] in
            guard let self, self.isStarted else { return }
            await self.checkAutomaticallyIfDue()
        }
    }

    func stop() {
        isStarted = false
        cancelAutomaticSchedule?()
        cancelAutomaticSchedule = nil
        checkTask?.cancel()
    }

    private static func scheduleTimer(_ callback: @escaping () -> Void) -> () -> Void {
        let timer = Timer(timeInterval: 60 * 60, repeats: true) { _ in callback() }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }

    func checkAutomaticallyIfDue() async {
        guard automaticallyChecksForUpdates else { return }
        if let task = checkTask { await task.value; return }
        if let previous = defaults.object(forKey: Self.lastAttemptPreferenceKey) as? Date {
            let elapsed = now().timeIntervalSince(previous)
            // A changed clock must not suppress all future checks.
            guard elapsed < 0 || elapsed >= Self.checkInterval else { return }
        }
        await checkForUpdates()
    }

    /// Manual checks bypass the daily throttle but share any active request.
    func checkForUpdates() async {
        if let task = checkTask { await task.value; return }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performCheck()
        }
        checkTask = task
        await task.value
        checkTask = nil
    }

    private func performCheck() async {
        state = .checking
        errorMessage = nil
        onChange?()
        // Persist attempts, including offline/rate-limited failures, so frequent
        // launches do not repeatedly contact GitHub. Manual retry stays usable.
        defaults.set(now(), forKey: Self.lastAttemptPreferenceKey)
        do {
            guard let installed = AppVersion(currentVersion) else { throw AppUpdateError.invalidCurrentVersion }
            var request = URLRequest(url: AppRelease.apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("Nacho-Power/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await fetch(request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.url == AppRelease.apiURL else {
                throw AppUpdateError.invalidResponse
            }
            switch http.statusCode {
            case 200: break
            case 403, 429: throw AppUpdateError.rateLimited
            case 404: throw AppUpdateError.noRelease
            default: throw AppUpdateError.server(http.statusCode)
            }
            let release = try AppRelease.decode(data)
            guard let available = AppVersion(release.version) else { throw AppUpdateError.invalidRelease }
            latestRelease = release
            lastCheckedAt = now()
            defaults.set(data, forKey: Self.cachedReleasePreferenceKey)
            defaults.set(lastCheckedAt, forKey: Self.lastSuccessPreferenceKey)
            state = available > installed ? .updateAvailable : .current
        } catch is CancellationError {
            state = .notChecked
        } catch {
            if let error = error as? URLError {
                switch error.code {
                case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                    errorMessage = "Couldn’t reach GitHub. Check your Internet connection and try again."
                case .timedOut:
                    errorMessage = "The update check timed out. Try again or visit GitHub Releases."
                default:
                    errorMessage = "Couldn’t check for updates. Try again or visit GitHub Releases."
                }
            } else {
                errorMessage = error.localizedDescription
            }
            state = .unavailable
        }
        onChange?()
    }

    nonisolated private static func fetchLatestRelease(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: UpdateRedirectPolicy(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }
}

private final class UpdateRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // The public metadata endpoint is fixed; never follow redirects to
        // another repository, an authentication page, or an arbitrary host.
        completionHandler(nil)
    }
}
