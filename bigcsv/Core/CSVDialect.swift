import Foundation

/// A column delimiter. We support the four that cover virtually all real-world
/// CSV/TSV exports.
public nonisolated enum Delimiter: String, Sendable, Equatable, CaseIterable, Codable {
    case comma
    case semicolon
    case tab
    case pipe

    public var byte: UInt8 {
        switch self {
        case .comma: return 0x2C      // ,
        case .semicolon: return 0x3B  // ;
        case .tab: return 0x09        // \t
        case .pipe: return 0x7C       // |
        }
    }

    public var displayName: String {
        switch self {
        case .comma: return "Comma"
        case .semicolon: return "Semicolon"
        case .tab: return "Tab"
        case .pipe: return "Pipe"
        }
    }

    public var displaySymbol: String {
        switch self {
        case .comma: return ","
        case .semicolon: return ";"
        case .tab: return "\\t"
        case .pipe: return "|"
        }
    }
}

/// Text encoding for decoding field bytes. UTF-8 is self-synchronizing so the
/// byte-offset index is correct for it and for any single-byte encoding;
/// Windows-1252 is our fallback for "dirty" Latin-1 files. UTF-16/32 are
/// detected elsewhere and reported as unsupported (they break the byte model).
public nonisolated enum TextEncoding: String, Sendable, Equatable, CaseIterable, Codable {
    case utf8
    case windows1252

    public var stringEncoding: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .windows1252: return .windowsCP1252
        }
    }

    public var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .windows1252: return "Windows-1252"
        }
    }
}

/// Everything needed to interpret the bytes of a CSV/TSV file: how fields are
/// separated, the quote character, the text encoding, and whether the first
/// record is a header row.
public nonisolated struct CSVDialect: Sendable, Equatable, Codable {
    public var delimiter: Delimiter
    public var quote: UInt8
    public var encoding: TextEncoding
    public var hasHeader: Bool

    public init(delimiter: Delimiter = .comma,
                quote: UInt8 = 0x22,
                encoding: TextEncoding = .utf8,
                hasHeader: Bool = true) {
        self.delimiter = delimiter
        self.quote = quote
        self.encoding = encoding
        self.hasHeader = hasHeader
    }

    /// A neutral default used before detection runs (comma, double-quote, UTF-8, header).
    public static let `default` = CSVDialect()
}
