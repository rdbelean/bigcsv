import Testing
import Foundation
@testable import BigCSVKit

@Suite("SearchEngine & offset→row")
struct SearchEngineTests {

    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var rows: [Int] = []
        private(set) var complete = false
        private(set) var finalCount = 0
        func add(_ r: Int) { lock.lock(); rows.append(r); lock.unlock() }
        func progress(_ n: Int, _ done: Bool) { lock.lock(); if done { complete = true; finalCount = n }; lock.unlock() }
    }

    // MARK: firstIndex

    @Test func firstIndexFindsSubstring() {
        Array("xxabcyy".utf8).withUnsafeBytes { buf in
            #expect(SearchEngine.firstIndex(of: Array("abc".utf8), in: buf, from: 0, caseSensitive: true) == 2)
        }
    }

    @Test func firstIndexCaseInsensitive() {
        Array("Hello WORLD".utf8).withUnsafeBytes { buf in
            #expect(SearchEngine.firstIndex(of: Array("world".utf8), in: buf, from: 0, caseSensitive: false) == 6)
        }
    }

    @Test func firstIndexCaseSensitiveMisses() {
        Array("Hello WORLD".utf8).withUnsafeBytes { buf in
            #expect(SearchEngine.firstIndex(of: Array("world".utf8), in: buf, from: 0, caseSensitive: true) == nil)
        }
    }

    @Test func firstIndexNotFound() {
        Array("abc".utf8).withUnsafeBytes { buf in
            #expect(SearchEngine.firstIndex(of: Array("xyz".utf8), in: buf, from: 0, caseSensitive: true) == nil)
        }
    }

    // MARK: offset → row

    @Test func rowForByteOffset() async throws {
        let (m, idx) = try await TestSupport.buildIndex("a\nbb\nccc\n", stride: 2)
        #expect(idx.row(forByteOffset: 0, mapper: m, dialect: .default) == 0)   // "a"
        #expect(idx.row(forByteOffset: 3, mapper: m, dialect: .default) == 1)   // "bb"
        #expect(idx.row(forByteOffset: 6, mapper: m, dialect: .default) == 2)   // "ccc"
    }

    // MARK: streaming search

    @Test func searchCaseInsensitiveFindsAllRows() async throws {
        let (m, idx) = try await TestSupport.buildIndex("id,name\n1,Alice\n2,Bob\n3,alice\n4,Carol\n", stride: 2)
        let c = Collector()
        await SearchEngine().search(mapper: m, index: idx, dialect: .default,
                                    query: "alice", caseSensitive: false,
                                    onMatch: { c.add($0) },
                                    onProgress: { n, _, done in c.progress(n, done) })
        #expect(c.rows == [1, 3])       // "Alice" (record 1) and "alice" (record 3)
        #expect(c.complete)
        #expect(c.finalCount == 2)
    }

    @Test func searchCaseSensitiveIsExact() async throws {
        let (m, idx) = try await TestSupport.buildIndex("id,name\n1,Alice\n2,Bob\n3,alice\n", stride: 2)
        let c = Collector()
        await SearchEngine().search(mapper: m, index: idx, dialect: .default,
                                    query: "alice", caseSensitive: true,
                                    onMatch: { c.add($0) },
                                    onProgress: { n, _, done in c.progress(n, done) })
        #expect(c.rows == [3])          // only the lowercase "alice"
    }

    @Test func searchReportsEachRowOnce() async throws {
        // "ab" appears twice in one record → that record reported once.
        let (m, idx) = try await TestSupport.buildIndex("ab ab cd\nxy\n", stride: 2)
        let c = Collector()
        await SearchEngine().search(mapper: m, index: idx, dialect: .default,
                                    query: "ab", caseSensitive: false,
                                    onMatch: { c.add($0) },
                                    onProgress: { n, _, done in c.progress(n, done) })
        #expect(c.rows == [0])
    }

    @Test func emptyQueryYieldsNoMatches() async throws {
        let (m, idx) = try await TestSupport.buildIndex("a\nb\n")
        let c = Collector()
        await SearchEngine().search(mapper: m, index: idx, dialect: .default,
                                    query: "", caseSensitive: false,
                                    onMatch: { c.add($0) },
                                    onProgress: { n, _, done in c.progress(n, done) })
        #expect(c.rows.isEmpty)
        #expect(c.complete)
    }
}
