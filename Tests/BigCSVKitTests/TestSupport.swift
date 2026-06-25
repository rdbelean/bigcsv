import Foundation
@testable import BigCSVKit

enum TestSupport {

    /// Write bytes to a unique temp file and return its URL.
    static func writeTempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bigcsv-test-\(UUID().uuidString).csv")
        try Data(bytes).write(to: url)
        return url
    }

    static func writeTempFile(_ string: String) throws -> URL {
        try writeTempFile(Array(string.utf8))
    }

    /// Map content and build a fully-completed index over it. The backing temp
    /// file is unlinked after mapping (the mmap stays valid), so nothing leaks.
    static func buildIndex(_ bytes: [UInt8],
                           dialect: CSVDialect = .default,
                           stride: Int = 4) async throws -> (FileMapper, RecordIndex) {
        let url = try writeTempFile(bytes)
        let mapper = try FileMapper(url: url)
        try? FileManager.default.removeItem(at: url)   // mmap remains valid after unlink
        let index = RecordIndex(stride: stride)
        await LineIndexer().index(mapper, dialect: dialect, into: index, onProgress: { _ in })
        return (mapper, index)
    }

    static func buildIndex(_ string: String,
                           dialect: CSVDialect = .default,
                           stride: Int = 4) async throws -> (FileMapper, RecordIndex) {
        try await buildIndex(Array(string.utf8), dialect: dialect, stride: stride)
    }

    /// Resolve and parse one row.
    static func fields(_ mapper: FileMapper,
                       _ index: RecordIndex,
                       row: Int,
                       dialect: CSVDialect = .default) -> [String] {
        guard let range = index.byteRange(forRow: row, mapper: mapper, dialect: dialect) else {
            return []
        }
        return CSVParser.parseRecord(mapper.bytes(in: range), dialect: dialect)
    }

    /// Parse a record straight from a string (no file).
    static func parse(_ string: String, dialect: CSVDialect = .default) -> [String] {
        Array(string.utf8).withUnsafeBytes { CSVParser.parseRecord($0, dialect: dialect) }
    }

    /// Parse a record straight from raw bytes (no file) — for encoding tests.
    static func parse(_ bytes: [UInt8], dialect: CSVDialect = .default) -> [String] {
        bytes.withUnsafeBytes { CSVParser.parseRecord($0, dialect: dialect) }
    }
}
