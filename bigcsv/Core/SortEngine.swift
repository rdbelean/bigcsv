import Foundation

/// Builds a sort permutation over the file's rows by one column.
///
/// Pre-extracts the sort column's value for every row once (O(rows) parses),
/// detects whether the column is numeric, then sorts an index permutation by the
/// extracted keys (numeric or Finder-style localized text). The extraction phase
/// is cancellable and reports progress. The table then reads rows through the
/// returned permutation.
public nonisolated struct SortEngine: Sendable {

    public enum Order: Sendable, Equatable { case ascending, descending }

    public init() {}

    /// Returns a permutation `p` of `0..<rowCount` (display rows) sorted by
    /// `column`, or nil if cancelled. `recordOffset` is the file record index of
    /// display row 0 (1 when there's a header, else 0).
    public func sortedPermutation(mapper: FileMapper,
                                  index: RecordIndex,
                                  dialect: CSVDialect,
                                  column: Int,
                                  order: Order,
                                  recordOffset: Int,
                                  rowCount: Int,
                                  onProgress: @Sendable (Double) -> Void) async -> [UInt32]? {
        guard rowCount > 0 else { return [] }
        _ = index   // (boundaries are re-derived by a single sequential scan below)

        // 1) Extract the column key for every row in ONE sequential pass over the
        // mapped bytes — NOT index.byteRange(forRow:) per row, which re-scans from
        // the nearest checkpoint each call and is quadratic over a full scan.
        let bytes = mapper.bytes
        let n = bytes.count
        let delimiter = dialect.delimiter.byte
        let quote = dialect.quote
        var pos = RecordScanner.utf8BOMLength(bytes)
        var skipped = 0
        while skipped < recordOffset && pos < n {
            pos = RecordScanner.nextRecordStart(bytes, from: pos, delimiter: delimiter, quote: quote)
            skipped += 1
        }

        var keys = [String]()
        keys.reserveCapacity(rowCount)
        var d = 0
        while pos < n && d < rowCount {
            if Task.isCancelled { return nil }
            let next = RecordScanner.nextRecordStart(bytes, from: pos, delimiter: delimiter, quote: quote)
            let fields = CSVParser.parseRecord(
                UnsafeRawBufferPointer(rebasing: bytes[pos..<min(next, n)]), dialect: dialect)
            keys.append(column < fields.count ? fields[column] : "")
            pos = next
            d += 1
            if d & 0xFFFF == 0 {
                onProgress(Double(d) / Double(rowCount))
                await Task.yield()
            }
        }
        while keys.count < rowCount { keys.append("") }    // tolerate a short tail
        if Task.isCancelled { return nil }

        let perm = Self.permutation(keys: keys, order: order)
        onProgress(1)
        return perm
    }

    /// Returns a permutation of `0..<offsets.count` sorted by `column`, reading
    /// each row directly from its byte start `offset`. Used to sort the **filtered
    /// subset**: `offsets` are the byte starts of the matching rows (subset-index
    /// space), so the returned permutation maps visible positions to subset indices
    /// — exactly what `RowProjection.order` expects when a filter is active.
    public func sortedPermutation(mapper: FileMapper,
                                  dialect: CSVDialect,
                                  column: Int,
                                  order: Order,
                                  offsets: [Int],
                                  onProgress: @Sendable (Double) -> Void) async -> [UInt32]? {
        guard !offsets.isEmpty else { return [] }
        let bytes = mapper.bytes
        let n = bytes.count
        let delimiter = dialect.delimiter.byte
        let quote = dialect.quote

        var keys = [String]()
        keys.reserveCapacity(offsets.count)
        for (i, off) in offsets.enumerated() {
            if Task.isCancelled { return nil }
            guard off >= 0, off < n else { keys.append(""); continue }
            let next = RecordScanner.nextRecordStart(bytes, from: off, delimiter: delimiter, quote: quote)
            let fields = CSVParser.parseRecord(
                UnsafeRawBufferPointer(rebasing: bytes[off..<min(next, n)]), dialect: dialect)
            keys.append(column < fields.count ? fields[column] : "")
            if i & 0xFFFF == 0 {
                onProgress(Double(i) / Double(offsets.count))
                await Task.yield()
            }
        }
        if Task.isCancelled { return nil }

        let perm = Self.permutation(keys: keys, order: order)
        onProgress(1)
        return perm
    }

    /// Sort an index permutation by extracted keys — numeric (locale-aware) when
    /// the column looks numeric, else Finder-style localized text. Stable.
    static func permutation(keys: [String], order: Order) -> [UInt32] {
        let numeric = isNumericColumn(keys)
        var perm = Array(0..<keys.count).map { UInt32($0) }
        let ascending = order == .ascending
        if numeric {
            let values = keys.map { numericValue($0) }
            perm.sort { a, b in
                let x = values[Int(a)], y = values[Int(b)]
                if x == y { return a < b }                  // stable
                return ascending ? x < y : x > y
            }
        } else {
            perm.sort { a, b in
                let r = keys[Int(a)].localizedStandardCompare(keys[Int(b)])
                if r == .orderedSame { return a < b }       // stable
                return ascending ? (r == .orderedAscending) : (r == .orderedDescending)
            }
        }
        return perm
    }

    /// A value with empties/non-numbers sorted to the end (+∞). Locale-aware.
    static func numericValue(_ s: String) -> Double {
        NumberParsing.parse(s) ?? .infinity
    }

    static func isNumericColumn(_ keys: [String]) -> Bool {
        NumberParsing.isNumericColumn(keys)
    }
}
