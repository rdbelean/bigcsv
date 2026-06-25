import Testing
import Foundation
@testable import BigCSVKit

@Suite("FileMapper")
struct FileMapperTests {

    @Test func mapsAndReadsKnownBytes() throws {
        let content = Array("Hello, BigCSV!".utf8)
        let url = try TestSupport.writeTempFile(content)
        defer { try? FileManager.default.removeItem(at: url) }

        let mapper = try FileMapper(url: url)
        #expect(mapper.count == content.count)

        let all = mapper.bytes
        #expect(Array(all) == content)

        let slice = mapper.bytes(in: 7..<13)   // "BigCSV"
        #expect(String(decoding: Array(slice), as: UTF8.self) == "BigCSV")
    }

    @Test func emptyFileMapsToZeroBytes() throws {
        let url = try TestSupport.writeTempFile([])
        defer { try? FileManager.default.removeItem(at: url) }

        let mapper = try FileMapper(url: url)
        #expect(mapper.count == 0)
        #expect(mapper.bytes.count == 0)
        #expect(mapper.bytes(in: 0..<0).count == 0)
    }

    @Test func openingMissingFileThrows() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("definitely-missing-\(UUID().uuidString).csv")
        #expect(throws: FileMapper.MapError.self) {
            _ = try FileMapper(url: url)
        }
    }

    @Test func deinitDoesNotCrash() throws {
        let url = try TestSupport.writeTempFile(Array("x".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let mapper = try FileMapper(url: url)
            _ = mapper.bytes
        }   // deinit (munmap + close) runs here
        #expect(Bool(true))
    }
}
