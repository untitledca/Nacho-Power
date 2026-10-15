import Foundation

/// Reuses the numeric identity of a single account previously signed in to the
/// official Mac EcoFlow app. This reads container metadata and directory names
/// only: never account databases, preferences contents, passwords, or tokens.
enum EcoFlowAccountDiscovery {
    private static let officialBundleID = "com.ef.EcoFlow"
    private static let metadataName = ".com.apple.containermanagerd.metadata.plist"

    /// Filesystem access happens away from the main actor. A denied or slow
    /// container lookup simply leaves the app's normal sign-in flow available.
    static func discover() async -> String? {
        let containers = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
        return await withCheckedContinuation { continuation in
            let completion = DiscoveryCompletion(continuation)
            let deadline = Date().addingTimeInterval(4)
            DispatchQueue.global(qos: .utility).async {
                completion.finish(discover(in: containers, deadline: deadline))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4) {
                completion.finish(nil)
            }
        }
    }

    /// Internal seam for filesystem fixtures. A single ID may appear in more
    /// than one region/container; different IDs always require explicit sign-in.
    static func discover(in containers: URL, deadline: Date = .distantFuture) -> String? {
        let files = FileManager.default
        guard Date() < deadline,
              let candidates = try? files.contentsOfDirectory(at: containers,
                                                               includingPropertiesForKeys: nil,
                                                               options: [.skipsHiddenFiles]) else { return nil }
        var accountIDs = Set<String>()
        var foundOfficialContainer = false
        for candidate in candidates {
            guard Date() < deadline else { return nil }
            guard itemType(at: candidate, files: files) == .typeDirectory,
                  isOfficialContainer(candidate, files: files) else { continue }
            foundOfficialContainer = true
            let dataCenters = candidate.appendingPathComponent("Data/Documents/DataCenters", isDirectory: true)
            guard itemType(at: dataCenters, files: files) == .typeDirectory,
                  let regions = try? files.contentsOfDirectory(at: dataCenters,
                                                               includingPropertiesForKeys: nil,
                                                               options: [.skipsHiddenFiles]) else {
                // Inaccessible account metadata cannot establish uniqueness.
                return nil
            }
            for region in regions {
                guard Date() < deadline else { return nil }
                guard itemType(at: region, files: files) == .typeDirectory else { continue }
                let users = region.appendingPathComponent("users", isDirectory: true)
                guard files.fileExists(atPath: users.path) else { continue }
                guard itemType(at: users, files: files) == .typeDirectory,
                      let accounts = try? files.contentsOfDirectory(at: users,
                                                                   includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles]) else { return nil }
                for account in accounts {
                    guard Date() < deadline else { return nil }
                    let name = account.lastPathComponent
                    guard isNumericAccountID(name), itemType(at: account, files: files) == .typeDirectory else { continue }
                    accountIDs.insert(name)
                    guard accountIDs.count <= 1 else { return nil }
                }
            }
        }
        return foundOfficialContainer && accountIDs.count == 1 ? accountIDs.first : nil
    }

    private static func isOfficialContainer(_ container: URL, files: FileManager) -> Bool {
        let metadata = container.appendingPathComponent(metadataName)
        if let data = try? Data(contentsOf: metadata),
           let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let identifier = dictionary["MCMMetadataIdentifier"] as? String {
            return identifier == officialBundleID
        }
        // macOS can protect the container manager's plist while allowing the
        // app's directory metadata. Stat this exact EcoFlow preference marker;
        // do not enumerate or read any unrelated application's data directory.
        let marker = container.appendingPathComponent("Data/Library/Preferences/\(officialBundleID).plist")
        return itemType(at: marker, files: files) == .typeRegular
    }

    private static func isNumericAccountID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 32 && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func itemType(at url: URL, files: FileManager) -> FileAttributeType? {
        (try? files.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType
    }

    private final class DiscoveryCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String?, Never>?

        init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }

        func finish(_ value: String?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }
}
