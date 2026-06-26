import Foundation

/// How visible table positions map to original display rows — the single model
/// that lets **filter**, **sort**, and **search** compose.
///
/// Compose order: `position → (sort) → subset-index → (filter) → original row`.
/// - `order` is a sort permutation over the *current* row set's index space
///   (`0..<base.count`, or `0..<totalRows` when there's no filter). `nil` = natural.
/// - `base` is the filtered subset of ORIGINAL display rows, ascending. `nil` =
///   all rows (identity — we store `nil`, never a materialized identity array,
///   even when a filter matches everything, to cap the 4-bytes/row memory cost).
///
/// `nil`/`nil` is the identity projection — byte-for-byte the un-sorted, un-filtered
/// view. Sort-only sets `order`; filter-only sets `base`; filter+sort sets `base`
/// then an `order` computed over the subset.
public nonisolated struct RowProjection: Sendable, Equatable {
    public var base: [UInt32]?
    public var order: [UInt32]?
    public var totalRows: Int

    public init(base: [UInt32]? = nil, order: [UInt32]? = nil, totalRows: Int) {
        self.base = base
        self.order = order
        self.totalRows = totalRows
    }

    public static func identity(totalRows: Int) -> RowProjection {
        RowProjection(totalRows: totalRows)
    }

    /// Number of visible rows (filtered count, or all rows when unfiltered).
    public var count: Int { base?.count ?? max(0, totalRows) }

    /// The original (unfiltered, unsorted) display row shown at visible `position`.
    /// Defensive against a stale `order`/`base` (e.g. the index grew after a sort)
    /// — out-of-range falls back to identity rather than trapping.
    public func originalRow(at position: Int) -> Int {
        let index: Int
        if let order, position >= 0, position < order.count {
            index = Int(order[position])
        } else {
            index = position
        }
        if let base, index >= 0, index < base.count {
            return Int(base[index])
        }
        return index
    }
}
