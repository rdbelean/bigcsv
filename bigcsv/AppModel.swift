import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers

/// Top-level app state. Owns the single open document (the free app shows one
/// file at a time; opening another replaces it — multi-file/tabs is a paid
/// unlock) and routes every way a file can be opened into one place.
@MainActor
final class AppModel: ObservableObject {

    static let shared = AppModel()

    @Published private(set) var document: TableDocument?
    @Published var errorMessage: String?
    /// Drives the "Go to Row…" sheet (triggered by ⌘L).
    @Published var showGoToRow = false
    /// Recently opened files (Open Recent menu), persisted via security bookmarks.
    @Published private(set) var recentFiles: [RecentFile] = Bookmarks.load()

    /// Re-open the current document's file (e.g. after it changed on disk).
    func reopenCurrent() {
        guard let url = document?.fileURL else { return }
        open(url: url)
    }

    /// Open a file URL (from NSOpenPanel, drag-drop, or Finder "Open With").
    /// Replaces any currently open document.
    func open(url: URL) {
        // An in-flight export would be silently cancelled (and its partial file
        // removed) by the teardown below — confirm first so it's never a surprise.
        if document?.isExporting == true {
            let alert = NSAlert()
            alert.messageText = "An export is in progress"
            alert.informativeText = "Opening another file will cancel the current export. Continue?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open Anyway")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        // Tear down the previous document first (cancels indexing, releases the
        // mmap, balances its security scope).
        document?.close()
        document = nil

        // NSOpenPanel / Finder-opened files are session-granted; calling start is
        // harmless and required when resolving from a bookmark later (Phase 3).
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            document = try TableDocument(url: url, securityScoped: scoped)
            errorMessage = nil
            rememberRecent(url)        // bookmark while we have access
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            errorMessage = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: Recent files

    private func rememberRecent(_ url: URL) {
        guard let bookmark = Bookmarks.makeBookmark(for: url) else { return }
        let entry = RecentFile(name: url.lastPathComponent, path: url.path, bookmark: bookmark)
        recentFiles.removeAll { $0.path == entry.path }
        recentFiles.insert(entry, at: 0)
        if recentFiles.count > Bookmarks.maxRecent {
            recentFiles = Array(recentFiles.prefix(Bookmarks.maxRecent))
        }
        Bookmarks.save(recentFiles)
    }

    func openRecent(_ file: RecentFile) {
        guard let url = Bookmarks.resolve(file.bookmark) else {
            recentFiles.removeAll { $0.id == file.id }
            Bookmarks.save(recentFiles)
            errorMessage = "“\(file.name)” could not be found. It may have moved or been deleted."
            return
        }
        open(url: url)
    }

    func clearRecents() {
        recentFiles = []
        Bookmarks.save(recentFiles)
    }

    /// Present an open panel restricted to the delimited-text types we handle.
    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText, .text]
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url {
            open(url: url)
        }
    }
}
