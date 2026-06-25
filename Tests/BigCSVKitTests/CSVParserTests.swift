import Testing
import Foundation
@testable import BigCSVKit

@Suite("CSVParser")
struct CSVParserTests {

    @Test func simpleRow() {
        #expect(TestSupport.parse("a,b,c") == ["a", "b", "c"])
    }

    @Test func quotedFieldContainingDelimiter() {
        #expect(TestSupport.parse("a,\"b,c\",d") == ["a", "b,c", "d"])
    }

    @Test func escapedQuotes() {
        #expect(TestSupport.parse("\"she said \"\"hi\"\"\"") == ["she said \"hi\""])
    }

    @Test func emptyFields() {
        #expect(TestSupport.parse("a,,c") == ["a", "", "c"])
    }

    @Test func trailingDelimiterYieldsEmptyLastField() {
        #expect(TestSupport.parse("a,b,") == ["a", "b", ""])
    }

    @Test func leadingDelimiterYieldsEmptyFirstField() {
        #expect(TestSupport.parse(",a,b") == ["", "a", "b"])
    }

    @Test func spacesArePreserved() {
        #expect(TestSupport.parse(" a , b ") == [" a ", " b "])
    }

    @Test func leadingSpaceDisablesQuoting() {
        // A space before the quote means the field is NOT quoted; the quote is literal (Excel behavior).
        #expect(TestSupport.parse(" \"a,b\"") == [" \"a", "b\""])
    }

    @Test func midFieldQuoteIsLiteral() {
        #expect(TestSupport.parse("ab\"cd") == ["ab\"cd"])
    }

    @Test func blankRecordIsSingleEmptyField() {
        #expect(TestSupport.parse("") == [""])
    }

    @Test func quotedFieldWithEmbeddedNewline() {
        #expect(TestSupport.parse("\"a\nb\",c") == ["a\nb", "c"])
    }

    @Test func trimsTrailingLF() {
        #expect(TestSupport.parse("a,b\n") == ["a", "b"])
    }

    @Test func trimsTrailingCRLF() {
        #expect(TestSupport.parse("a,b\r\n") == ["a", "b"])
    }

    @Test func trimsTrailingLoneCR() {
        #expect(TestSupport.parse("a,b\r") == ["a", "b"])
    }

    @Test func semicolonDelimiter() {
        let d = CSVDialect(delimiter: .semicolon)
        #expect(TestSupport.parse("a;b;c", dialect: d) == ["a", "b", "c"])
    }

    @Test func tabDelimiter() {
        let d = CSVDialect(delimiter: .tab)
        #expect(TestSupport.parse("a\tb\tc", dialect: d) == ["a", "b", "c"])
    }

    @Test func pipeDelimiter() {
        let d = CSVDialect(delimiter: .pipe)
        #expect(TestSupport.parse("a|b|c", dialect: d) == ["a", "b", "c"])
    }

    @Test func utf8Multibyte() {
        #expect(TestSupport.parse("café,xÿz") == ["café", "xÿz"])
    }

    @Test func windows1252Fallback() {
        // "café" in Windows-1252: c=0x63 a=0x61 f=0x66 é=0xE9
        let bytes: [UInt8] = [0x63, 0x61, 0x66, 0xE9]
        let d = CSVDialect(encoding: .windows1252)
        #expect(TestSupport.parse(bytes, dialect: d) == ["café"])
    }

    @Test func raggedShortAndLongRowsParseToTheirFieldCount() {
        #expect(TestSupport.parse("a") == ["a"])
        #expect(TestSupport.parse("a,b,c,d,e") == ["a", "b", "c", "d", "e"])
    }

    @Test func quotedFieldFollowedByDelimiterAndEmpty() {
        #expect(TestSupport.parse("\"x\",,\"y\"") == ["x", "", "y"])
    }
}
