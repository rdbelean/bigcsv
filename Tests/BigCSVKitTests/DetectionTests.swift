import Testing
import Foundation
@testable import BigCSVKit

@Suite("Detection")
struct DetectionTests {

    private func detect(_ bytes: [UInt8]) -> DetectionResult {
        bytes.withUnsafeBytes { Detector.detect($0) }
    }
    private func detect(_ string: String) -> DetectionResult {
        detect(Array(string.utf8))
    }

    // MARK: Delimiter

    @Test func detectsComma() {
        #expect(detect("a,b,c\nd,e,f\ng,h,i\n").dialect.delimiter == .comma)
    }

    @Test func detectsSemicolon() {
        #expect(detect("a;b;c\nd;e;f\ng;h;i\n").dialect.delimiter == .semicolon)
    }

    @Test func detectsTab() {
        #expect(detect("a\tb\tc\nd\te\tf\n").dialect.delimiter == .tab)
    }

    @Test func detectsPipe() {
        #expect(detect("a|b|c\nd|e|f\n").dialect.delimiter == .pipe)
    }

    @Test func semicolonWinsWhenDataContainsCommas() {
        // European style: ';' separates, ',' is a decimal point inside values.
        let r = detect("name;value\nAlice;1,5\nBob;2,5\nCarol;3,25\n")
        #expect(r.dialect.delimiter == .semicolon)
    }

    @Test func singleColumnFallsBackToComma() {
        #expect(detect("alpha\nbeta\ngamma\n").dialect.delimiter == .comma)
    }

    // MARK: Encoding

    @Test func plainASCIIIsUTF8() {
        let r = detect("a,b,c\n")
        #expect(r.dialect.encoding == .utf8)
        #expect(r.unsupported == nil)
    }

    @Test func utf8BOMDetected() {
        var bytes: [UInt8] = [0xEF, 0xBB, 0xBF]
        bytes.append(contentsOf: Array("a,b\n".utf8))
        let (enc, bom, unsupported) = bytes.withUnsafeBytes { Detector.detectEncoding($0) }
        #expect(enc == .utf8)
        #expect(bom == 3)
        #expect(unsupported == nil)
    }

    @Test func validUTF8MultibyteStaysUTF8() {
        #expect(detect("café,Zürich,naïve\n").dialect.encoding == .utf8)
    }

    @Test func windows1252FallbackForInvalidUTF8() {
        // "café,x\n" with é as a lone 0xE9 (valid Win-1252, invalid UTF-8).
        let bytes: [UInt8] = [0x63, 0x61, 0x66, 0xE9, 0x2C, 0x78, 0x0A]
        #expect(detect(bytes).dialect.encoding == .windows1252)
    }

    @Test func utf16LEBOMIsUnsupported() {
        let bytes: [UInt8] = [0xFF, 0xFE, 0x61, 0x00, 0x2C, 0x00]
        #expect(detect(bytes).unsupported == .utf16LE)
    }

    @Test func utf16BEBOMIsUnsupported() {
        let bytes: [UInt8] = [0xFE, 0xFF, 0x00, 0x61, 0x00, 0x2C]
        #expect(detect(bytes).unsupported == .utf16BE)
    }

    @Test func utf16WithoutBOMDetectedByNULs() {
        // "a,b\n" as UTF-16LE without BOM: lots of 0x00 high bytes.
        let bytes: [UInt8] = [0x61, 0x00, 0x2C, 0x00, 0x62, 0x00, 0x0A, 0x00,
                              0x63, 0x00, 0x2C, 0x00, 0x64, 0x00, 0x0A, 0x00]
        #expect(detect(bytes).unsupported != nil)
    }

    @Test func truncatedMultibyteTailIsAccepted() {
        // "é" is C3 A9; cut after C3 — a truncated tail must not fail validation.
        let bytes: [UInt8] = [0x61, 0x2C, 0xC3]
        #expect(bytes.withUnsafeBytes { Detector.isValidUTF8Prefix($0, limit: bytes.count) })
    }
}
