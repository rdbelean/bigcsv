import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The window's root view: either the empty drop-zone (no file open) or the
/// document view. Accepts file drops anywhere in the window.
struct AppShellView: View {
    @EnvironmentObject var appModel: AppModel
    @EnvironmentObject var purchase: PurchaseManager

    var body: some View {
        Group {
            if let document = appModel.document {
                VStack(spacing: 0) {
                    if appModel.documents.count > 1 {
                        TabBarView()
                        Divider()
                    }
                    DocumentView(document: document)
                        .id(document.id)        // fresh document view per active tab
                }
            } else {
                EmptyStateView(onOpen: { appModel.presentOpenPanel() },
                               recentFiles: appModel.recentFiles,
                               onOpenRecent: { appModel.openRecent($0) })
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            appModel.open(url: url)
            return true
        }
        .alert("Couldn’t open file",
               isPresented: Binding(get: { appModel.errorMessage != nil },
                                    set: { if !$0 { appModel.errorMessage = nil } })) {
            Button("OK", role: .cancel) { appModel.errorMessage = nil }
        } message: {
            Text(appModel.errorMessage ?? "")
        }
        .sheet(item: $purchase.paywallContext) { context in
            PaywallView(purchase: purchase, feature: context.feature)
        }
        .sheet(isPresented: $appModel.showWelcome) {
            WelcomeSheet(purchase: purchase)
        }
        // Decide only after StoreKit's first entitlement check, so an already-unlocked
        // user never sees a momentary flash. maybeShowWelcome is once-only + idempotent.
        .onAppear {
            if purchase.entitlementsLoaded { appModel.maybeShowWelcome(unlocked: purchase.isUnlocked) }
        }
        .onChange(of: purchase.entitlementsLoaded) { _, loaded in
            if loaded { appModel.maybeShowWelcome(unlocked: purchase.isUnlocked) }
        }
    }
}

/// Tab strip for multiple open files (Pro). Shown only when more than one document
/// is open; click to switch, × to close, + to open another.
struct TabBarView: View {
    @EnvironmentObject var appModel: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(appModel.documents.enumerated()), id: \.element.id) { index, doc in
                    TabItem(title: doc.fileURL.lastPathComponent,
                            isActive: index == appModel.activeIndex,
                            onSelect: { appModel.activeIndex = index },
                            onClose: { appModel.closeTab(doc) })
                    Divider().frame(height: 18)
                }
                Button { appModel.presentOpenPanel() } label: {
                    Image(systemName: "plus").frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help("Open another file in a new tab")
                Spacer(minLength: 0)
            }
        }
        .frame(height: 30)
        .background(.bar)
    }
}

private struct TabItem: View {
    let title: String
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .lineLimit(1)
                .font(.callout)
                .foregroundStyle(isActive ? Color.primary : .secondary)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(hovering || isActive ? 1 : 0)
            }
            .buttonStyle(.borderless)
            .help("Close tab")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .frame(maxWidth: 220)
        .background(isActive ? Color(nsColor: .controlBackgroundColor) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }
}

/// Hosts the data grid (or a warning), the status bar, the format menu, and the
/// go-to-row / inspector sheets. Observes the document so its published state
/// (progress, file-changed, inspected row) drives the UI.
struct DocumentView: View {
    @ObservedObject var document: TableDocument
    @EnvironmentObject var appModel: AppModel
    @EnvironmentObject var purchase: PurchaseManager

    var body: some View {
        VStack(spacing: 0) {
            BrandToolbar(document: document)
            if document.fileChangedExternally {
                FileChangedBanner { appModel.reopenCurrent() }
            }
            if document.filterBarVisible {
                FilterBar(document: document)
            }
            if let unsupported = document.unsupportedEncoding {
                UnsupportedEncodingView(encoding: unsupported,
                                        fileName: document.fileURL.lastPathComponent)
            } else {
                CSVTableView(document: document)
                    .id(ObjectIdentifier(document))   // fresh table per file
            }
            StatusBarView(document: document)
        }
        .sheet(isPresented: $appModel.showGoToRow) {
            GoToRowSheet(document: document)
        }
        .sheet(isPresented: $appModel.showGoToColumn) {
            GoToColumnSheet(document: document)
        }
        .sheet(isPresented: Binding(get: { document.inspectedRow != nil },
                                    set: { if !$0 { document.inspectedRow = nil } })) {
            if let row = document.inspectedRow {
                RowInspectorView(document: document, displayRow: row)
            }
        }
        .alert("Sorting", isPresented: Binding(get: { document.transientMessage != nil },
                                               set: { if !$0 { document.transientMessage = nil } })) {
            Button("OK", role: .cancel) { document.transientMessage = nil }
        } message: {
            Text(document.transientMessage ?? "")
        }
        .sheet(isPresented: $document.exportSheetVisible) {
            ExportSheet(document: document)
        }
        .sheet(isPresented: $document.statsSheetVisible) {
            StatisticsSheet(document: document)
        }
        .alert("Export complete",
               isPresented: Binding(get: { document.lastExportURL != nil },
                                    set: { if !$0 { document.lastExportURL = nil } })) {
            Button("Show in Finder") {
                if let url = document.lastExportURL {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                document.lastExportURL = nil
            }
            Button("OK", role: .cancel) { document.lastExportURL = nil }
        } message: {
            Text("Exported to “\(document.lastExportURL?.lastPathComponent ?? "")”."
                 + (document.exportTruncated
                    ? "\n\nNote: the view exceeds Excel’s \(XLSXExporter.maxRows.formatted())-row "
                      + "limit, so it was truncated. Use CSV to export every row."
                    : ""))
        }
        .alert("Export failed",
               isPresented: Binding(get: { document.exportError != nil },
                                    set: { if !$0 { document.exportError = nil } })) {
            Button("OK", role: .cancel) { document.exportError = nil }
        } message: {
            Text(document.exportError ?? "")
        }
    }
}

/// Shown before any file is open: a calm, branded drop target.
struct EmptyStateView: View {
    let onOpen: () -> Void
    var recentFiles: [RecentFile] = []
    var onOpenRecent: (RecentFile) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "tablecells")
                .font(.system(size: 60, weight: .ultraLight))
                .foregroundStyle(Color(Brand.textMuted))
            VStack(spacing: 7) {
                Text("Open giant CSVs, instantly")
                    .font(Brand.sansFont(24, .semibold))
                    .foregroundStyle(Color(Brand.textPrimary))
                Text("Drag a .csv or .tsv file here, or choose one to open.")
                    .font(Brand.sansFont(13.5))
                    .foregroundStyle(Color(Brand.textSecondary))
            }
            Button(action: onOpen) {
                Text("Open File…")
                    .font(Brand.sansFont(13.5, .semibold))
                    .foregroundStyle(Color(Brand.onAccent))
                    .padding(.horizontal, 18).frame(height: 38)
                    .background(Color(Brand.accent), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("o", modifiers: .command)

            if !recentFiles.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("RECENT")
                        .font(Brand.monoFont(10.5, .semibold))
                        .foregroundStyle(Color(Brand.textMuted))
                        .tracking(1)
                    ForEach(recentFiles.prefix(5)) { file in
                        Button { onOpenRecent(file) } label: {
                            Label(file.name, systemImage: "doc.text")
                                .font(Brand.sansFont(13))
                                .foregroundStyle(Color(Brand.accentText))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(Brand.windowBg))
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

/// "Go to Column…" sheet: pick a column and scroll it into view.
struct GoToColumnSheet: View {
    @ObservedObject var document: TableDocument
    @Environment(\.dismiss) private var dismiss
    @State private var column = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Go to Column").font(.headline)
            Picker("Column", selection: $column) {
                ForEach(Array(document.columnTitles.enumerated()), id: \.offset) { i, title in
                    Text(title.isEmpty ? "Column \(i + 1)" : title).tag(i)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Go") {
                    document.requestScrollToColumn(column)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { column = min(max(0, document.statsColumn), max(0, document.columnCount - 1)) }
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
        HStack(spacing: 0) {
            leading
            Spacer(minLength: 12)
            trailing
        }
        .font(Brand.monoFont(11))
        .frame(height: 28)
        .padding(.horizontal, 12)
        .background(Color(Brand.barBg))
        .overlay(alignment: .top) { Color(Brand.hairline).frame(height: 1) }
    }

    @ViewBuilder private var leading: some View {
        if document.isExporting {
            progress("Exporting", document.exportProgress)
        } else if document.isSorting {
            progress("Sorting", document.sortProgress)
        } else if document.unsupportedEncoding != nil {
            Label("Unsupported encoding", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        } else if !document.progress.isComplete {
            progress("Indexing", document.progress.fractionComplete)
        } else {
            Text("\(document.fileURL.lastPathComponent)  ·  \(fileSizeText)")
                .foregroundStyle(Color(Brand.textSecondary))
                .lineLimit(1)
        }
    }

    private var trailing: some View {
        (Text("\(document.dialect.encoding.displayName)  ·  \(document.dialect.delimiter.displayName)  ·  ")
            .foregroundStyle(Color(Brand.textSecondary))
         + Text(countsText).foregroundStyle(Color(Brand.textMuted)))
            .lineLimit(1)
    }

    private func progress(_ label: String, _ value: Double) -> some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color(Brand.hairline)).frame(width: 90, height: 4)
                Capsule().fill(Color(Brand.accent)).frame(width: 90 * max(0, min(1, value)), height: 4)
            }
            Text("\(label)… \(Int(value * 100))%").foregroundStyle(Color(Brand.textSecondary))
        }
    }

    private var countsText: String {
        let cols = document.columnCount
        let colPart = cols > 0 ? "  ·  \(cols) cols" : ""
        if !document.filterSet.isEmpty && document.displayRowCount != document.totalRowCount {
            return "\(document.displayRowCount.formatted()) of \(document.totalRowCount.formatted()) rows" + colPart
        }
        return "\(document.displayRowCount.formatted()) rows" + colPart
    }

    private var fileSizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(document.fileSize), countStyle: .file)
    }
}

/// Export sheet (Pro): pick a format + header option, then a Save panel. Shows
/// live progress with Cancel while the streaming export runs, and auto-dismisses
/// on completion (the parent shows the success / failure alert).
struct ExportSheet: View {
    @ObservedObject var document: TableDocument
    @Environment(\.dismiss) private var dismiss
    @State private var format: SheetExportFormat = .csv
    @State private var includeHeader = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export").font(.headline)

            if document.isExporting {
                VStack(alignment: .leading, spacing: 10) {
                    ProgressView(value: document.exportProgress)
                    Text("Exporting… \(Int(document.exportProgress * 100))%")
                        .foregroundStyle(.secondary).monospacedDigit()
                    HStack {
                        Spacer()
                        Button("Cancel", role: .cancel) { document.cancelExport() }
                    }
                }
            } else {
                Text("\(document.exportableRowCount.formatted()) rows — the current view"
                     + (document.filterSet.isEmpty ? "" : " (filtered)") + ".")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Format", selection: $format) {
                    ForEach(SheetExportFormat.allCases) { f in Text(f.label).tag(f) }
                }
                .pickerStyle(.segmented)
                if format.supportsHeaderToggle {
                    Toggle("Include header row", isOn: $includeHeader)
                }
                if format == .xlsx && document.exportableRowCount > XLSXExporter.maxRows {
                    Label("Excel allows \(XLSXExporter.maxRows.formatted()) rows — the rest "
                          + "won’t be included. Use CSV for the full view.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Export…", action: chooseDestinationAndExport)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!document.canExport)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        // The document dismisses this sheet (via exportSheetVisible) when an export
        // finishes, then presents the result alert — so no onChange dismiss here.
    }

    private func chooseDestinationAndExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue =
            document.fileURL.deletingPathExtension().lastPathComponent + " (export)." + format.fileExtension
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Never export over the file we're viewing: it's mmap'd, so truncating it
        // would lose the original (on a filtered/sorted export) and risks a SIGBUS.
        if url.resolvingSymlinksInPath().standardizedFileURL
            == document.fileURL.resolvingSymlinksInPath().standardizedFileURL {
            let alert = NSAlert()
            alert.messageText = "Choose a different file"
            alert.informativeText = "You can’t export over the file you’re viewing. "
                + "Pick another name or folder."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        if let engineFormat = format.engineFormat {
            document.beginExport(to: url, format: engineFormat, includeHeader: includeHeader)
        } else {
            document.beginExportXLSX(to: url, includeHeader: includeHeader)
        }
    }
}

/// The export formats offered in the UI (CSV/TSV/JSON go through `ExportEngine`;
/// Excel goes through `XLSXExporter`).
enum SheetExportFormat: String, CaseIterable, Identifiable {
    case csv, tsv, json, xlsx
    var id: String { rawValue }

    var label: String {
        switch self {
        case .csv: return "CSV"
        case .tsv: return "TSV"
        case .json: return "JSON"
        case .xlsx: return "Excel"
        }
    }
    var fileExtension: String { rawValue }
    var supportsHeaderToggle: Bool { self != .json }
    var engineFormat: ExportEngine.Format? {
        switch self {
        case .csv: return .csv
        case .tsv: return .tsv
        case .json: return .json
        case .xlsx: return nil
        }
    }
    var utType: UTType {
        switch self {
        case .csv: return .commaSeparatedText
        case .tsv: return .tabSeparatedText
        case .json: return .json
        case .xlsx: return UTType(filenameExtension: "xlsx") ?? .data
        }
    }
}

/// Column statistics (Pro): pick a column, compute count / distinct and — for
/// numeric columns — sum / mean / min / max / median over the current filtered view.
struct StatisticsSheet: View {
    @ObservedObject var document: TableDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Column Statistics").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Picker("Column", selection: Binding(
                get: { document.statsColumn },
                set: { document.computeStats(column: $0) })) {
                ForEach(Array(document.columnTitles.enumerated()), id: \.offset) { i, title in
                    Text(title.isEmpty ? "Column \(i + 1)" : title).tag(i)
                }
            }
            if !document.filterSet.isEmpty {
                Text("Over the filtered view (\(document.exportableRowCount.formatted()) rows).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()

            if document.isComputingStats {
                HStack(spacing: 8) {
                    ProgressView(value: document.statsProgress).frame(width: 160)
                    Text("Calculating… \(Int(document.statsProgress * 100))%")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let s = document.currentStats {
                StatsList(stats: s)
            } else {
                Text("Choose a column to see its statistics.")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 380, height: 440)
        .onAppear {
            // Always recompute on open so the figures reflect the current filter.
            document.computeStats(column: min(max(0, document.statsColumn),
                                              max(0, document.columnCount - 1)))
        }
        .onDisappear { document.cancelStats() }
    }
}

private struct StatsList: View {
    let stats: ColumnStats

    var body: some View {
        VStack(spacing: 8) {
            StatRow("Rows", stats.total.formatted())
            StatRow("Filled", stats.filled.formatted())
            StatRow("Empty", stats.empty.formatted())
            StatRow("Distinct", stats.distinctCount.formatted() + (stats.distinctCapped ? "+" : ""))
            if stats.isNumeric {
                Divider().padding(.vertical, 2)
                StatRow("Numeric", stats.numericCount.formatted())
                StatRow("Sum", num(stats.sum))
                StatRow("Mean", num(stats.mean))
                StatRow("Min", num(stats.minValue))
                StatRow("Max", num(stats.maxValue))
                StatRow("Median", stats.medianOmitted ? "— (too many values)" : num(stats.median))
            }
        }
    }

    private func num(_ d: Double?) -> String {
        guard let d else { return "—" }
        return d.formatted(.number.precision(.fractionLength(0...6)))
    }
}

private struct StatRow: View {
    let key: String, value: String
    init(_ key: String, _ value: String) { self.key = key; self.value = value }
    var body: some View {
        HStack {
            Text(key).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }
}
