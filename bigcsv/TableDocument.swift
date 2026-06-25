import Foundation
import Combine

/// The view-model for one open file: owns the memory map and the streaming line
/// index, drives the background indexing task, and parses rows on demand (only
/// the rows the table asks for) with a small cache for the visible window.
///
/// All UI-facing state is `@MainActor`; the heavy indexing runs off-main inside
/// `LineIndexer` (a `nonisolated` core type) and publishes back here in batches.
@MainActor
final class TableDocument: ObservableObject {

    let fileURL: URL
    let fileSize: Int
    let mapper: FileMapper
    let index: RecordIndex

    @Published private(set) var dialect: CSVDialect
    @Published private(set) var progress: IndexProgress = .empty
    @Published private(set) var columnTitles: [String] = []
    @Published private(set) var displayRowCount: Int = 0

    /// Invoked (coalesced by the table view) whenever the indexed row count grows.
    var onIndexUpdate: (() -> Void)?

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
        self.dialect = .default
        startIndexing()
    }

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
        if dialect.hasHeader {
            columnTitles = (0..<maxCols).map { i in
                (i < firstRow.count && !firstRow[i].isEmpty) ? firstRow[i] : "Column \(i + 1)"
            }
        } else {
            columnTitles = (0..<maxCols).map { "Column \($0 + 1)" }
        }
    }

    var columnCount: Int { columnTitles.count }

    /// The logical record index for a displayed row (skips the header if present).
    private func logicalRow(forDisplayRow displayRow: Int) -> Int {
        dialect.hasHeader ? displayRow + 1 : displayRow
    }

    /// Value for one cell, parsed on demand. Out-of-range columns (ragged rows)
    /// return an empty string — never a crash.
    func cell(displayRow: Int, column: Int) -> String {
        let fields = parsedRow(logicalRow(forDisplayRow: displayRow))
        return column < fields.count ? fields[column] : ""
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

    /// Cancel indexing and release the security scope. Called when this document
    /// is replaced by another.
    func close() {
        indexTask?.cancel()
        indexTask = nil
        if securityScoped {
            fileURL.stopAccessingSecurityScopedResource()
        }
    }

    deinit {
        // `close()` is the normal teardown path; this is a safety net for the
        // security scope only (fileURL is immutable and safe to touch here).
        if securityScoped {
            fileURL.stopAccessingSecurityScopedResource()
        }
    }
}
