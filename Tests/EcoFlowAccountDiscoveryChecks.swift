import Foundation

@main
struct EcoFlowAccountDiscoveryChecks {
    static func main() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("EcoFlowAccountDiscovery-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }

        func container(_ name: String, identifier: String? = "com.ef.EcoFlow", marker: Bool = false) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try files.createDirectory(at: url, withIntermediateDirectories: true)
            if let identifier {
                let data = try PropertyListSerialization.data(fromPropertyList: ["MCMMetadataIdentifier": identifier], format: .binary, options: 0)
                try data.write(to: url.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
            }
            if marker {
                let preferences = url.appendingPathComponent("Data/Library/Preferences", isDirectory: true)
                try files.createDirectory(at: preferences, withIntermediateDirectories: true)
                // Deliberately invalid content: discovery must never parse it.
                try Data("not read by discovery".utf8).write(to: preferences.appendingPathComponent("com.ef.EcoFlow.plist"))
            }
            return url
        }
        func account(_ id: String, in container: URL, region: String = "us") throws -> URL {
            let path = container.appendingPathComponent("Data/Documents/DataCenters/\(region)/users/\(id)", isDirectory: true)
            try files.createDirectory(at: path, withIntermediateDirectories: true)
            return path
        }
        func check(_ expected: String?, _ message: String) {
            precondition(EcoFlowAccountDiscovery.discover(in: root) == expected, message)
        }

        check(nil, "No official container requires sign-in")
        let unrelated = try container("unrelated", identifier: "com.example.unrelated", marker: true)
        _ = try account("999", in: unrelated)
        check(nil, "Explicitly unrelated metadata takes precedence over a misleading marker")

        let official = try container("random-container-uuid")
        let primary = try account("1234567890123456789", in: official)
        check("1234567890123456789", "One official account is discovered without container UUID assumptions")
        _ = try account("1234567890123456789", in: official, region: "default")
        _ = try account("not-an-id", in: official)
        _ = try account("１２３４", in: official)
        check("1234567890123456789", "Regions deduplicate; non-ASCII and nonnumeric names are ignored")

        let second = try account("4567890123456789", in: official)
        check(nil, "Multiple cached accounts must not be guessed")
        try files.removeItem(at: second)
        check("1234567890123456789", "Single account is available again")

        let fallback = try container("fallback-uuid", identifier: nil, marker: true)
        _ = try account("1234567890123456789", in: fallback)
        check("1234567890123456789", "Exact official preference marker supports protected metadata")
        try files.removeItem(at: official)
        check("1234567890123456789", "Fallback works independently of readable metadata")

        let symlinkContainer = root.appendingPathComponent("symlink-container")
        try files.createSymbolicLink(at: symlinkContainer, withDestinationURL: fallback)
        check("1234567890123456789", "Discovery does not follow container symlinks")
        try files.removeItem(at: symlinkContainer)

        let users = fallback.appendingPathComponent("Data/Documents/DataCenters/us/users", isDirectory: true)
        let symlinkAccount = users.appendingPathComponent("22222")
        try files.createSymbolicLink(at: symlinkAccount, withDestinationURL: primary)
        check("1234567890123456789", "Numeric symlinks cannot supply another account")
        precondition(EcoFlowAccountDiscovery.discover(in: root, deadline: .distantPast) == nil,
                     "Expired lookup cannot return an account")
        print("EcoFlow account discovery checks passed")
        if CommandLine.arguments.contains("--live") {
            let discovered = await EcoFlowAccountDiscovery.discover()
            print("Live official account metadata discovered: \(discovered != nil)")
        }
    }
}
