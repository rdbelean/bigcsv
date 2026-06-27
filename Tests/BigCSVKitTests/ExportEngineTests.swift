import Testing
import Foundation
@testable import BigCSVKit

@Suite("Export serialization")
struct ExportSerializationTests {

    private func csvField(_ s: String, delimiter: UInt8 = 0x2C) -> String {
        var out = [UInt8](); ExportEngine.appendDelimitedField(s, delimiter: delimiter, into: &out)
        return String(decoding: out, as: UTF8.self)
    }
    private func jsonString(_ s: String) -> String {
        var out = [UInt8](); ExportEngine.appendJSONString(s, into: &out)
        return String(decoding: out, as: UTF8.self)
    }

    @Test func plainFieldIsUnquoted() {
        #expect(csvField("hello") == "hello")
        #expect(csvField("") == "")
    }
    @Test func fieldWithDelimiterIsQuoted() {
        #expect(csvField("a,b") == "\"a,b\"")
        #expect(csvField("a;b", delimiter: 0x3B) == "\"a;b\"")
        #expect(csvField("a,b", delimiter: 0x09) == "a,b")     // comma is data under a tab delimiter
    }
    @Test func fieldWithQuoteIsDoubledAndWrapped() {
        #expect(csvField("he said \"hi\"") == "\"he said \"\"hi\"\"\"")
    }
    @Test func fieldWithNewlineIsQuoted() {
        #expect(csvField("line1\nline2") == "\"line1\nline2\"")
        #expect(csvField("a\rb") == "\"a\rb\"")
    }
    @Test func jsonEscaping() {
        #expect(jsonString("plain") == "\"plain\"")
        #expect(jsonString("a\"b") == "\"a\\\"b\"")
        #expect(jsonString("a\\b") == "\"a\\\\b\"")
        #expect(jsonString("tab\tnew\nret\r") == "\"tab\\tnew\\nret\\r\"")
        #expect(jsonString("\u{01}") == "\"\\u0001\"")          // control char → \u00xx
        #expect(jsonString("café") == "\"café\"")               // non-ASCII passes through
    }
    @Test func jsonObjectKeysAndRagged() {
        var out = [UInt8]()
        ExportEngine.appendJSONObject(["x", "y", "z"], columns: ["a", "b"], into: &out)
        // extra ragged field gets a generated key
        #expect(String(decoding: out, as: UTF8.self) == "{\"a\":\"x\",\"b\":\"y\",\"Column 3\":\"z\"}")
    }
    @Test func jsonObjectMissingFieldsAreEmpty() {
        var out = [UInt8]()
        ExportEngine.appendJSONObject(["x"], columns: ["a", "b"], into: &out)
        #expect(String(decoding: out, as: UTF8.self) == "{\"a\":\"x\",\"b\":\"\"}")
    }
}

@Suite("ExportEngine (file)")
struct ExportEngineFileTests {

    private func tmpURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("bigcsv-export-\(UUID().uuidString).out")
    }
    private func read(_ url: URL) throws -> String {
        defer { try? FileManager.default.removeItem(at: url) }
        return try String(contentsOf: url, encoding: .utf8)
    }
    private func offset(_ m: FileMapper, _ idx: RecordIndex, record: Int) -> Int {
        idx.byteRange(forRow: record, mapper: m, dialect: .default)!.lowerBound
    }

    @Test func sequentialCSVWithHeader() async throws {
        let (m, _) = try await TestSupport.buildIndex("name,age\nBob,30\nAlice,20\n", stride: 2)
        let url = tmpURL()
        let req = ExportEngine.Request(format: .csv, columns: ["name", "age"], includeHeader: true,
                                       recordOffset: 1, rowCount: 2)
        try await ExportEngine().export(mapper: m, dialect: .default, request: req, to: url,
                                        onProgress: { _, _ in })
        #expect(try read(url) == "name,age\nBob,30\nAlice,20\n")
    }

    @Test func sequentialCSVWithoutHeader() async throws {
        let (m, _) = try await TestSupport.buildIndex("name,age\nBob,30\nAlice,20\n", stride: 2)
        let url = tmpURL()
        let req = ExportEngine.Request(format: .csv, columns: ["name", "age"], includeHeader: false,
                                       recordOffset: 1, rowCount: 2)
        try await ExportEngine().export(mapper: m, dialect: .default, request: req, to: url,
                                        onProgress: { _, _ in })
        #expect(try read(url) == "Bob,30\nAlice,20\n")
    }

    @Test func tsvOutputUsesTabs() async throws {
        let (m, _) = try await TestSupport.buildIndex("a,b\n1,2\n", stride: 2)
        let url = tmpURL()
        let req = ExportEngine.Request(format: .tsv, columns: ["a", "b"], includeHeader: true,
                                       recordOffset: 1, rowCount: 1)
        try await ExportEngine().export(mapper: m, dialect: .default, request: req, to: url,
                                        onProgress: { _, _ in })
        #expect(try read(url) == "a\tb\n1\t2\n")
    }

    @Test func quotingRoundTrips() async throws {
        // Source contains an embedded comma, embedded quotes, and an embedded newline.
        let source = "h1,h2\n\"a,b\",\"he said \"\"hi\"\"\"\n\"line1\nline2\",plain\n"
        let (m, _) = try await TestSupport.buildIndex(source, stride: 2)
        let url = tmpURL()
        let req = ExportEngine.Request(format: .csv, columns: ["h1", "h2"], includeHeader: false,
                                       recordOffset: 1, rowCount: 2)
        try await ExportEngine().export(mapper: m, dialect: .default, request: req, to: url,
                                        onProgress: { _, _ in })
        // Re-parse the exported rows and confirm the fields survived intact.
        let text = try read(url)
        let (m2, idx2) = try await TestSupport.buildIndex(text, dialect:
            CSVDialect(hasHeader: false), stride: 2)
        #expect(idx2.count == 2)
        #expect(TestSupport.fields(m2, idx2, row: 0) == ["a,b", "he said \"hi\""])
        #expect(TestSupport.fields(m2, idx2, row: 1) == ["line1\nline2", "plain"])
    }

    @Test func jsonIsValidAndOrdered() async throws {
        let (m, _) = try await TestSupport.buildIndex("name,age\nBob,30\nAlice,20\n", stride: 2)
        let url = tmpURL()
        let req = ExportEngine.Request(format: .json, columns: ["name", "age"], includeHeader: true,
                                       recordOffset: 1, rowCount: 2)
        try await ExportEngine().export(mapper: m, dialect: .default, request: req, to: url,
                                        onProgress: { _, _ in })
        let data = Data(try read(url).utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [[String: String]]
        #expect(obj?.count == 2)
        #expect(obj?[0] == ["name": "Bob", "age": "30"])
        #expect(obj?[1] == ["name": "Alice", "age": "20"])
    }

    @Test func jsonEmptyViewIsEmptyArray() async throws {
        let (m, _) = try await TestSupport.buildIndex("only,header\n", stride: 2)
        let url = tmpURL()
        let req = ExportEngine.Request(format: .json, columns: ["only", "header"], includeHeader: true,
                                       recordOffset: 1, rowCount: 0)
        try await ExportEngine().export(mapper: m, dialect: .default, request: req, to: url,
                                        onProgress: { _, _ in })
        let obj = try JSONSerialization.jsonObject(with: Data(try read(url).utf8)) as? [Any]
        #expect(obj?.isEmpty == true)
    }

    @Test func filteredSubsetExportsOnlyMatchingRowsInOrder() async throws {
        // header + Alice,Bob,Carol,Dave; simulate a filter that kept Carol & Alice.
        let (m, idx) = try await TestSupport.buildIndex(
            "name,city\nAlice,Tokyo\nBob,Paris\nCarol,Tokyo\nDave,Berlin\n", stride: 2)
        let url = tmpURL()
        let subset = [offset(m, idx, record: 3), offset(m, idx, record: 1)]   // Carol, Alice
        let req = ExportEngine.Request(format: .csv, columns: ["name", "city"], includeHeader: false,
                                       recordOffset: 1, rowCount: 4, subsetOffsets: subset)
        try await ExportEngine().export(mapper: m, dialect: .default, request: req, to: url,
                                        onProgress: { _, _ in })
        #expect(try read(url) == "Carol,Tokyo\nAlice,Tokyo\n")
    }

    @Test func sortPermutationReordersFullFile() async throws {
        let (m, _) = try await TestSupport.buildIndex("n\nC\nA\nB\n", stride: 2)
        let url = tmpURL()
        // Sort permutation over 3 rows: A(1), B(2), C(0).
        let req = ExportEngine.Request(format: .csv, columns: ["n"], includeHeader: false,
                                       recordOffset: 1, rowCount: 3, order: [1, 2, 0])
        try await ExportEngine().export(mapper: m, dialect: .default, request: req, to: url,
                                        onProgress: { _, _ in })
        #expect(try read(url) == "A\nB\nC\n")
    }

    @Test func filterPlusSortComposes() async throws {
        let (m, idx) = try await TestSupport.buildIndex(
            "name,age\nBob,30\nAlice,20\nCarol,25\nDave,40\n", stride: 2)
        let url = tmpURL()
        // Subset = Bob, Alice, Carol (records 1,2,3). Sort by age asc → Alice(20),Carol(25),Bob(30).
        let subset = [offset(m, idx, record: 1), offset(m, idx, record: 2), offset(m, idx, record: 3)]
        let order: [UInt32] = [1, 2, 0]   // subset-space: Alice, Carol, Bob
        let req = ExportEngine.Request(format: .csv, columns: ["name", "age"], includeHeader: true,
                                       recordOffset: 1, rowCount: 4, subsetOffsets: subset, order: order)
        try await ExportEngine().export(mapper: m, dialect: .default, request: req, to: url,
                                        onProgress: { _, _ in })
        #expect(try read(url) == "name,age\nAlice,20\nCarol,25\nBob,30\n")
    }

    @Test func progressReachesComplete() async throws {
        let (m, _) = try await TestSupport.buildIndex("a\n1\n2\n3\n", stride: 2)
        let url = tmpURL()
        final class Flag: @unchecked Sendable { var done = false }
        let flag = Flag()
        let req = ExportEngine.Request(format: .csv, columns: ["a"], includeHeader: false,
                                       recordOffset: 1, rowCount: 3)
        try await ExportEngine().export(mapper: m, dialect: .default, request: req, to: url,
                                        onProgress: { _, complete in if complete { flag.done = true } })
        _ = try read(url)
        #expect(flag.done)
    }
}
