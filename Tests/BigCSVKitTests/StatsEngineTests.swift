import Testing
import Foundation
@testable import BigCSVKit

@Suite("StatsEngine")
struct StatsEngineTests {

    private func source(_ m: FileMapper, rowCount: Int,
                        subset: [Int]? = nil, recordOffset: Int = 1) -> ExportRowSource {
        ExportRowSource(mapper: m, dialect: .default, subsetOffsets: subset, order: nil,
                        recordOffset: recordOffset, rowCount: rowCount)
    }

    @Test func numericColumnEvenMedian() async throws {
        let (m, _) = try await TestSupport.buildIndex("v\n1\n2\n3\n4\n", stride: 2)
        let s = try await StatsEngine().compute(source: source(m, rowCount: 4), column: 0,
                                                onProgress: { _ in })
        #expect(s.total == 4)
        #expect(s.numericCount == 4)
        #expect(s.sum == 10)
        #expect(s.mean == 2.5)
        #expect(s.minValue == 1)
        #expect(s.maxValue == 4)
        #expect(s.median == 2.5)               // (2 + 3) / 2
        #expect(s.distinctCount == 4)
        #expect(s.empty == 0)
    }

    @Test func numericColumnOddMedian() async throws {
        let (m, _) = try await TestSupport.buildIndex("v\n10\n2\n7\n", stride: 2)
        let s = try await StatsEngine().compute(source: source(m, rowCount: 3), column: 0,
                                                onProgress: { _ in })
        #expect(s.median == 7)                  // sorted [2,7,10] → middle 7
        #expect(s.minValue == 2)
        #expect(s.maxValue == 10)
    }

    @Test func mixedColumnCountsEmptyAndDistinct() async throws {
        let (m, _) = try await TestSupport.buildIndex("v\na\n\n5\na\n", stride: 2)
        let s = try await StatsEngine().compute(source: source(m, rowCount: 4), column: 0,
                                                onProgress: { _ in })
        #expect(s.total == 4)
        #expect(s.empty == 1)
        #expect(s.filled == 3)
        #expect(s.numericCount == 1)            // only "5"
        #expect(s.distinctCount == 2)           // "a", "5"
        #expect(s.mean == 5)
        #expect(s.isNumeric)
    }

    @Test func europeanNumbersCount() async throws {
        // Semicolon delimiter so the decimal comma stays inside the field.
        let dialect = CSVDialect(delimiter: .semicolon)
        let (m, _) = try await TestSupport.buildIndex("v\n1.234,5\n2,5\n", dialect: dialect, stride: 2)
        let src = ExportRowSource(mapper: m, dialect: dialect, subsetOffsets: nil, order: nil,
                                  recordOffset: 1, rowCount: 2)
        let s = try await StatsEngine().compute(source: src, column: 0, onProgress: { _ in })
        #expect(s.numericCount == 2)
        #expect(s.sum == 1237.0)                // 1234.5 + 2.5
    }

    @Test func statsOverFilteredSubset() async throws {
        let (m, idx) = try await TestSupport.buildIndex("name,n\nA,10\nB,20\nC,30\nD,40\n", stride: 2)
        func off(_ r: Int) -> Int { idx.byteRange(forRow: r, mapper: m, dialect: .default)!.lowerBound }
        // Subset = rows A and C (records 1, 3) → column 1 values 10, 30.
        let s = try await StatsEngine().compute(
            source: source(m, rowCount: 4, subset: [off(1), off(3)]), column: 1,
            onProgress: { _ in })
        #expect(s.total == 2)
        #expect(s.sum == 40)
        #expect(s.mean == 20)
        #expect(s.minValue == 10)
        #expect(s.maxValue == 30)
        #expect(s.median == 20)
    }

    @Test func emptyColumnHasNoNumericStats() async throws {
        let (m, _) = try await TestSupport.buildIndex("v\n\n\n", stride: 2)
        let s = try await StatsEngine().compute(source: source(m, rowCount: 2), column: 0,
                                                onProgress: { _ in })
        #expect(s.total == 2)
        #expect(s.empty == 2)
        #expect(s.numericCount == 0)
        #expect(!s.isNumeric)
        #expect(s.median == nil)
        #expect(s.mean == nil)
    }
}
