import Foundation

/// Summary statistics for one column over the current view.
public nonisolated struct ColumnStats: Sendable, Equatable {
    public var column: Int
    public var total: Int = 0            // rows scanned (the displayed/filtered count)
    public var empty: Int = 0            // blank (whitespace-only) cells
    public var numericCount: Int = 0     // cells that parse as a number
    public var distinctCount: Int = 0    // distinct non-empty values (capped)
    public var distinctCapped: Bool = false
    public var sum: Double = 0
    public var mean: Double?
    public var minValue: Double?
    public var maxValue: Double?
    public var median: Double?
    public var medianOmitted: Bool = false   // too many numeric values to hold for a median

    public var filled: Int { total - empty }
    public var isNumeric: Bool { numericCount > 0 }

    public init(column: Int) { self.column = column }
}

/// Computes `ColumnStats` for one column in a single streaming pass over the mapped
/// bytes (off-main, cancellable). Reuses `ExportRowSource` so it sees exactly the
/// current view — filtered rows only when a filter is active. Numeric parsing is the
/// same locale-aware logic used by sort/filter.
public nonisolated struct StatsEngine: Sendable {

    /// Above this many numeric values we skip the median (it needs them all in memory).
    public static let medianCap = 5_000_000
    /// Distinct values are tracked up to this many, then reported as "N+".
    public static let distinctCap = 200_000

    public init() {}

    public func compute(source: ExportRowSource, column: Int,
                        onProgress: @Sendable (Double) -> Void) async throws -> ColumnStats {
        var total = 0, empty = 0, numericCount = 0
        var sum = 0.0
        var minV = Double.infinity, maxV = -Double.infinity
        var values = [Double]()
        var medianOmitted = false
        var distinct = Set<String>()
        var distinctCapped = false
        let displayTotal = source.displayCount

        try await source.forEach { _, fields in
            total += 1
            let raw = column < fields.count ? fields[column] : ""
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty {
                empty += 1
            } else {
                if !distinctCapped {
                    distinct.insert(t)
                    if distinct.count >= Self.distinctCap { distinctCapped = true }
                }
                if let d = NumberParsing.parse(t) {
                    numericCount += 1
                    sum += d
                    if d < minV { minV = d }
                    if d > maxV { maxV = d }
                    if values.count < Self.medianCap { values.append(d) } else { medianOmitted = true }
                }
            }
            if total & 0x3FFF == 0 { onProgress(Double(total) / Double(max(1, displayTotal))) }
        }
        onProgress(1)

        var stats = ColumnStats(column: column)
        stats.total = total
        stats.empty = empty
        stats.numericCount = numericCount
        stats.distinctCount = distinct.count
        stats.distinctCapped = distinctCapped
        if numericCount > 0 {
            stats.sum = sum
            stats.mean = sum / Double(numericCount)
            stats.minValue = minV
            stats.maxValue = maxV
            stats.medianOmitted = medianOmitted
            if !medianOmitted && !values.isEmpty {
                values.sort()
                let n = values.count
                stats.median = n % 2 == 1 ? values[n / 2]
                                          : (values[n / 2 - 1] + values[n / 2]) / 2
            }
        }
        return stats
    }
}
