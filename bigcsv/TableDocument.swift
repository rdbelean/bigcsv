import Foundation
import Combine

/// The view-model for one open file: owns the memory map and the streaming line
/// index, auto-detects the dialect, drives the background indexing task, and
/// parses rows on demand (only the rows the table asks for) with a small cache
/// for the visible window.
///
/// All UI-facing state is `@MainActor`; the heavy indexing runs off-main inside
/// `LineIndexer` (a `nonisolated` core type) and publishes back here in batches.
@MainActor
final class TableDocument: ObservableObject {

    let fileURL: URL
    let fileSize: Int
    let mapper: FileMapper

    @Published private(set) var dialect: CSVDialect
    @Published private(set) var progress: IndexProgress = .empty
    @Published private(set) var columnTitles: [String] = []
    @Published private(set) var displayRowCount: Int = 0
    /// Bumped whenever the column model changes (count or titles) so the table
    /// knows to rebuild its NSTableColumns even if the count is unchanged.
    @Published private(set) var columnsVersion: Int = 0
    /// Set when the file is in an encoding we can't byte-index (UTF-16/32).
    @Published private(set) var unsupportedEncoding: UnsupportedEncoding?

    /// Invoked (coalesced by the table view) whenever the indexed row count grows.
    var onIndexUpdate: (() -> Void)?

    private(set) var index: RecordIndex
    private let securityScoped: Bool
    private var indexTask: Task<Void, Never>?
    private var columnsComputed = false

    // Small LRU of parsed rows so all columns of a visible row parse once.
    private var rowCache: [Int: [String]] = [:]
    private var rowCacheOrder: [Int] = []
    private let rowCacheLimit = 600

    init(url: URL, securityScoped: Bool) throws {
        self.fileURL = url
        self.securityScoped = securityScoped
        self.mapper = try FileMapper(url: url)
        self.fileSize = mapper.count
        self.index = RecordIndex()

        // Auto-detect encoding + delimiter from the first chunk.
        let sampleLength = min(mapper.count, Detector.sampleByteLimit)
        let detection = Detector.detect(mapper.bytes(in: 0..<sampleLength))
        self.dialect = detection.dialect
        self.unsupportedEncoding = detection.unsupported

        if detection.unsupported == nil {
            startIndexing()
        }
    }

    // MARK: Indexing

    private func startIndexing() {
        let mapper = self.mapper
        let index = self.index
        let dialect = self.dialect
        indexTask = Task {
            await LineIndexer(progressRowInterval: 16_384)
                .index(mapper, dialect: dialect, into: index) { [weak self] progress in
                    guard let self else { return }
                    Task { @MainActor in
                        self.applyProgress(progress)
                    }
                }
        }
    }

    private func applyProgress(_ p: IndexProgress) {
        progress = p
        if !columnsComputed && index.count > 0 { computeColumns() }
        displayRowCount = dialect.hasHeader ? max(0, index.count - 1) : index.count
        onIndexUpdate?()
    }

    /// Derive the column model from the first rows. Stable once computed so the
    /// layout doesn't shift as more rows stream in.
    private func computeColumns() {
        let sample = min(index.count, 100)
        guard sample > 0 else { return }
        var maxCols = 0
        var firstRow: [String] = []
        for r in 0..<sample {
            let fields = parsedRow(r)
            if r == 0 { firstRow = fields }
            maxCols = max(maxCols, fields.count)
        }
        guard maxCols > 0 else { return }
        columnsComputed = true
        setColumnTitles(makeTitles(maxColumns: maxCols, firstRow: firstRow))
    }

    private func makeTitles(maxColumns: Int, firstRow: [String]) -> [String] {
        if dialect.hasHeader {
            return (0..<maxColumns).map { i in
                (i < firstRow.count && !firstRow[i].isEmpty) ? firstRow[i] : "Column \(i + 1)"
            }
        }
        return (0..<maxColumns).map { "Column \($0 + 1)" }
    }

    private func setColumnTitles(_ titles: [String]) {
        columnTitles = titles
        columnsVersion += 1
    }

    var columnCount: Int { columnTitles.count }

    // MARK: Cells

    private func logicalRow(forDisplayRow displayRow: Int) -> Int {
        dialect.hasHeader ? displayRow + 1 : displayRow
    }

    /// Value for one cell, parsed on demand. Out-of-range columns (ragged rows)
    /// return an empty string — never a crash.
    func cell(displayRow: Int, column: Int) -> String {
        let fields = parsedRow(logicalRow(forDisplayRow: displayRow))
        return column < fields.count ? fields[column] : ""
    }

    /// Full field list for a displayed row (used by the cell inspector later).
    func rowFields(displayRow: Int) -> [String] {
        parsedRow(logicalRow(forDisplayRow: displayRow))
    }

    private func parsedRow(_ row: Int) -> [String] {
        if let cached = rowCache[row] { return cached }
        guard let range = index.byteRange(forRow: row, mapper: mapper, dialect: dialect) else {
            return []
        }
        let fields = CSVParser.parseRecord(mapper.bytes(in: range), dialect: dialect)
        rowCache[row] = fields
        rowCacheOrder.append(row)
        if rowCacheOrder.count > rowCacheLimit {
            let evicted = rowCacheOrder.removeFirst()
            rowCache.removeValue(forKey: evicted)
        }
        return fields
    }

    private func clearRowCache() {
        rowCache.removeAll(keepingCapacity: true)
        rowCacheOrder.removeAll(keepingCapacity: true)
    }

    // MARK: Manual dialect overrides

    /// Change the delimiter — requires a full re-index (record boundaries depend
    /// on it via quote/field-start tracking).
    func setDelimiter(_ delimiter: Delimiter) {
        guard delimiter != dialect.delimiter else { return }
        dialect.delimiter = delimiter
        reindex()
    }

    /// Change the text encoding — no re-index needed (UTF-8 and Windows-1252 are
    /// byte-compatible for the structural bytes); just re-decode visible cells.
    func setEncoding(_ encoding: TextEncoding) {
        guard encoding != dialect.encoding else { return }
        dialect.encoding = encoding
        clearRowCache()
        recomputeColumns()
        onIndexUpdate?()
    }

    /// Toggle whether the first record is a header — no re-index, just remap.
    func setHasHeader(_ hasHeader: Bool) {
        guard hasHeader != dialect.hasHeader else { return }
        dialect.hasHeader = hasHeader
        displayRowCount = dialect.hasHeader ? max(0, index.count - 1) : index.count
        recomputeColumns()
        onIndexUpdate?()
    }

    private func recomputeColumns() {
        columnsComputed = false
        clearRowCache()
        computeColumns()
    }

    private func reindex() {
        indexTask?.cancel()
        index = RecordIndex()
        columnsComputed = false
        setColumnTitles([])
        displayRowCount = 0
        progress = .empty
        clearRowCache()
        startIndexing()
        onIndexUpdate?()
    }

    // MARK: Lifecycle

    func close() {
        indexTask?.cancel()
        indexTask = nil
        if securityScoped {
            fileURL.stopAccessingSecurityScopedResource()
        }
    }

    deinit {
        if securityScoped {
            fileURL.stopAccessingSecurityScopedResource()
        }
    }
}
