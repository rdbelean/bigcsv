import Testing
import Foundation
@testable import BigCSVKit

@Suite("XLSX number & cell serialization")
struct XLSXSerializationTests {
    @Test func plainIntegersAreNumeric() {
        #expect(XLSXExporter.numericLiteral("42") == "42")
        #expect(XLSXExporter.numericLiteral("0") == "0")
        #expect(XLSXExporter.numericLiteral("-7") == "-7")
        #expect(XLSXExporter.numericLiteral("  42  ") == "42")     // trimmed
    }
    @Test func usDecimalsKeepExactText() {
        #expect(XLSXExporter.numericLiteral("1234.56") == "1234.56")
        #expect(XLSXExporter.numericLiteral("-3.14") == "-3.14")
        #expect(XLSXExporter.numericLiteral("0.5") == "0.5")
        #expect(XLSXExporter.numericLiteral("1e5") == "1e5")
    }
    @Test func europeanNumbersAreNormalized() {
        #expect(XLSXExporter.numericLiteral("1.234,56") == "1234.56")
        #expect(XLSXExporter.numericLiteral("1,5") == "1.5")
    }
    @Test func zeroPrefixedCodesStayText() {
        #expect(XLSXExporter.numericLiteral("007") == nil)
        #expect(XLSXExporter.numericLiteral("00") == nil)
        #expect(XLSXExporter.numericLiteral("0123") == nil)
    }
    @Test func nonNumbersAreText() {
        #expect(XLSXExporter.numericLiteral("") == nil)
        #expect(XLSXExporter.numericLiteral("abc") == nil)
        #expect(XLSXExporter.numericLiteral("1.2.3") == nil)
        #expect(XLSXExporter.numericLiteral("12px") == nil)
    }
    @Test func ambiguousDottedRunsStayText() {
        // No decimal comma → dot grouping is NOT honored (IP / version / grouped IDs).
        #expect(XLSXExporter.numericLiteral("1.234.567") == nil)
        #expect(XLSXExporter.numericLiteral("192.168.001") == nil)
        #expect(XLSXExporter.numericLiteral("123.456.789") == nil)
        // But a real European decimal still parses.
        #expect(XLSXExporter.numericLiteral("1.234.567,89") == "1234567.89")
    }
    @Test func overflowingNumbersStayText() {
        #expect(XLSXExporter.numericLiteral("1e500") == nil)             // → +inf as a double
        #expect(XLSXExporter.numericLiteral(String(repeating: "9", count: 350)) == nil)
    }
    @Test func forceTextKeepsNumericLookingHeadersAsStrings() {
        var out = [UInt8]()
        XLSXExporter.appendCell("2023", colRef: Array("A".utf8), rowDigits: Array("1".utf8),
                                forceText: true, into: &out)
        #expect(String(decoding: out, as: UTF8.self)
                == "<c r=\"A1\" t=\"inlineStr\"><is><t xml:space=\"preserve\">2023</t></is></c>")
    }
    @Test func columnLetters() {
        #expect(String(decoding: XLSXExporter.columnLetters(0), as: UTF8.self) == "A")
        #expect(String(decoding: XLSXExporter.columnLetters(25), as: UTF8.self) == "Z")
        #expect(String(decoding: XLSXExporter.columnLetters(26), as: UTF8.self) == "AA")
        #expect(String(decoding: XLSXExporter.columnLetters(701), as: UTF8.self) == "ZZ")
        #expect(String(decoding: XLSXExporter.columnLetters(702), as: UTF8.self) == "AAA")
    }
    @Test func xmlTextEscapingAndControlStripping() {
        var out = [UInt8]()
        XLSXExporter.appendXMLText("a<b>&c", into: &out)
        #expect(String(decoding: out, as: UTF8.self) == "a&lt;b&gt;&amp;c")
        out.removeAll()
        XLSXExporter.appendXMLText("a\tb\u{01}c\nd", into: &out)   //  illegal in XML
        #expect(String(decoding: out, as: UTF8.self) == "a\tbc\nd")
    }
    @Test func cellNumericVsString() {
        var num = [UInt8]()
        XLSXExporter.appendCell("42", colRef: Array("A".utf8), rowDigits: Array("1".utf8), into: &num)
        #expect(String(decoding: num, as: UTF8.self) == "<c r=\"A1\"><v>42</v></c>")
        var str = [UInt8]()
        XLSXExporter.appendCell("hi", colRef: Array("B".utf8), rowDigits: Array("2".utf8), into: &str)
        #expect(String(decoding: str, as: UTF8.self)
                == "<c r=\"B2\" t=\"inlineStr\"><is><t xml:space=\"preserve\">hi</t></is></c>")
    }
}

@Suite("XLSX file (ZIP)")
struct XLSXFileTests {

    private func tmpURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("bigcsv-xlsx-\(UUID().uuidString).xlsx")
    }

    /// Minimal STORED-only ZIP reader: parses the central directory, validates each
    /// entry's CRC-32 against its bytes, and returns name → raw bytes.
    private func unzipStored(_ data: Data) throws -> [String: [UInt8]] {
        let b = [UInt8](data)
        func le16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func le32(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 }

        // Find EOCD (PK\x05\x06) scanning back from the end.
        var eocd = -1
        var i = b.count - 22
        while i >= 0 {
            if b[i] == 0x50, b[i+1] == 0x4B, b[i+2] == 0x05, b[i+3] == 0x06 { eocd = i; break }
            i -= 1
        }
        #expect(eocd >= 0)
        let count = le16(eocd + 10)
        var p = le32(eocd + 16)                                   // central directory offset

        var parts: [String: [UInt8]] = [:]
        for _ in 0..<count {
            #expect(le32(p) == 0x0201_4b50)                       // central header signature
            let crc = UInt32(le32(p + 16))
            let size = le32(p + 24)                               // uncompressed size
            let nameLen = le16(p + 28)
            let extraLen = le16(p + 30)
            let commentLen = le16(p + 32)
            let localOff = le32(p + 42)
            let name = String(decoding: b[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)

            // Local header → data start.
            #expect(le32(localOff) == 0x0403_4b50)
            let lNameLen = le16(localOff + 26)
            let lExtraLen = le16(localOff + 28)
            let dataStart = localOff + 30 + lNameLen + lExtraLen
            let bytes = Array(b[dataStart..<(dataStart + size)])
            #expect(CRC32.checksum(bytes) == crc)                 // integrity: stored CRC matches data
            parts[name] = bytes
            p += 46 + nameLen + extraLen + commentLen
        }
        return parts
    }

    @Test func producesValidWorkbookWithExpectedCells() async throws {
        let (m, _) = try await TestSupport.buildIndex("name,age\nAlice,30\nBob,25\n", stride: 2)
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = ExportRowSource(mapper: m, dialect: .default,
                                     subsetOffsets: nil, order: nil, recordOffset: 1, rowCount: 2)
        let result = try await XLSXExporter().export(
            source: source, columns: ["name", "age"], includeHeader: true, to: url,
            onProgress: { _, _ in })
        #expect(result.rowsWritten == 2)
        #expect(result.truncated == false)

        let data = try Data(contentsOf: url)
        #expect(Array(data.prefix(4)) == [0x50, 0x4B, 0x03, 0x04])   // ZIP local header magic
        let parts = try unzipStored(data)
        // All required parts present.
        for required in ["[Content_Types].xml", "_rels/.rels", "xl/workbook.xml",
                         "xl/_rels/workbook.xml.rels", "xl/styles.xml", "xl/worksheets/sheet1.xml"] {
            #expect(parts[required] != nil, "missing part \(required)")
        }
        let sheet = String(decoding: parts["xl/worksheets/sheet1.xml"]!, as: UTF8.self)
        // Header strings, a numeric cell, a string cell, in the right places.
        #expect(sheet.contains("<c r=\"A1\" t=\"inlineStr\"><is><t xml:space=\"preserve\">name</t></is></c>"))
        #expect(sheet.contains("<c r=\"A2\" t=\"inlineStr\"><is><t xml:space=\"preserve\">Alice</t></is></c>"))
        #expect(sheet.contains("<c r=\"B2\"><v>30</v></c>"))
        #expect(sheet.contains("<c r=\"B3\"><v>25</v></c>"))
        #expect(sheet.contains("<row r=\"1\">") && sheet.contains("<row r=\"3\">"))
        #expect(sheet.hasSuffix("</sheetData></worksheet>"))
    }

    @Test func filteredSortedViewExportsInOrder() async throws {
        let (m, idx) = try await TestSupport.buildIndex(
            "name,age\nAlice,30\nBob,25\nCarol,40\n", stride: 2)
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }
        func off(_ r: Int) -> Int { idx.byteRange(forRow: r, mapper: m, dialect: .default)!.lowerBound }
        // Subset = Alice, Carol (records 1,3); sorted desc by age → Carol(40), Alice(30).
        let source = ExportRowSource(mapper: m, dialect: .default,
                                     subsetOffsets: [off(1), off(3)], order: [1, 0],
                                     recordOffset: 1, rowCount: 3)
        _ = try await XLSXExporter().export(source: source, columns: ["name", "age"],
                                            includeHeader: false, to: url, onProgress: { _, _ in })
        let sheet = String(decoding: try unzipStored(Data(contentsOf: url))["xl/worksheets/sheet1.xml"]!,
                           as: UTF8.self)
        // Row 1 = Carol/40, Row 2 = Alice/30.
        let carol = sheet.range(of: "Carol")!
        let alice = sheet.range(of: "Alice")!
        #expect(carol.lowerBound < alice.lowerBound)
        #expect(sheet.contains("<c r=\"B1\"><v>40</v></c>"))
        #expect(sheet.contains("<c r=\"B2\"><v>30</v></c>"))
    }

    @Test func numericHeaderIsWrittenAsText() async throws {
        let (m, _) = try await TestSupport.buildIndex("2023,name\n10,Alice\n", stride: 2)
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = ExportRowSource(mapper: m, dialect: .default,
                                     subsetOffsets: nil, order: nil, recordOffset: 1, rowCount: 1)
        _ = try await XLSXExporter().export(source: source, columns: ["2023", "name"],
                                            includeHeader: true, to: url, onProgress: { _, _ in })
        let sheet = String(decoding: try unzipStored(Data(contentsOf: url))["xl/worksheets/sheet1.xml"]!,
                           as: UTF8.self)
        // Header "2023" stays a label (inlineStr), while the data 10 is a real number.
        #expect(sheet.contains("<c r=\"A1\" t=\"inlineStr\"><is><t xml:space=\"preserve\">2023</t></is></c>"))
        #expect(sheet.contains("<c r=\"A2\"><v>10</v></c>"))
    }

    @Test func emptyCellsAreOmitted() async throws {
        let (m, _) = try await TestSupport.buildIndex("a,b,c\nx,,z\n", stride: 2)
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = ExportRowSource(mapper: m, dialect: .default,
                                     subsetOffsets: nil, order: nil, recordOffset: 1, rowCount: 1)
        _ = try await XLSXExporter().export(source: source, columns: ["a", "b", "c"],
                                            includeHeader: false, to: url, onProgress: { _, _ in })
        let sheet = String(decoding: try unzipStored(Data(contentsOf: url))["xl/worksheets/sheet1.xml"]!,
                           as: UTF8.self)
        #expect(sheet.contains("r=\"A1\""))      // x
        #expect(sheet.contains("r=\"C1\""))      // z
        #expect(!sheet.contains("r=\"B1\""))     // empty middle cell omitted
    }
}
