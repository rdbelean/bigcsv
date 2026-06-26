import Testing
@testable import BigCSVKit

@Suite("RowProjection")
struct RowProjectionTests {

    @Test func identityMapsPositionToItself() {
        let p = RowProjection.identity(totalRows: 5)
        #expect(p.count == 5)
        #expect((0..<5).map { p.originalRow(at: $0) } == [0, 1, 2, 3, 4])
    }

    @Test func sortOnlyAppliesOrder() {
        // Sorted so position 0 shows original row 3, etc.
        let p = RowProjection(order: [3, 1, 4, 0, 2], totalRows: 5)
        #expect(p.count == 5)
        #expect((0..<5).map { p.originalRow(at: $0) } == [3, 1, 4, 0, 2])
    }

    @Test func filterOnlyAppliesBase() {
        // Only original rows 1, 4, 7 matched (ascending subset).
        let p = RowProjection(base: [1, 4, 7], totalRows: 10)
        #expect(p.count == 3)
        #expect((0..<3).map { p.originalRow(at: $0) } == [1, 4, 7])
    }

    @Test func filterThenSortComposes() {
        // Subset of originals [1,4,7,9]; sorted into subset-index order [2,0,3,1]
        // → positions show originals [7,1,9,4].
        let p = RowProjection(base: [1, 4, 7, 9], order: [2, 0, 3, 1], totalRows: 10)
        #expect(p.count == 4)
        #expect((0..<4).map { p.originalRow(at: $0) } == [7, 1, 9, 4])
    }

    @Test func staleOrderFallsBackToIdentity() {
        // order shorter than count (index grew after sorting) — extra positions
        // map to themselves rather than trapping.
        let p = RowProjection(order: [1, 0], totalRows: 4)
        #expect(p.originalRow(at: 0) == 1)
        #expect(p.originalRow(at: 1) == 0)
        #expect(p.originalRow(at: 3) == 3)     // beyond order → identity
    }

    @Test func emptyFilterHasZeroCount() {
        let p = RowProjection(base: [], totalRows: 10)
        #expect(p.count == 0)
    }
}
