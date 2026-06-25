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

    /// Re-open the current document's file (e.g. after it changed on disk).
    func reopenCurrent() {
        guard let url = document?.fileURL else { return }
        open(url: url)
    }

    /// Open a file URL (from NSOpenPanel, drag-drop, or Finder "Open With").
    /// Replaces any currently open document.
    func open(url: URL) {
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
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            errorMessage = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
        }
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
