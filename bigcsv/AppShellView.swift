import SwiftUI
import UniformTypeIdentifiers

/// The window's root view: either the empty drop-zone (no file open) or the data
/// grid plus a status bar. Accepts file drops anywhere in the window.
struct AppShellView: View {
    @EnvironmentObject var appModel: AppModel

    var body: some View {
        Group {
            if let document = appModel.document {
                VStack(spacing: 0) {
                    CSVTableView(document: document)
                        .id(ObjectIdentifier(document))   // fresh table per file
                    Divider()
                    StatusBarView(document: document)
                }
            } else {
                EmptyStateView { appModel.presentOpenPanel() }
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            appModel.open(url: url)
            return true
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appModel.presentOpenPanel()
                } label: {
                    Label("Open", systemImage: "folder")
                }
                .help("Open a CSV or TSV file (⌘O)")
            }
        }
        .alert("Couldn’t open file",
               isPresented: Binding(get: { appModel.errorMessage != nil },
                                    set: { if !$0 { appModel.errorMessage = nil } })) {
            Button("OK", role: .cancel) { appModel.errorMessage = nil }
        } message: {
            Text(appModel.errorMessage ?? "")
        }
    }
}

/// Shown before any file is open: a friendly drop target for non-technical users.
struct EmptyStateView: View {
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "tablecells")
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text("Open a big CSV — instantly")
                    .font(.title2.weight(.semibold))
                Text("Drag a .csv or .tsv file here, or choose one to open.")
                    .foregroundStyle(.secondary)
            }
            Button(action: onOpen) {
                Text("Open File…").padding(.horizontal, 8)
            }
            .controlSize(.large)
            .keyboardShortcut("o", modifiers: .command)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

/// Minimal Phase-1 status bar: row/column counts and live indexing progress.
/// (Encoding, delimiter, and file size join in Phase 2.)
struct StatusBarView: View {
    @ObservedObject var document: TableDocument

    var body: some View {
        HStack(spacing: 14) {
            Text("\(document.displayRowCount.formatted()) rows")
            if document.columnCount > 0 {
                Text("\(document.columnCount) columns")
            }
            Text(fileSizeText)
                .foregroundStyle(.secondary)

            Spacer()

            if !document.progress.isComplete {
                HStack(spacing: 8) {
                    ProgressView(value: document.progress.fractionComplete)
                        .frame(width: 120)
                    Text("Indexing… \(Int(document.progress.fractionComplete * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else {
                Label("Ready", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var fileSizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(document.fileSize), countStyle: .file)
    }
}
