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
}
