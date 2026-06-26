import Testing
import Foundation
@testable import BigCSVKit

@Suite("NumberParsing")
struct NumberParsingTests {
    @Test func usFormat() { #expect(NumberParsing.parse("1234.56") == 1234.56) }
    @Test func europeanFormat() { #expect(NumberParsing.parse("1.234,56") == 1234.56) }
    @Test func europeanDecimalOnly() { #expect(NumberParsing.parse("1,5") == 1.5) }
    @Test func plainInteger() { #expect(NumberParsing.parse("42") == 42) }
    @Test func emptyIsNil() { #expect(NumberParsing.parse("   ") == nil) }
    @Test func textIsNil() { #expect(NumberParsing.parse("abc") == nil) }
    @Test func detectsNumericColumn() {
        #expect(NumberParsing.isNumericColumn(["1.234,56", "987,00", "42"]))
        #expect(!NumberParsing.isNumericColumn(["Berlin", "Paris", "Tokyo"]))
    }
}

@Suite("ColumnCondition")
struct ColumnConditionTests {
    private func cond(_ op: FilterOperator, _ value: String, column: Int = 0, cs: Bool = false) -> ColumnCondition {
        ColumnCondition(column: column, op: op, value: value, caseSensitive: cs)
    }

    @Test func contains() {
        #expect(cond(.contains, "york").matches(["New York"]))
        #expect(!cond(.contains, "york", cs: true).matches(["New York"]))   // case-sensitive miss
    }
    @Test func equalsCaseInsensitive() {
        #expect(cond(.equals, "berlin").matches(["Berlin"]))
        #expect(!cond(.equals, "Berl").matches(["Berlin"]))
    }
    @Test func beginsEnds() {
        #expect(cond(.beginsWith, "New").matches(["New York"]))
        #expect(cond(.endsWith, "York").matches(["New York"]))
        #expect(!cond(.beginsWith, "York").matches(["New York"]))
    }
    @Test func numericGreaterLess() {
        #expect(cond(.greaterThan, "100").matches(["150"]))
        #expect(!cond(.greaterThan, "100").matches(["9"]))      // numeric, not lexical
        #expect(cond(.lessThan, "100").matches(["9"]))
    }
    @Test func numericExcludesNonNumbers() {
        #expect(!cond(.greaterThan, "100").matches([""]))       // empty → non-matching
        #expect(!cond(.greaterThan, "100").matches(["abc"]))
    }
    @Test func europeanNumeric() {
        #expect(cond(.greaterThan, "1000").matches(["1.234,56"]))
    }
    @Test func emptyAndNotEmpty() {
        #expect(cond(.isEmpty, "").matches([""]))
        #expect(cond(.isEmpty, "").matches(["   "]))
        #expect(cond(.isNotEmpty, "").matches(["x"]))
    }
    @Test func raggedRowOutOfRangeColumn() {
        #expect(cond(.isEmpty, "", column: 5).matches(["a", "b"]))   // missing column reads empty
    }
}

@Suite("FilterSet")
struct FilterSetTests {
    @Test func emptyMatchesAll() {
        #expect(FilterSet().matches(["anything"]))
    }
    @Test func andCombinator() {
        let fs = FilterSet(combinator: .all, conditions: [
            ColumnCondition(column: 0, op: .contains, value: "a"),
            ColumnCondition(column: 1, op: .greaterThan, value: "10"),
        ])
        #expect(fs.matches(["alpha", "20"]))
        #expect(!fs.matches(["alpha", "5"]))     // second fails
        #expect(!fs.matches(["xyz", "20"]))      // first fails
    }
    @Test func orCombinator() {
        let fs = FilterSet(combinator: .any, conditions: [
            ColumnCondition(column: 0, op: .equals, value: "Berlin"),
            ColumnCondition(column: 0, op: .equals, value: "Paris"),
        ])
        #expect(fs.matches(["Berlin"]))
        #expect(fs.matches(["Paris"]))
        #expect(!fs.matches(["Tokyo"]))
    }
    @Test func codableRoundTrip() throws {
        let fs = FilterSet(combinator: .any, conditions: [ColumnCondition(column: 2, op: .lessThan, value: "5")])
        let data = try JSONEncoder().encode(fs)
        #expect(try JSONDecoder().decode(FilterSet.self, from: data) == fs)
    }
}

@Suite("FilterEngine")
struct FilterEngineTests {
    final class Collector: @unchecked Sendable {
        private let lock = NSLock(); private(set) var rows: [UInt32] = []; private(set) var done = false
        func add(_ r: UInt32) { lock.lock(); rows.append(r); lock.unlock() }
        func finish() { lock.lock(); done = true; lock.unlock() }
    }

    @Test func filtersMatchingDisplayRows() async throws {
        // header + 4 data rows; filter city == Tokyo (column 1).
        let (m, idx) = try await TestSupport.buildIndex(
            "name,city\nAlice,Tokyo\nBob,Paris\nCarol,Tokyo\nDave,Berlin\n", stride: 2)
        let c = Collector()
        let fs = FilterSet(conditions: [ColumnCondition(column: 1, op: .equals, value: "Tokyo")])
        await FilterEngine().filter(mapper: m, index: idx, dialect: .default, filterSet: fs,
                                    recordOffset: 1, rowCount: 4,
                                    onMatch: { c.add($0) },
                                    onProgress: { _, _, done in if done { c.finish() } })
        #expect(c.rows == [0, 2])     // display rows 0 (Alice) and 2 (Carol)
        #expect(c.done)
    }

    @Test func emptyFilterYieldsNothing() async throws {
        let (m, idx) = try await TestSupport.buildIndex("a\nb\nc\n", stride: 2)
        let c = Collector()
        await FilterEngine().filter(mapper: m, index: idx, dialect: .default, filterSet: FilterSet(),
                                    recordOffset: 0, rowCount: 3,
                                    onMatch: { c.add($0) },
                                    onProgress: { _, _, done in if done { c.finish() } })
        #expect(c.rows.isEmpty)       // empty filter handled by caller (identity), engine emits none
    }
}
