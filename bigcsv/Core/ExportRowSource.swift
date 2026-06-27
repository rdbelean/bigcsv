import Foundation

/// Shared row enumeration for the exporters. Walks the current view — filtered
/// and/or sorted, or the whole file — parsing each row on demand from the mapped
/// bytes, in DISPLAY order, exactly mirroring `RowProjection` (identity fallback
/// for any short/raced permutation + bounds checks so an out-of-range index yields
/// an empty row, never a trap). Off-main, cancellable.
///
/// Both the text (`ExportEngine`) and `XLSXExporter` exporters drive their output
/// from this, so the carefully hardened row mapping lives in exactly one place.
public nonisolated struct ExportRowSource: Sendable {
    public let mapper: FileMapper
    public let dialect: CSVDialect
    /// Filtered rows' byte starts in display order, or nil when unfiltered.
    public let subsetOffsets: [Int]?
    /// Sort permutation over the current row set (subset or full), or nil.
    public let order: [UInt32]?
    /// File record index of display row 0 (1 with a header, else 0).
    public let recordOffset: Int
    /// Underlying display rows (used for the sequential scan + progress totals).
    public let rowCount: Int

    public init(mapper: FileMapper, dialect: CSVDialect,
                subsetOffsets: [Int]?, order: [UInt32]?,
                recordOffset: Int, rowCount: Int) {
        self.mapper = mapper
        self.dialect = dialect
        self.subsetOffsets = subsetOffsets
        self.order = order
        self.recordOffset = recordOffset
        self.rowCount = rowCount
    }

    /// Number of rows the enumeration will yield (the displayed / filtered count).
    public var displayCount: Int {
        if let subset = subsetOffsets { return subset.count }      // filtered (± sort)
        return max(0, rowCount)                                     // full file (± sort)
    }

    /// Parse and yield each displayed row's fields, in order. The body may throw to
    /// stop early (e.g. a row cap); cancellation throws `CancellationError`.
    func forEach(_ body: (_ position: Int, _ fields: [String]) throws -> Void) async throws {
        let bytes = mapper.bytes
        let n = bytes.count
        let delimiter = dialect.delimiter.byte
        let quote = dialect.quote

        func parse(at off: Int) -> [String] {
            guard off >= 0, off < n else { return [] }
            let next = RecordScanner.nextRecordStart(bytes, from: off, delimiter: delimiter, quote: quote)
            return CSVParser.parseRecord(
                UnsafeRawBufferPointer(rebasing: bytes[off..<min(next, n)]), dialect: dialect)
        }

        if let offsets = try orderedOffsets(bytes: bytes, n: n, delimiter: delimiter, quote: quote) {
            var p = 0
            for off in offsets {
                if Task.isCancelled { throw CancellationError() }
                try body(p, parse(at: off))
                p += 1
                // Real suspension point: without it this non-suspending async loop runs
                // synchronously on the caller's actor (the MainActor) and freezes the UI.
                if p & 0x3FFF == 0 { await Task.yield() }
            }
        } else {
            var pos = RecordScanner.utf8BOMLength(bytes)
            var skipped = 0
            while skipped < recordOffset && pos < n {
                pos = RecordScanner.nextRecordStart(bytes, from: pos, delimiter: delimiter, quote: quote)
                skipped += 1
            }
            var p = 0
            while pos < n && p < rowCount {
                if Task.isCancelled { throw CancellationError() }
                let next = RecordScanner.nextRecordStart(bytes, from: pos, delimiter: delimiter, quote: quote)
                try body(p, CSVParser.parseRecord(
                    UnsafeRawBufferPointer(rebasing: bytes[pos..<min(next, n)]), dialect: dialect))
                pos = next
                p += 1
                if p & 0x3FFF == 0 { await Task.yield() }   // hop off the MainActor (see above)
            }
        }
    }

    /// The ordered byte-offset list in display order, or nil for the pure sequential
    /// (unfiltered + unsorted) case.
    func orderedOffsets(bytes: UnsafeRawBufferPointer, n: Int,
                        delimiter: UInt8, quote: UInt8) throws -> [Int]? {
        switch (subsetOffsets, order) {
        case (nil, nil):
            return nil                                            // sequential

        case let (subset?, order?):                               // filter + sort
            return (0..<subset.count).map { p in
                let i = p < order.count ? Int(order[p]) : p
                return i >= 0 && i < subset.count ? subset[i] : -1
            }

        case let (subset?, nil):                                  // filter only
            return subset

        case let (nil, order?):                                   // sort only — collect all offsets first
            var all = [Int](); all.reserveCapacity(rowCount)
            var pos = RecordScanner.utf8BOMLength(bytes)
            var skipped = 0
            while skipped < recordOffset && pos < n {
                pos = RecordScanner.nextRecordStart(bytes, from: pos, delimiter: delimiter, quote: quote)
                skipped += 1
            }
            var d = 0
            while pos < n && d < rowCount {
                if Task.isCancelled { throw CancellationError() }
                all.append(pos)
                pos = RecordScanner.nextRecordStart(bytes, from: pos, delimiter: delimiter, quote: quote)
                d += 1
            }
            return (0..<all.count).map { p in
                let i = p < order.count ? Int(order[p]) : p
                return i >= 0 && i < all.count ? all[i] : -1
            }
        }
    }
}
