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
    /// True once the file changes on disk under us (guards against SIGBUS).
    @Published var fileChangedExternally = false
    /// Display row whose full contents should be shown in the inspector, if any.
    @Published var inspectedRow: Int?

    // Search
    @Published var searchQuery = ""
    @Published var searchCaseSensitive = false
    @Published var findBarVisible = false
    @Published private(set) var matchRows: [Int] = []     // display rows containing a match
    @Published var currentMatchIndex = 0
    @Published private(set) var isSearching = false

    /// A transient message to show the user (e.g. a sort limit), shown as an alert.
    @Published var transientMessage: String?

    // Sort
    @Published private(set) var sortColumn: Int?
    @Published private(set) var sortAscending = true
    @Published private(set) var isSorting = false
    @Published private(set) var sortProgress: Double = 0
    /// The most rows we'll sort (extraction is memory-bound); larger files show a message.
    let sortRowCap = 5_000_000

    /// Invoked (coalesced by the table view) whenever the indexed row count grows.
    var onIndexUpdate: (() -> Void)?
    /// Set by the table view; asks it to scroll a display row into view.
    var onScrollToRow: ((Int) -> Void)?
    /// Set by the table view; asks it to repaint visible rows (search highlights).
    var onSearchChanged: (() -> Void)?
    /// Set by the table view; asks it to rebuild the header (sort indicator) + repaint.
    var onSortChanged: (() -> Void)?

    private(set) var index: RecordIndex
    private let securityScoped: Bool
    private var indexTask: Task<Void, Never>?
    private var columnsComputed = false
    private var fileWatchSource: DispatchSourceFileSystemObject?
    private var watchFD: Int32 = -1
    private var searchTask: Task<Void, Never>?
    private var didJumpToFirstMatch = false
    private var sortTask: Task<Void, Never>?
    /// Maps visible positions to original rows (filter subset + sort order).
    private var projection = RowProjection.identity(totalRows: 0)

    // Small LRU of parsed rows so all columns of a visible row parse once.
    private var rowCache: [Int: [String]] = [:]
    private var rowCacheOrder: [Int] = []
    private let rowCacheLimit = 2000

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
        startWatchingFile()
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
        projection.totalRows = dialect.hasHeader ? max(0, index.count - 1) : index.count
        displayRowCount = projection.count
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

    /// Map a display position to its underlying display row (identity unless a
    /// sort permutation is active).
    private func mappedRow(_ displayRow: Int) -> Int {
        projection.originalRow(at: displayRow)
    }

    /// The 1-based file row number shown in the gutter (follows the sort).
    func fileRowNumber(displayRow: Int) -> Int { mappedRow(displayRow) + 1 }

    /// Value for one cell, parsed on demand. Out-of-range columns (ragged rows)
    /// return an empty string — never a crash.
    func cell(displayRow: Int, column: Int) -> String {
        let fields = parsedRow(logicalRow(forDisplayRow: mappedRow(displayRow)))
        return column < fields.count ? fields[column] : ""
    }

    /// Full field list for a displayed row (used by the cell inspector).
    func rowFields(displayRow: Int) -> [String] {
        parsedRow(logicalRow(forDisplayRow: mappedRow(displayRow)))
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
        resetSort()
        clearRowCache()
        recomputeColumns()
        onIndexUpdate?()
    }

    /// Toggle whether the first record is a header — no re-index, just remap.
    func setHasHeader(_ hasHeader: Bool) {
        guard hasHeader != dialect.hasHeader else { return }
        dialect.hasHeader = hasHeader
        resetSort()
        projection.totalRows = dialect.hasHeader ? max(0, index.count - 1) : index.count
        displayRowCount = projection.count
        recomputeColumns()
        onIndexUpdate?()
    }

    /// Drop any active sort (its mapping is invalidated by a re-index / dialect change).
    private func resetSort() {
        sortTask?.cancel()
        sortTask = nil
        projection.order = nil
        sortColumn = nil
        isSorting = false
    }

    private func recomputeColumns() {
        columnsComputed = false
        clearRowCache()
        computeColumns()
    }

    private func reindex() {
        indexTask?.cancel()
        resetSort()
        projection = .identity(totalRows: 0)
        index = RecordIndex()
        columnsComputed = false
        setColumnTitles([])
        displayRowCount = 0
        progress = .empty
        clearRowCache()
        startIndexing()
        onIndexUpdate?()
    }

    // MARK: Navigation & inspection

    /// Scroll a 0-based display row into view (clamped to the available range).
    func requestScrollToRow(_ displayRow: Int) {
        guard displayRowCount > 0 else { return }
        onScrollToRow?(min(max(0, displayRow), displayRowCount - 1))
    }

    /// Show the full contents of a display row in the inspector.
    func requestInspector(displayRow: Int) {
        guard displayRow >= 0, displayRow < displayRowCount else { return }
        inspectedRow = displayRow
    }

    // MARK: Search

    /// (Re)run the search for the current `searchQuery`. Streams matching display
    /// rows in as they're found, off-main, cancellable.
    func performSearch() {
        searchTask?.cancel()
        matchRows = []
        currentMatchIndex = 0
        didJumpToFirstMatch = false
        onSearchChanged?()

        let query = searchQuery
        guard !query.isEmpty else { isSearching = false; return }
        isSearching = true

        let mapper = self.mapper
        let index = self.index
        let dialect = self.dialect
        let caseSensitive = self.searchCaseSensitive
        let hasHeader = dialect.hasHeader
        let buffer = MatchBuffer()

        searchTask = Task {
            await SearchEngine().search(
                mapper: mapper, index: index, dialect: dialect,
                query: query, caseSensitive: caseSensitive,
                onMatch: { record in
                    let displayRow = hasHeader ? record - 1 : record
                    if displayRow >= 0 { buffer.append(displayRow) }
                },
                onProgress: { _, _, isComplete in
                    Task { @MainActor [weak self] in self?.flushSearch(buffer, isComplete: isComplete) }
                })
        }
    }

    private func flushSearch(_ buffer: MatchBuffer, isComplete: Bool) {
        let new = buffer.drainNew()
        if !new.isEmpty { matchRows.append(contentsOf: new) }
        if isComplete { isSearching = false }
        if !didJumpToFirstMatch, let first = matchRows.first {
            didJumpToFirstMatch = true
            currentMatchIndex = 0
            requestScrollToRow(first)   // also repaints (highlights) the visible window
        }
        // No table reload here: highlighting is query-based and already applied as
        // cells render; streaming matches only update the count + navigation.
    }

    func nextMatch() {
        guard !matchRows.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % matchRows.count
        requestScrollToRow(matchRows[currentMatchIndex])
        onSearchChanged?()
    }

    func previousMatch() {
        guard !matchRows.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + matchRows.count) % matchRows.count
        requestScrollToRow(matchRows[currentMatchIndex])
        onSearchChanged?()
    }

    func clearSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchQuery = ""
        matchRows = []
        currentMatchIndex = 0
        isSearching = false
        didJumpToFirstMatch = false
        onSearchChanged?()
    }

    // MARK: Sort

    /// Sort by a column (click a header). Same column again flips the order.
    func toggleSort(column: Int) {
        guard column >= 0, column < columnCount else { return }
        if displayRowCount > sortRowCap {
            transientMessage = "Sorting is available for files up to \(sortRowCap.formatted()) rows. "
                + "This file has \(displayRowCount.formatted()) rows."
            return
        }
        let order: SortEngine.Order
        if sortColumn == column {
            order = sortAscending ? .descending : .ascending
        } else {
            order = .ascending
        }
        sortColumn = column
        sortAscending = (order == .ascending)
        clearSearch()
        onSortChanged?()                // show the indicator immediately
        runSort(column: column, order: order)
    }

    func clearSort() {
        sortTask?.cancel()
        sortTask = nil
        projection.order = nil
        sortColumn = nil
        isSorting = false
        clearRowCache()
        onSortChanged?()
    }

    private func runSort(column: Int, order: SortEngine.Order) {
        sortTask?.cancel()
        isSorting = true
        sortProgress = 0
        let mapper = self.mapper
        let index = self.index
        let dialect = self.dialect
        let recordOffset = dialect.hasHeader ? 1 : 0
        let rowCount = displayRowCount

        sortTask = Task {
            let perm = await SortEngine().sortedPermutation(
                mapper: mapper, index: index, dialect: dialect,
                column: column, order: order, recordOffset: recordOffset, rowCount: rowCount,
                onProgress: { fraction in
                    Task { @MainActor [weak self] in self?.sortProgress = fraction }
                })
            await MainActor.run { [weak self] in self?.applySort(perm) }
        }
    }

    private func applySort(_ perm: [UInt32]?) {
        isSorting = false
        guard let perm else { return }     // cancelled
        projection.order = perm
        clearRowCache()
        onSortChanged?()
    }

    // MARK: File-change watch (guards against SIGBUS on truncation/replacement)

    private func startWatchingFile() {
        watchFD = open(fileURL.path, O_EVTONLY)
        guard watchFD >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchFD,
            eventMask: [.write, .extend, .delete, .rename, .link],
            queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.fileChangedExternally = true }
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.watchFD, fd >= 0 { Darwin.close(fd) }
        }
        source.resume()
        fileWatchSource = source
    }

    private func stopWatchingFile() {
        fileWatchSource?.cancel()
        fileWatchSource = nil
        watchFD = -1
    }

    // MARK: Lifecycle

    func close() {
        indexTask?.cancel()
        indexTask = nil
        searchTask?.cancel()
        searchTask = nil
        sortTask?.cancel()
        sortTask = nil
        stopWatchingFile()
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

/// Thread-safe accumulator the off-main search appends to; the main actor drains
/// the new entries periodically.
private nonisolated final class MatchBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Int] = []
    private var drained = 0

    func append(_ row: Int) {
        lock.lock(); items.append(row); lock.unlock()
    }

    func drainNew() -> [Int] {
        lock.lock(); defer { lock.unlock() }
        guard drained < items.count else { return [] }
        let new = Array(items[drained...])
        drained = items.count
        return new
    }
}
