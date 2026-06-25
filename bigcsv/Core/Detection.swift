import Foundation

/// Result of sniffing a file's start: which encoding/delimiter to use, and
/// whether the file is in an encoding we can't safely byte-index (UTF-16/32).
public nonisolated struct DetectionResult: Sendable, Equatable {
    public var dialect: CSVDialect
    /// Non-nil when the file is in an unsupported (multi-byte, non-UTF-8) encoding.
    public var unsupported: UnsupportedEncoding?

    public init(dialect: CSVDialect, unsupported: UnsupportedEncoding? = nil) {
        self.dialect = dialect
        self.unsupported = unsupported
    }
}

public nonisolated enum UnsupportedEncoding: String, Sendable, Equatable {
    case utf16LE = "UTF-16 (little-endian)"
    case utf16BE = "UTF-16 (big-endian)"
    case utf32LE = "UTF-32 (little-endian)"
    case utf32BE = "UTF-32 (big-endian)"
}

/// Sniffs encoding + delimiter from the first chunk of a file. Cheap: never reads
/// more than `sampleByteLimit` bytes, never the whole file.
public nonisolated enum Detector {

    /// How many leading bytes to sniff. 256 KB is plenty to see many rows.
    public static let sampleByteLimit = 256 * 1024

    public static func detect(_ bytes: UnsafeRawBufferPointer,
                              hasHeader: Bool = true) -> DetectionResult {
        // 1) Encoding (BOM first, then UTF-8 validity, then a UTF-16 NUL heuristic).
        let (encoding, bomLength, unsupported) = detectEncoding(bytes)
        if let unsupported {
            return DetectionResult(
                dialect: CSVDialect(delimiter: .comma, quote: 0x22,
                                    encoding: encoding, hasHeader: hasHeader),
                unsupported: unsupported)
        }

        // 2) Delimiter, scanning records after any BOM.
        let delimiter = detectDelimiter(bytes, scanStart: bomLength, quote: 0x22)

        return DetectionResult(
            dialect: CSVDialect(delimiter: delimiter, quote: 0x22,
                                encoding: encoding, hasHeader: hasHeader),
            unsupported: nil)
    }

    // MARK: Encoding

    /// Returns the encoding, the BOM byte length, and (if applicable) the
    /// unsupported multi-byte encoding we detected.
    public static func detectEncoding(_ bytes: UnsafeRawBufferPointer)
        -> (TextEncoding, Int, UnsupportedEncoding?) {
        let n = bytes.count

        // BOM sniff.
        if n >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            return (.utf8, 3, nil)
        }
        if n >= 4, bytes[0] == 0xFF, bytes[1] == 0xFE, bytes[2] == 0x00, bytes[3] == 0x00 {
            return (.utf8, 0, .utf32LE)
        }
        if n >= 4, bytes[0] == 0x00, bytes[1] == 0x00, bytes[2] == 0xFE, bytes[3] == 0xFF {
            return (.utf8, 0, .utf32BE)
        }
        if n >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE {
            return (.utf8, 0, .utf16LE)
        }
        if n >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
            return (.utf8, 0, .utf16BE)
        }

        // No BOM: a high density of NUL bytes signals UTF-16 without a BOM.
        let sample = min(n, sampleByteLimit)
        if sample >= 16 {
            var nuls = 0
            for i in 0..<sample where bytes[i] == 0x00 { nuls += 1 }
            if Double(nuls) / Double(sample) > 0.20 {
                // Even-index NULs => LE; odd-index => BE (rough but serviceable).
                var evenNuls = 0
                for i in stride(from: 0, to: sample, by: 2) where bytes[i] == 0x00 { evenNuls += 1 }
                return (.utf8, 0, evenNuls > nuls / 2 ? .utf16BE : .utf16LE)
            }
        }

        // Validate as UTF-8 (tolerating a sequence truncated at the sample edge).
        if isValidUTF8Prefix(bytes, limit: sampleByteLimit) {
            return (.utf8, 0, nil)
        }
        return (.windows1252, 0, nil)
    }

    /// Structural UTF-8 validation of the first `limit` bytes. A multi-byte
    /// sequence cut off at the end of the sample is accepted (not a real error).
    public static func isValidUTF8Prefix(_ bytes: UnsafeRawBufferPointer, limit: Int) -> Bool {
        let n = min(bytes.count, limit)
        var i = 0
        while i < n {
            let b = bytes[i]
            if b < 0x80 { i += 1; continue }
            let need: Int
            if b & 0xE0 == 0xC0 {
                if b < 0xC2 { return false }            // overlong 2-byte
                need = 1
            } else if b & 0xF0 == 0xE0 {
                need = 2
            } else if b & 0xF8 == 0xF0 {
                if b > 0xF4 { return false }             // > U+10FFFF
                need = 3
            } else {
                return false                              // stray continuation / invalid lead
            }
            var k = 1
            while k <= need {
                if i + k >= n { return true }             // truncated tail — accept
                if bytes[i + k] & 0xC0 != 0x80 { return false }
                k += 1
            }
            i += need + 1
        }
        return true
    }

    // MARK: Delimiter

    /// Choose the delimiter that yields the most fields, most consistently, across
    /// the first `sampleRecords` records.
    public static func detectDelimiter(_ bytes: UnsafeRawBufferPointer,
                                       scanStart: Int,
                                       quote: UInt8,
                                       sampleRecords: Int = 50) -> Delimiter {
        var best: Delimiter = .comma
        var bestScore = -1.0
        for candidate in Delimiter.allCases {
            let score = score(candidate, bytes: bytes, scanStart: scanStart,
                              quote: quote, sampleRecords: sampleRecords)
            if score > bestScore {
                bestScore = score
                best = candidate
            }
        }
        return best
    }

    private static func score(_ delimiter: Delimiter,
                              bytes: UnsafeRawBufferPointer,
                              scanStart: Int,
                              quote: UInt8,
                              sampleRecords: Int) -> Double {
        let n = bytes.count
        guard scanStart < n else { return -1 }
        let dialect = CSVDialect(delimiter: delimiter, quote: quote,
                                 encoding: .utf8, hasHeader: false)
        var counts: [Int] = []
        var pos = scanStart
        var r = 0
        while pos < n && r < sampleRecords {
            let next = RecordScanner.nextRecordStart(bytes, from: pos,
                                                     delimiter: delimiter.byte, quote: quote)
            let end = min(next, n)
            let record = UnsafeRawBufferPointer(rebasing: bytes[pos..<end])
            counts.append(CSVParser.parseRecord(record, dialect: dialect).count)
            r += 1
            if next >= n { break }
            pos = next
        }
        guard !counts.isEmpty else { return -1 }

        let average = Double(counts.reduce(0, +)) / Double(counts.count)
        if average <= 1.0 { return 0 }   // delimiter essentially absent

        // Reward consistency: fraction of records matching the modal field count.
        var histogram: [Int: Int] = [:]
        for c in counts { histogram[c, default: 0] += 1 }
        let modeCount = histogram.values.max() ?? 0
        let consistency = Double(modeCount) / Double(counts.count)
        return average * consistency
    }
}
