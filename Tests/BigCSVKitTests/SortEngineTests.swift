import Testing
import Foundation
@testable import BigCSVKit

@Suite("SortEngine")
struct SortEngineTests {

    private let sample = "name,age\nBob,30\nAlice,20\nCarol,25\n"   // header + 3 rows

    @Test func numericAscending() async throws {
        let (m, idx) = try await TestSupport.buildIndex(sample, stride: 2)
        let perm = await SortEngine().sortedPermutation(
            mapper: m, index: idx, dialect: .default, column: 1, order: .ascending,
            recordOffset: 1, rowCount: 3, onProgress: { _ in })
        #expect(perm == [1, 2, 0])      // 20 (Alice), 25 (Carol), 30 (Bob)
    }

    @Test func numericDescending() async throws {
        let (m, idx) = try await TestSupport.buildIndex(sample, stride: 2)
        let perm = await SortEngine().sortedPermutation(
            mapper: m, index: idx, dialect: .default, column: 1, order: .descending,
            recordOffset: 1, rowCount: 3, onProgress: { _ in })
        #expect(perm == [0, 2, 1])      // 30, 25, 20
    }

    @Test func textAscending() async throws {
        let (m, idx) = try await TestSupport.buildIndex(sample, stride: 2)
        let perm = await SortEngine().sortedPermutation(
            mapper: m, index: idx, dialect: .default, column: 0, order: .ascending,
            recordOffset: 1, rowCount: 3, onProgress: { _ in })
        #expect(perm == [1, 0, 2])      // Alice, Bob, Carol
    }

    @Test func numericSortsNotLexically() async throws {
        // "100" < "9" lexically, but 9 < 100 numerically.
        let (m, idx) = try await TestSupport.buildIndex("n\n100\n9\n11\n", stride: 2)
        let perm = await SortEngine().sortedPermutation(
            mapper: m, index: idx, dialect: .default, column: 0, order: .ascending,
            recordOffset: 1, rowCount: 3, onProgress: { _ in })
        #expect(perm == [1, 2, 0])      // 9, 11, 100
    }

    @Test func numericDetection() {
        #expect(SortEngine.isNumericColumn(["1", "2", "3", "", ""]))
        #expect(!SortEngine.isNumericColumn(["apple", "banana", "cherry"]))
    }

    // MARK: Filtered-subset sort (sort by explicit byte offsets)

    /// Byte start of each record, used to build the subset offset list a filter
    /// would have captured.
    private func offset(_ m: FileMapper, _ idx: RecordIndex, record: Int) -> Int {
        idx.byteRange(forRow: record, mapper: m, dialect: .default)!.lowerBound
    }

    @Test func subsetNumericAscending() async throws {
        let (m, idx) = try await TestSupport.buildIndex(sample, stride: 2)
        // Filtered subset in arbitrary order: Bob(30), Carol(25), Alice(20).
        let offsets = [offset(m, idx, record: 1), offset(m, idx, record: 3), offset(m, idx, record: 2)]
        let perm = await SortEngine().sortedPermutation(
            mapper: m, dialect: .default, column: 1, order: .ascending,
            offsets: offsets, onProgress: { _ in })
        #expect(perm == [2, 1, 0])      // subset-space: Alice(20), Carol(25), Bob(30)
    }

    @Test func subsetTextDescending() async throws {
        let (m, idx) = try await TestSupport.buildIndex(sample, stride: 2)
        let offsets = [offset(m, idx, record: 1), offset(m, idx, record: 2), offset(m, idx, record: 3)]
        let perm = await SortEngine().sortedPermutation(
            mapper: m, dialect: .default, column: 0, order: .descending,
            offsets: offsets, onProgress: { _ in })
        // subset: Bob(0), Alice(1), Carol(2). Descending by name → Carol, Bob, Alice.
        #expect(perm == [2, 0, 1])
    }

    @Test func subsetEmptyOffsets() async throws {
        let (m, _) = try await TestSupport.buildIndex(sample, stride: 2)
        let perm = await SortEngine().sortedPermutation(
            mapper: m, dialect: .default, column: 0, order: .ascending,
            offsets: [], onProgress: { _ in })
        #expect(perm == [])
    }
}
