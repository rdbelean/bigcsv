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
                .foregroundStyle(.secondary)
                .help("Delimiter")
            Text(document.dialect.encoding.displayName)
                .foregroundStyle(.secondary)
                .help("Text encoding")

            if document.unsupportedEncoding != nil {
                Label("Unsupported encoding", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if !document.progress.isComplete {
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
