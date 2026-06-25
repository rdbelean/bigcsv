import Foundation

/// One entry in the "Open Recent" menu, backed by an app-scoped security bookmark
/// so the sandboxed app can reopen the file across launches.
struct RecentFile: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var path: String
    var bookmark: Data
}

/// Creates / resolves / persists app-scoped security bookmarks for recent files.
/// (Requires the `com.apple.security.files.bookmarks.app-scope` entitlement.)
enum Bookmarks {

    private static let defaultsKey = "recentFiles.v1"
    static let maxRecent = 10

    /// Create a read-only app-scoped bookmark for a file the app currently has
    /// access to (NSOpenPanel / drag-drop / Finder-opened).
    static func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
    }

    /// Resolve a bookmark back to a (security-scoped) URL. Returns nil if it can't
    /// be resolved (e.g. the file moved/was deleted).
    static func resolve(_ data: Data) -> URL? {
        var stale = false
        let url = try? URL(resolvingBookmarkData: data,
                           options: [.withSecurityScope],
                           relativeTo: nil,
                           bookmarkDataIsStale: &stale)
        return url
    }

    // MARK: Persistence (a small Codable mirror stored in UserDefaults)

    private struct Stored: Codable { var name: String; var path: String; var bookmark: Data }

    static func load() -> [RecentFile] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode([Stored].self, from: data) else { return [] }
        return stored.map { RecentFile(name: $0.name, path: $0.path, bookmark: $0.bookmark) }
    }

    static func save(_ files: [RecentFile]) {
        let stored = files.map { Stored(name: $0.name, path: $0.path, bookmark: $0.bookmark) }
        UserDefaults.standard.set(try? JSONEncoder().encode(stored), forKey: defaultsKey)
    }
}
