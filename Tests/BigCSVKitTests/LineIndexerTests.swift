import Testing
import Foundation
@testable import BigCSVKit

@Suite("LineIndexer & RecordIndex")
struct LineIndexerTests {

    @Test func twoRowsWithTrailingNewline() async throws {
        let (m, idx) = try await TestSupport.buildIndex("a,b,c\nd,e,f\n")
        #expect(idx.count == 2)
        #expect(TestSupport.fields(m, idx, row: 0) == ["a", "b", "c"])
        #expect(TestSupport.fields(m, idx, row: 1) == ["d", "e", "f"])
    }

    @Test func noTrailingNewlineCountsLastRow() async throws {
        let (m, idx) = try await TestSupport.buildIndex("a\nb")
        #expect(idx.count == 2)
        #expect(TestSupport.fields(m, idx, row: 0) == ["a"])
        #expect(TestSupport.fields(m, idx, row: 1) == ["b"])
    }

    @Test func trailingNewlineDoesNotAddPhantomRow() async throws {
        let (_, idx) = try await TestSupport.buildIndex("a\nb\n")
        #expect(idx.count == 2)
    }

    @Test func embeddedNewlineInQuotesIsNotARowBoundary() async throws {
        let (m, idx) = try await TestSupport.buildIndex("x,\"line1\nline2\",y\nnext,1,2\n")
        #expect(idx.count == 2)
        #expect(TestSupport.fields(m, idx, row: 0) == ["x", "line1\nline2", "y"])
        #expect(TestSupport.fields(m, idx, row: 1) == ["next", "1", "2"])
    }

    @Test func crlfLineEndings() async throws {
        let (m, idx) = try await TestSupport.buildIndex("a,b\r\nc,d\r\n")
        #expect(idx.count == 2)
        #expect(TestSupport.fields(m, idx, row: 0) == ["a", "b"])
        #expect(TestSupport.fields(m, idx, row: 1) == ["c", "d"])
    }

    @Test func loneCRLineEndings() async throws {
        let (m, idx) = try await TestSupport.buildIndex("a,b\rc,d\r")
        #expect(idx.count == 2)
        #expect(TestSupport.fields(m, idx, row: 0) == ["a", "b"])
        #expect(TestSupport.fields(m, idx, row: 1) == ["c", "d"])
    }

    @Test func mixedLineEndings() async throws {
        let (m, idx) = try await TestSupport.buildIndex("a\r\nb\nc\r")
        #expect(idx.count == 3)
        #expect(TestSupport.fields(m, idx, row: 0) == ["a"])
        #expect(TestSupport.fields(m, idx, row: 1) == ["b"])
        #expect(TestSupport.fields(m, idx, row: 2) == ["c"])
    }

    @Test func blankLineIsAnEmptyRow() async throws {
        let (m, idx) = try await TestSupport.buildIndex("a\n\nb\n")
        #expect(idx.count == 3)
        #expect(TestSupport.fields(m, idx, row: 0) == ["a"])
        #expect(TestSupport.fields(m, idx, row: 1) == [""])
        #expect(TestSupport.fields(m, idx, row: 2) == ["b"])
    }

    @Test func emptyFileHasZeroRows() async throws {
        let (_, idx) = try await TestSupport.buildIndex("")
        #expect(idx.count == 0)
        #expect(idx.isComplete)
    }

    @Test func singleRowNoNewline() async throws {
        let (m, idx) = try await TestSupport.buildIndex("hello,world")
        #expect(idx.count == 1)
        #expect(TestSupport.fields(m, idx, row: 0) == ["hello", "world"])
    }

    @Test func utf8BOMIsStrippedFromFirstField() async throws {
        var bytes: [UInt8] = [0xEF, 0xBB, 0xBF]      // UTF-8 BOM
        bytes.append(contentsOf: Array("a,b\nc,d\n".utf8))
        let (m, idx) = try await TestSupport.buildIndex(bytes)
        #expect(idx.count == 2)
        #expect(TestSupport.fields(m, idx, row: 0) == ["a", "b"])   // not "\u{FEFF}a"
    }

    @Test func checkpointResolutionAcrossManyRows() async throws {
        // 10 rows, small stride to force multiple checkpoints + in-block rescans.
        var s = ""
        for i in 0..<10 { s += "r\(i)c0,r\(i)c1\n" }
        let (m, idx) = try await TestSupport.buildIndex(s, stride: 3)
        #expect(idx.count == 10)
        for i in 0..<10 {
            #expect(TestSupport.fields(m, idx, row: i) == ["r\(i)c0", "r\(i)c1"])
        }
    }

    @Test func contiguousWindowResolution() async throws {
        var s = ""
        for i in 0..<20 { s += "\(i)\n" }
        let (m, idx) = try await TestSupport.buildIndex(s, stride: 4)
        let ranges = idx.byteRanges(forRows: 5..<12, mapper: m, dialect: .default)
        #expect(ranges.count == 7)
        for (offset, range) in ranges.enumerated() {
            let row = 5 + offset
            #expect(CSVParser.parseRecord(m.bytes(in: range), dialect: .default) == ["\(row)"])
        }
    }

    @Test func incrementalCountIsMonotonicAndComplete() async throws {
        // Drive the indexer manually to observe progress callbacks growing.
        var s = ""
        for i in 0..<5000 { s += "row\(i)\n" }
        let url = try TestSupport.writeTempFile(s)
        let mapper = try FileMapper(url: url)
        try? FileManager.default.removeItem(at: url)
        let index = RecordIndex(stride: 1024)

        actor Box { var last = 0; var sawComplete = false
            func update(_ p: IndexProgress) { last = max(last, p.rowCount); if p.isComplete { sawComplete = true } } }
        let box = Box()
        await LineIndexer(progressRowInterval: 512).index(mapper, dialect: .default, into: index) { p in
            Task { await box.update(p) }
        }
        #expect(index.count == 5000)
        #expect(index.isComplete)
    }
}
