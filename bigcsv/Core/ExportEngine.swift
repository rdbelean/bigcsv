import Foundation

/// Streams the current view (filtered and/or sorted, or the whole file) to a CSV,
/// TSV, or JSON file — off-main, cancellable, with progress, and **without ever
/// holding the whole output in memory**.
///
/// Rows are parsed on demand from the mapped bytes and re-serialized into a small
/// reused byte buffer that is flushed to disk in chunks. Three enumeration modes,
/// chosen by the caller via `Request`:
///   * sequential — no filter, no sort: one forward record scan (fastest).
///   * subset offsets — a filter is active: iterate the matching rows' byte starts.
///   * permuted — a sort is active: iterate the sort permutation over either the
///     subset offsets (filter+sort) or a freshly collected offset table (sort only).
public nonisolated struct ExportEngine: Sendable {

    public enum Format: String, Sendable, CaseIterable { case csv, tsv, json }

    public enum ExportError: LocalizedError {
        case cannotCreateFile
        public var errorDescription: String? {
            switch self {
            case .cannotCreateFile: return "Couldn’t create the export file."
            }
        }
    }

    /// Everything the engine needs, all `Sendable` value types so it crosses the
    /// task boundary cleanly. `subsetOffsets`/`order` are the document's existing
    /// arrays (copy-on-write references — cheap to pass).
    public struct Request: Sendable {
        public var format: Format
        public var columns: [String]
        public var includeHeader: Bool
        /// File record index of display row 0 (1 with a header, else 0).
        public var recordOffset: Int
        /// Number of underlying display rows (used for the sequential scan + progress).
        public var rowCount: Int
        /// Filtered rows' byte starts in display order, or nil when unfiltered.
        public var subsetOffsets: [Int]?
        /// Sort permutation over the current row set (subset or full), or nil.
        public var order: [UInt32]?

        public init(format: Format, columns: [String], includeHeader: Bool,
                    recordOffset: Int, rowCount: Int,
                    subsetOffsets: [Int]? = nil, order: [UInt32]? = nil) {
            self.format = format
            self.columns = columns
            self.includeHeader = includeHeader
            self.recordOffset = recordOffset
            self.rowCount = rowCount
            self.subsetOffsets = subsetOffsets
            self.order = order
        }
    }

    public init() {}

    private static let flushThreshold = 256 * 1024

    public func export(mapper: FileMapper,
                       dialect: CSVDialect,
                       request: Request,
                       to url: URL,
                       onProgress: @Sendable (_ fraction: Double, _ isComplete: Bool) -> Void) async throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ExportError.cannotCreateFile
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        let bytes = mapper.bytes
        let n = bytes.count
        let srcDelimiter = dialect.delimiter.byte
        let quote = dialect.quote
        let outDelimiter: UInt8 = request.format == .tsv ? 0x09 : 0x2C   // tab vs comma (json ignores)
        let columns = request.columns
        let json = request.format == .json

        var out = [UInt8]()
        out.reserveCapacity(Self.flushThreshold + 64 * 1024)

        func flush(force: Bool) throws {
            if (force || out.count >= Self.flushThreshold), !out.isEmpty {
                try handle.write(contentsOf: Data(out))
                out.removeAll(keepingCapacity: true)
            }
        }

        // Resolve the ordered offset list (nil ⇒ pure sequential streaming).
        let orderedOffsets = try collectOrderedOffsets(request: request, bytes: bytes, n: n,
                                                        srcDelimiter: srcDelimiter, quote: quote)
        let total = orderedOffsets?.count ?? max(0, request.rowCount)

        // ── Preamble ─────────────────────────────────────────────────────────
        if json {
            out.append(0x5B); out.append(0x0A)                // "[\n"
        } else if request.includeHeader {
            Self.appendDelimitedRow(columns, delimiter: outDelimiter, into: &out)
        }

        var written = 0
        func emit(_ fields: [String]) throws {
            if json {
                if written > 0 { out.append(0x2C); out.append(0x0A) }   // ",\n"
                Self.appendJSONObject(fields, columns: columns, into: &out)
            } else {
                Self.appendDelimitedRow(fields, delimiter: outDelimiter, into: &out)
            }
            written += 1
            if written & 0x3FF == 0 {
                if Task.isCancelled { throw CancellationError() }
                onProgress(Double(written) / Double(max(1, total)), false)
            }
            try flush(force: false)   // cheap no-op until the buffer reaches the threshold
        }

        // ── Body ─────────────────────────────────────────────────────────────
        if let offsets = orderedOffsets {
            for off in offsets {
                if Task.isCancelled { throw CancellationError() }
                guard off >= 0, off < n else { try emit([]); continue }
                let next = RecordScanner.nextRecordStart(bytes, from: off, delimiter: srcDelimiter, quote: quote)
                try emit(CSVParser.parseRecord(
                    UnsafeRawBufferPointer(rebasing: bytes[off..<min(next, n)]), dialect: dialect))
            }
        } else {
            // Sequential: skip the BOM + header/leading records, then stream rowCount rows.
            var pos = RecordScanner.utf8BOMLength(bytes)
            var skipped = 0
            while skipped < request.recordOffset && pos < n {
                pos = RecordScanner.nextRecordStart(bytes, from: pos, delimiter: srcDelimiter, quote: quote)
                skipped += 1
            }
            var d = 0
            while pos < n && d < request.rowCount {
                if Task.isCancelled { throw CancellationError() }
                let next = RecordScanner.nextRecordStart(bytes, from: pos, delimiter: srcDelimiter, quote: quote)
                try emit(CSVParser.parseRecord(
                    UnsafeRawBufferPointer(rebasing: bytes[pos..<min(next, n)]), dialect: dialect))
                pos = next
                d += 1
            }
        }

        // ── Postamble ────────────────────────────────────────────────────────
        if json { out.append(0x0A); out.append(0x5D); out.append(0x0A) }   // "\n]\n"
        try flush(force: true)
        onProgress(1, true)
    }

    /// Builds the offset list to iterate, in display order, or nil for the pure
    /// sequential (unfiltered + unsorted) case. Cancellable.
    private func collectOrderedOffsets(request: Request,
                                       bytes: UnsafeRawBufferPointer, n: Int,
                                       srcDelimiter: UInt8, quote: UInt8) throws -> [Int]? {
        switch (request.subsetOffsets, request.order) {
        case (nil, nil):
            return nil                                            // sequential

        case let (subset?, order?):                               // filter + sort
            // One emitted row per displayed (filtered) position, mirroring
            // RowProjection exactly: position p → subset index `order[p]` (identity
            // for any tail beyond a short/raced permutation) → byte offset. An
            // out-of-range index yields -1, which the body turns into an empty row
            // rather than trapping.
            return (0..<subset.count).map { p in
                let i = p < order.count ? Int(order[p]) : p
                return i >= 0 && i < subset.count ? subset[i] : -1
            }

        case let (subset?, nil):                                  // filter only
            return subset

        case let (nil, order?):                                   // sort only — collect all offsets first
            var all = [Int](); all.reserveCapacity(request.rowCount)
            var pos = RecordScanner.utf8BOMLength(bytes)
            var skipped = 0
            while skipped < request.recordOffset && pos < n {
                pos = RecordScanner.nextRecordStart(bytes, from: pos, delimiter: srcDelimiter, quote: quote)
                skipped += 1
            }
            var d = 0
            while pos < n && d < request.rowCount {
                if Task.isCancelled { throw CancellationError() }
                all.append(pos)
                pos = RecordScanner.nextRecordStart(bytes, from: pos, delimiter: srcDelimiter, quote: quote)
                d += 1
            }
            // One emitted row per displayed position. Identity fallback for any tail
            // beyond a sort permutation that was taken before the index finished
            // growing — so the export matches exactly what the table shows.
            return (0..<all.count).map { p in
                let i = p < order.count ? Int(order[p]) : p
                return i >= 0 && i < all.count ? all[i] : -1
            }
        }
    }

    // MARK: Serialization (static + tested directly)

    /// Append one delimited row (CSV/TSV) followed by `\n`, quoting fields per
    /// RFC 4180: a field is quoted iff it contains the delimiter, a double quote,
    /// CR, or LF; embedded quotes are doubled.
    static func appendDelimitedRow(_ fields: [String], delimiter: UInt8, into out: inout [UInt8]) {
        for (i, field) in fields.enumerated() {
            if i > 0 { out.append(delimiter) }
            appendDelimitedField(field, delimiter: delimiter, into: &out)
        }
        out.append(0x0A)
    }

    static func appendDelimitedField(_ field: String, delimiter: UInt8, into out: inout [UInt8]) {
        var needsQuote = false
        for b in field.utf8 where b == delimiter || b == 0x22 || b == 0x0A || b == 0x0D {
            needsQuote = true; break
        }
        if !needsQuote {
            out.append(contentsOf: field.utf8)
            return
        }
        out.append(0x22)
        for b in field.utf8 {
            if b == 0x22 { out.append(0x22) }      // double an embedded quote
            out.append(b)
        }
        out.append(0x22)
    }

    /// Append one JSON object `{"col":"val",...}`. Values are always strings (CSV is
    /// untyped); keys are the column titles, with `Column N` for ragged extra fields.
    /// Keys are disambiguated within the object (`id`, `id_2`, …) so duplicate column
    /// titles — or a generated `Column N` colliding with a real one — never produce
    /// duplicate JSON keys (which every parser collapses, silently dropping data).
    static func appendJSONObject(_ fields: [String], columns: [String], into out: inout [UInt8]) {
        out.append(0x7B)                                          // {
        let count = max(fields.count, columns.count)
        var used = Set<String>(); used.reserveCapacity(count)
        for i in 0..<count {
            if i > 0 { out.append(0x2C) }                         // ,
            var key = (i < columns.count && !columns[i].isEmpty) ? columns[i] : "Column \(i + 1)"
            if used.contains(key) {
                var k = 2
                while used.contains("\(key)_\(k)") { k += 1 }
                key = "\(key)_\(k)"
            }
            used.insert(key)
            appendJSONString(key, into: &out)
            out.append(0x3A)                                      // :
            appendJSONString(i < fields.count ? fields[i] : "", into: &out)
        }
        out.append(0x7D)                                          // }
    }

    /// Append a JSON-escaped string literal (including the surrounding quotes).
    static func appendJSONString(_ s: String, into out: inout [UInt8]) {
        out.append(0x22)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out.append(0x5C); out.append(0x22)
            case "\\": out.append(0x5C); out.append(0x5C)
            case "\n": out.append(0x5C); out.append(0x6E)
            case "\r": out.append(0x5C); out.append(0x72)
            case "\t": out.append(0x5C); out.append(0x74)
            default:
                if scalar.value < 0x20 {
                    out.append(contentsOf: String(format: "\\u%04x", scalar.value).utf8)
                } else {
                    out.append(contentsOf: String(scalar).utf8)
                }
            }
        }
        out.append(0x22)
    }
}
