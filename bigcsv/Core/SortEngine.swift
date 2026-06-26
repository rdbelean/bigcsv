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

        // 1) Extract the column key for every row.
        var keys = [String]()
        keys.reserveCapacity(rowCount)
        for d in 0..<rowCount {
            if Task.isCancelled { return nil }
            let record = recordOffset + d
            if let range = index.byteRange(forRow: record, mapper: mapper, dialect: dialect) {
                let fields = CSVParser.parseRecord(mapper.bytes(in: range), dialect: dialect)
                keys.append(column < fields.count ? fields[column] : "")
            } else {
                keys.append("")
            }
            if d & 0xFFFF == 0 {
                onProgress(Double(d) / Double(rowCount))
                await Task.yield()
            }
        }
        if Task.isCancelled { return nil }

        // 2) Numeric column? (most non-empty values parse as a number)
        let numeric = Self.isNumericColumn(keys)

        // 3) Sort an index permutation by the keys.
        var perm = Array(0..<rowCount).map { UInt32($0) }
        let ascending = order == .ascending
        if numeric {
            let values = keys.map { Self.numericValue($0) }
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
        onProgress(1)
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
