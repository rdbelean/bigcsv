import Foundation

/// Low-level, quote-aware byte scanning shared by `LineIndexer` (finding record
/// boundaries) and `RecordIndex` (resolving a row to its byte range).
///
/// The CSV quote rules implemented here are *positional* and match what Excel /
/// RFC 4180 actually do:
///   * A quote byte opens a quoted field ONLY at the start of a field
///     (record start, or immediately after a delimiter). A quote elsewhere is a
///     literal data byte.
///   * Inside a quoted field, two consecutive quotes (`""`) are an escaped quote
///     and stay inside the field.
///   * A newline (`\n`, `\r`, or `\r\n`) ends a record ONLY when not inside a
///     quoted field; inside quotes it is data.
public nonisolated enum RecordScanner {

    static let lf: UInt8 = 0x0A   // \n
    static let cr: UInt8 = 0x0D   // \r

    /// Number of leading bytes occupied by a UTF-8 BOM (0 if none).
    /// (UTF-16/32 BOMs are detected by `EncodingDetector`, not here.)
    public static func utf8BOMLength(_ bytes: UnsafeRawBufferPointer) -> Int {
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            return 3
        }
        return 0
    }

    /// Given a record that starts at `start` (which must be a true record start —
    /// outside quotes, at a field boundary), return the byte offset where the
    /// NEXT record starts. Returns `bytes.count` when the record at `start` is the
    /// last record in the file (no trailing record).
    @inline(__always)
    public static func nextRecordStart(_ bytes: UnsafeRawBufferPointer,
                                       from start: Int,
                                       delimiter: UInt8,
                                       quote: UInt8) -> Int {
        let n = bytes.count
        var k = start
        var inQuotes = false
        var atFieldStart = true

        while k < n {
            let b = bytes[k]
            if inQuotes {
                if b == quote {
                    if k + 1 < n && bytes[k + 1] == quote {
                        k += 2            // escaped "" inside quotes
                        continue
                    }
                    inQuotes = false      // closing quote
                    atFieldStart = false
                    k += 1
                    continue
                }
                k += 1                    // data (including newlines) inside quotes
                continue
            } else {
                if atFieldStart && b == quote {
                    inQuotes = true       // opening quote at field start
                    atFieldStart = false
                    k += 1
                    continue
                }
                if b == delimiter {
                    atFieldStart = true
                    k += 1
                    continue
                }
                if b == lf {
                    return k + 1
                }
                if b == cr {
                    if k + 1 < n && bytes[k + 1] == lf { return k + 2 }  // CRLF
                    return k + 1                                         // lone CR
                }
                atFieldStart = false
                k += 1
                continue
            }
        }
        return n
    }
}
