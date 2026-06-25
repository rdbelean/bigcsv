import SwiftUI
import UniformTypeIdentifiers

/// The window's root view: either the empty drop-zone (no file open) or the
/// document view. Accepts file drops anywhere in the window.
struct AppShellView: View {
    @EnvironmentObject var appModel: AppModel

    var body: some View {
        Group {
            if let document = appModel.document {
                DocumentView(document: document)
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
                Button { appModel.presentOpenPanel() } label: {
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

/// Hosts the data grid (or a warning), the status bar, the format menu, and the
/// go-to-row / inspector sheets. Observes the document so its published state
/// (progress, file-changed, inspected row) drives the UI.
struct DocumentView: View {
    @ObservedObject var document: TableDocument
    @EnvironmentObject var appModel: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if document.fileChangedExternally {
                FileChangedBanner { appModel.reopenCurrent() }
            }
            if let unsupported = document.unsupportedEncoding {
                UnsupportedEncodingView(encoding: unsupported,
                                        fileName: document.fileURL.lastPathComponent)
            } else {
                CSVTableView(document: document)
                    .id(ObjectIdentifier(document))   // fresh table per file
            }
            Divider()
            StatusBarView(document: document)
        }
        .toolbar { FormatMenu(document: document) }
        .sheet(isPresented: $appModel.showGoToRow) {
            GoToRowSheet(document: document)
        }
        .sheet(isPresented: Binding(get: { document.inspectedRow != nil },
                                    set: { if !$0 { document.inspectedRow = nil } })) {
            if let row = document.inspectedRow {
                RowInspectorView(document: document, displayRow: row)
            }
        }
    }
}

/// Toolbar menu to override the auto-detected delimiter / encoding and toggle the
/// header row.
struct FormatMenu: ToolbarContent {
    @ObservedObject var document: TableDocument

    var body: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Menu {
                Picker("Delimiter", selection: Binding(
                    get: { document.dialect.delimiter },
                    set: { document.setDelimiter($0) })) {
                    ForEach(Delimiter.allCases, id: \.self) { d in
                        Text("\(d.displayName)  (\(d.displaySymbol))").tag(d)
                    }
                }
                Picker("Encoding", selection: Binding(
                    get: { document.dialect.encoding },
                    set: { document.setEncoding($0) })) {
                    ForEach(TextEncoding.allCases, id: \.self) { e in
                        Text(e.displayName).tag(e)
                    }
                }
                Divider()
                Toggle("First Row Is Header", isOn: Binding(
                    get: { document.dialect.hasHeader },
                    set: { document.setHasHeader($0) }))
            } label: {
                Label("Format", systemImage: "tablecells.badge.ellipsis")
            }
            .help("Delimiter, encoding, and header options")
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

/// Shown when the file is in an encoding we can't safely byte-index.
struct UnsupportedEncodingView: View {
    let encoding: UnsupportedEncoding
    let fileName: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(.orange)
            Text("This file is \(encoding.rawValue)")
                .font(.title3.weight(.semibold))
            Text("“\(fileName)” uses a two-byte encoding that BigCSV can’t open yet. "
                 + "Re-save it as UTF-8 (most spreadsheet apps offer this on export) and try again.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

/// A thin banner shown when the underlying file changed on disk.
struct FileChangedBanner: View {
    let onReopen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("This file changed on disk — the view may be out of date.")
            Spacer()
            Button("Reopen", action: onReopen)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.15))
    }
}

/// "Go to Row…" sheet (⌘L).
struct GoToRowSheet: View {
    @ObservedObject var document: TableDocument
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Go to Row").font(.headline)
            Text("Enter a row number (1–\(document.displayRowCount.formatted())).")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Row number", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit(go)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Go", action: go).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func go() {
        if let n = Int(text.trimmingCharacters(in: .whitespaces)), n >= 1 {
            document.requestScrollToRow(n - 1)
        }
        dismiss()
    }
}

/// Inspector showing every column value of one row in full (untruncated,
/// selectable) — handy for huge cells and embedded newlines.
struct RowInspectorView: View {
    @ObservedObject var document: TableDocument
    let displayRow: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let fields = document.rowFields(displayRow: displayRow)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Row \(displayRow + 1)").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(document.columnTitles.enumerated()), id: \.offset) { index, title in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(.caption).foregroundStyle(.secondary)
                            Text(index < fields.count ? fields[index] : "")
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        }
        .frame(width: 460, height: 520)
    }
}

/// Status bar: row/column counts, file size, detected delimiter + encoding, and
/// live indexing progress.
struct StatusBarView: View {
    @ObservedObject var document: TableDocument

    var body: some View {
        HStack(spacing: 14) {
            Text("\(document.displayRowCount.formatted()) rows")
            if document.columnCount > 0 {
                Text("\(document.columnCount) columns")
            }
            Text(fileSizeText).foregroundStyle(.secondary)

            Spacer()

            Text(document.dialect.delimiter.displayName)
                .foregroundStyle(.secondary).help("Delimiter")
            Text(document.dialect.encoding.displayName)
                .foregroundStyle(.secondary).help("Text encoding")

            if document.unsupportedEncoding != nil {
                Label("Unsupported encoding", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if !document.progress.isComplete {
                HStack(spacing: 8) {
                    ProgressView(value: document.progress.fractionComplete)
                        .frame(width: 120)
                    Text("Indexing… \(Int(document.progress.fractionComplete * 100))%")
                        .foregroundStyle(.secondary).monospacedDigit()
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
