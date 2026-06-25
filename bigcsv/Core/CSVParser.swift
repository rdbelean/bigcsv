import Foundation

/// Parses a single record's bytes into its field strings.
///
/// Operates on the raw byte span of one record (as produced by `RecordIndex`),
/// honoring the same positional quote rules as `RecordScanner`, unescaping `""`,
/// trimming a trailing line terminator, and decoding each field with the
/// dialect's encoding. Ragged rows are fine — callers index columns defensively.
public nonisolated enum CSVParser {

    private static let lf: UInt8 = 0x0A
    private static let cr: UInt8 = 0x0D

    /// Parse the bytes of one record into fields.
    public static func parseRecord(_ record: UnsafeRawBufferPointer,
                                   dialect: CSVDialect) -> [String] {
        let delimiter = dialect.delimiter.byte
        let quote = dialect.quote

        // Logical end excluding a single trailing line terminator.
        var n = record.count
        if n > 0 && record[n - 1] == lf {
            n -= 1
            if n > 0 && record[n - 1] == cr { n -= 1 }   // CRLF
        } else if n > 0 && record[n - 1] == cr {
            n -= 1                                        // lone CR
        }

        var fields: [String] = []
        var field = [UInt8]()
        field.reserveCapacity(32)
        var i = 0
        var inQuotes = false
        var atFieldStart = true

        @inline(__always)
        func flush() {
            fields.append(decode(field, encoding: dialect.encoding))
            field.removeAll(keepingCapacity: true)
            atFieldStart = true
        }

        while i < n {
            let b = record[i]
            if inQuotes {
                if b == quote {
                    if i + 1 < n && record[i + 1] == quote {
                        field.append(quote)       // escaped "" -> "
                        i += 2
                        continue
                    }
                    inQuotes = false              // closing quote
                    i += 1
                    continue
                }
                field.append(b)
                i += 1
                continue
            } else {
                if atFieldStart && b == quote {
                    inQuotes = true               // opening quote at field start
                    atFieldStart = false
                    i += 1
                    continue
                }
                if b == delimiter {
                    flush()
                    i += 1
                    continue
                }
                atFieldStart = false
                field.append(b)                   // data (literal quote mid-field stays literal)
                i += 1
                continue
            }
        }
        flush()   // final field (also yields [""] for a blank record)
        return fields
    }

    /// Decode field bytes using the dialect's encoding, falling back to a lossy
    /// UTF-8 read so we never crash on malformed input.
    @inline(__always)
    static func decode(_ bytes: [UInt8], encoding: TextEncoding) -> String {
        switch encoding {
        case .utf8:
            return String(decoding: bytes, as: UTF8.self)
        case .windows1252:
            if let s = String(bytes: bytes, encoding: .windowsCP1252) {
                return s
            }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
