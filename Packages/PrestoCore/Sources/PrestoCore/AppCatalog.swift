import Foundation

public struct AppEntry: Sendable, Hashable {
    /// Unique display name, also the Jev category name.
    public var name: String
    public var url: URL
    public var bundleID: String?

    public init(name: String, url: URL, bundleID: String?) {
        self.name = name
        self.url = url
        self.bundleID = bundleID
    }
}

/// The apps Presto can open, quit, or hide, by the names people say.
public struct AppCatalog: Sendable {
    public private(set) var entries: [AppEntry]
    private var byName: [String: AppEntry]

    public init(entries: [AppEntry]) {
        var seen: [String: AppEntry] = [:]
        for entry in entries where seen[entry.name] == nil { seen[entry.name] = entry }
        self.entries = seen.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        byName = seen
    }

    public func entry(named name: String) -> AppEntry? { byName[name] }

    public static let searchDirectories: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/Applications/Utilities"),
        URL(fileURLWithPath: "/System/Applications"),
        URL(fileURLWithPath: "/System/Applications/Utilities"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
    ]

    /// Helpers nobody asks for by voice, which only make Jev's choice harder.
    static func isNoise(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return ["uninstall", "url handler", "debug", "helper", "restore"].contains { lowered.contains($0) }
    }

    /// Scans the standard app folders. Earlier folders win for duplicate names.
    public static func scan(directories: [URL] = searchDirectories) -> AppCatalog {
        var entries: [AppEntry] = []
        let fm = FileManager.default
        for directory in directories {
            guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { continue }
            for url in items where url.pathExtension == "app" {
                let name = url.deletingPathExtension().lastPathComponent
                guard !isNoise(name) else { continue }
                entries.append(AppEntry(name: name, url: url, bundleID: Bundle(url: url)?.bundleIdentifier))
            }
        }
        return AppCatalog(entries: entries)
    }

    /// Adds apps that are running from elsewhere (a DMG, Xcode's build folder).
    public func adding(_ more: [AppEntry]) -> AppCatalog {
        AppCatalog(entries: entries + more.filter { !Self.isNoise($0.name) })
    }
}
