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

    /// Open documents. Free builds hold at most one (opening replaces it); Pro opens
    /// each file in its own tab.
    @Published private(set) var documents: [TableDocument] = []
    /// Index of the active document within `documents`.
    @Published var activeIndex = 0
    @Published var errorMessage: String?

    /// The active document (what the rest of the UI reads).
    var document: TableDocument? {
        documents.indices.contains(activeIndex) ? documents[activeIndex] : documents.last
    }
    /// Drives the "Go to Row…" sheet (triggered by ⌘L).
    @Published var showGoToRow = false
    /// Drives the "Go to Column…" sheet.
    @Published var showGoToColumn = false
    /// Recently opened files (Open Recent menu), persisted via security bookmarks.
    @Published private(set) var recentFiles: [RecentFile] = Bookmarks.load()
    /// Named, reusable filters (Pro), persisted in UserDefaults.
    @Published private(set) var savedFilters: [SavedFilter] = SavedFiltersStore.load()

    /// Re-open the current document's file in place (e.g. after it changed on disk).
    func reopenCurrent() {
        guard let doc = document, let i = documents.firstIndex(where: { $0 === doc }) else { return }
        let url = doc.fileURL
        doc.close()
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            documents[i] = try TableDocument(url: url, securityScoped: scoped)
            errorMessage = nil
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            documents.remove(at: i)
            activeIndex = min(activeIndex, max(0, documents.count - 1))
            errorMessage = "Could not reopen \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Open a file URL (from NSOpenPanel, drag-drop, or Finder "Open With"). Pro opens
    /// it in a new tab; the free build replaces the single open document.
    func open(url: URL) {
        // Already open → just switch to it (a no-op in both free and Pro). Compare
        // symlink-resolved paths so /tmp vs /private/tmp or an alias still matches.
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        if let i = documents.firstIndex(where: {
            $0.fileURL.resolvingSymlinksInPath().standardizedFileURL == canonical }) {
            activeIndex = i
            return
        }

        let unlocked = PurchaseManager.shared.isUnlocked

        // Replacing the single free document would silently cancel an in-flight
        // export — confirm first.
        if !unlocked, let existing = documents.first, existing.isExporting {
            let alert = NSAlert()
            alert.messageText = "An export is in progress"
            alert.informativeText = "Opening another file will cancel the current export. Continue?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open Anyway")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        // NSOpenPanel / Finder-opened files are session-granted; calling start is
        // harmless and required when resolving from a bookmark later.
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            let doc = try TableDocument(url: url, securityScoped: scoped)
            if unlocked {
                documents.append(doc)
                activeIndex = documents.count - 1
            } else {
                documents.forEach { $0.close() }     // free: single document — replace
                documents = [doc]
                activeIndex = 0
            }
            errorMessage = nil
            rememberRecent(url)                       // bookmark while we have access
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            errorMessage = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Close a document tab, balancing its resources and adjusting the active index.
    func closeTab(_ doc: TableDocument) {
        guard let i = documents.firstIndex(where: { $0 === doc }) else { return }
        if doc.isExporting {
            let alert = NSAlert()
            alert.messageText = "An export is in progress"
            alert.informativeText = "Closing this tab will cancel the current export. Continue?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Close Anyway")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        doc.close()
        documents.remove(at: i)
        if documents.isEmpty {
            activeIndex = 0
        } else {
            if i < activeIndex { activeIndex -= 1 }
            activeIndex = min(activeIndex, documents.count - 1)
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

    // MARK: Saved filters

    /// Save (or overwrite by name) the given filter under `name`.
    func saveFilter(named name: String, _ filterSet: FilterSet) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let i = savedFilters.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            savedFilters[i].filterSet = filterSet
        } else {
            savedFilters.append(SavedFilter(name: trimmed, filterSet: filterSet))
        }
        SavedFiltersStore.save(savedFilters)
    }

    func deleteSavedFilter(_ filter: SavedFilter) {
        savedFilters.removeAll { $0.id == filter.id }
        SavedFiltersStore.save(savedFilters)
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
