import Foundation

/// Writes the current view to a real `.xlsx` workbook **by hand — zero third-party
/// dependencies**. An XLSX is a ZIP (OOXML SpreadsheetML) of a few XML parts; we
/// stream the big worksheet part to a temp file (flat memory), then assemble a
/// valid ZIP using STORED (uncompressed) entries with correct CRC-32s, so Excel,
/// Numbers, and LibreOffice all open it.
///
/// Excel's hard sheet limits (1,048,576 rows × 16,384 columns) cap the export; rows
/// beyond the limit are dropped and `Result.truncated` is set so the UI can warn.
/// Cells that parse as numbers are written as real numbers; everything else is an
/// inline string (preserving exact text, including zero-prefixed codes like "007").
public nonisolated struct XLSXExporter: Sendable {

    public static let maxRows = 1_048_576       // Excel's hard row limit (incl. header)
    public static let maxColumns = 16_384       // Excel's hard column limit

    public struct Result: Sendable {
        public var rowsWritten: Int
        public var truncated: Bool
    }

    public enum XLSXError: LocalizedError {
        case cannotCreateFile
        case tooLargeForXLSX
        public var errorDescription: String? {
            switch self {
            case .cannotCreateFile: return "Couldn’t create the export file."
            case .tooLargeForXLSX:
                return "This view is too large for the .xlsx format. Export as CSV instead."
            }
        }
    }

    public init() {}

    private static let flushThreshold = 256 * 1024

    public func export(source: ExportRowSource,
                       columns: [String],
                       includeHeader: Bool,
                       to url: URL,
                       onProgress: @Sendable (_ fraction: Double, _ isComplete: Bool) -> Void) async throws -> Result {
        // 1) Stream the worksheet XML to a temp file, computing its CRC-32 + size.
        let sheetTmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bigcsv-sheet-\(UUID().uuidString).xml")
        defer { try? FileManager.default.removeItem(at: sheetTmp) }

        let sheet = try await streamWorksheet(source: source, columns: columns,
                                              includeHeader: includeHeader, to: sheetTmp,
                                              onProgress: onProgress)

        // 2) Assemble the .xlsx (ZIP). Small parts are built in memory; the worksheet
        //    is copied in from the temp file. STORED entries → size must fit UInt32.
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw XLSXError.cannotCreateFile
        }
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        let zip = ZipWriter(handle: out)

        try zip.addStored(name: "[Content_Types].xml", data: Self.contentTypesXML)
        try zip.addStored(name: "_rels/.rels", data: Self.rootRelsXML)
        try zip.addStored(name: "xl/workbook.xml", data: Self.workbookXML)
        try zip.addStored(name: "xl/_rels/workbook.xml.rels", data: Self.workbookRelsXML)
        try zip.addStored(name: "xl/styles.xml", data: Self.stylesXML)
        try zip.addStoredFromFile(name: "xl/worksheets/sheet1.xml",
                                  fileURL: sheetTmp, crc: sheet.crc, size: sheet.size)
        try zip.finish()

        onProgress(1, true)
        return Result(rowsWritten: sheet.rowsWritten, truncated: sheet.truncated)
    }

    // MARK: Worksheet streaming

    private struct SheetInfo { var crc: UInt32; var size: Int; var rowsWritten: Int; var truncated: Bool }
    private struct StopIteration: Error {}

    private func streamWorksheet(source: ExportRowSource, columns: [String], includeHeader: Bool,
                                 to url: URL,
                                 onProgress: @Sendable (Double, Bool) -> Void) async throws -> SheetInfo {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw XLSXError.cannotCreateFile
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var out = [UInt8](); out.reserveCapacity(Self.flushThreshold + 64 * 1024)
        var crc = CRC32()
        var totalSize = 0

        func flush(force: Bool) throws {
            if (force || out.count >= Self.flushThreshold), !out.isEmpty {
                crc.update(out)
                totalSize += out.count
                try handle.write(contentsOf: Data(out))
                out.removeAll(keepingCapacity: true)
            }
        }

        out.append(contentsOf: Self.sheetPrefix)

        // Precompute column-letter prefixes ("A","B",…,"AA"), capped at Excel's limit.
        let colCap = min(max(columns.count, 1), Self.maxColumns)
        var colLetters = (0..<max(colCap, 1)).map { Self.columnLetters($0) }

        let dataCap = Self.maxRows - (includeHeader ? 1 : 0)
        var truncated = source.displayCount > dataCap
        var emitted = 0           // data rows written
        var sheetRow = 0          // 1-based row number in the sheet

        func ensureColumnLetters(_ count: Int) {
            while colLetters.count < count { colLetters.append(Self.columnLetters(colLetters.count)) }
        }

        func writeRow(_ fields: [String]) {
            sheetRow += 1
            out.append(contentsOf: Self.rowOpen)                       // <row r="
            out.append(contentsOf: Self.ascii(sheetRow))
            out.append(contentsOf: Self.rowOpenClose)                  // ">
            let cols = min(fields.count, Self.maxColumns)
            if fields.count > Self.maxColumns { truncated = true }
            if cols > colLetters.count { ensureColumnLetters(cols) }
            for c in 0..<cols {
                let field = fields[c]
                if field.isEmpty { continue }                          // blank cell → omit
                Self.appendCell(field, colRef: colLetters[c], rowDigits: Self.ascii(sheetRow), into: &out)
            }
            out.append(contentsOf: Self.rowClose)                      // </row>
        }

        // Header row (column titles, always text).
        if includeHeader {
            writeRow(columns)
            try flush(force: false)
        }

        do {
            try await source.forEach { _, fields in
                if emitted >= dataCap { truncated = true; throw StopIteration() }
                writeRow(fields)
                emitted += 1
                if emitted & 0x3FF == 0 {
                    onProgress(Double(emitted) / Double(max(1, min(source.displayCount, dataCap))), false)
                }
                try flush(force: false)
            }
        } catch is StopIteration {
            // hit the row cap — stop cleanly, truncated already set
        }

        out.append(contentsOf: Self.sheetSuffix)
        try flush(force: true)

        if totalSize > Int(UInt32.max) { throw XLSXError.tooLargeForXLSX }
        return SheetInfo(crc: crc.value, size: totalSize, rowsWritten: emitted, truncated: truncated)
    }

    // MARK: Cell serialization

    /// `<c r="A1"><v>123</v></c>` for numbers, else
    /// `<c r="A1" t="inlineStr"><is><t xml:space="preserve">text</t></is></c>`.
    static func appendCell(_ field: String, colRef: [UInt8], rowDigits: [UInt8], into out: inout [UInt8]) {
        out.append(0x3C); out.append(0x63)                            // <c
        out.append(contentsOf: cellRefAttr)                           //  r="
        out.append(contentsOf: colRef)
        out.append(contentsOf: rowDigits)
        out.append(0x22)                                              // "
        if let number = numericLiteral(field) {
            out.append(0x3E)                                          // >
            out.append(contentsOf: vOpen)                             // <v>
            out.append(contentsOf: number.utf8)
            out.append(contentsOf: vCloseCClose)                      // </v></c>
        } else {
            out.append(contentsOf: inlineStrOpen)                     //  t="inlineStr"><is><t xml:space="preserve">
            appendXMLText(field, into: &out)
            out.append(contentsOf: inlineStrClose)                    // </t></is></c>
        }
    }

    /// Returns the numeric `<v>` literal for a field that should be a number, or nil
    /// (→ inline string). Zero-prefixed codes ("007") stay text. US-format numbers
    /// keep their exact text; European/other parse via the shared locale-aware logic.
    static func numericLiteral(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let u = Array(t.utf8)
        if u.count >= 2, u[0] == 0x30, u[1] >= 0x30, u[1] <= 0x39 { return nil }   // 0 then digit
        if isXSDDouble(u) { return t }                              // already a clean number literal
        return europeanNumber(t)                                    // strict locale-grouped form, or nil
    }

    /// Strictly validates a European-formatted number (`1.234.567,89`, `1,5`) and
    /// returns its normalized US literal, or nil. Strict on purpose — unlike the
    /// lenient sort/filter parser — so ambiguous tokens (version strings, IDs like
    /// "1.2.3") are never silently mangled into numbers on export.
    static func europeanNumber(_ t: String) -> String? {
        var body = Substring(t)
        var sign = ""
        if let f = body.first, f == "+" || f == "-" {
            if f == "-" { sign = "-" }
            body = body.dropFirst()
        }
        guard !body.isEmpty else { return nil }
        let parts = body.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let intPart = parts[0]
        let frac = parts.count == 2 ? parts[1] : nil
        if let frac { guard !frac.isEmpty, frac.allSatisfy(\.isASCIIDigit) else { return nil } }
        guard isValidGroupedInteger(intPart) else { return nil }
        let intDigits = intPart.filter { $0 != "." }
        guard !intDigits.isEmpty else { return nil }
        return sign + intDigits + (frac.map { "." + $0 } ?? "")
    }

    /// True if `s` is plain digits, or dot-grouped thousands (`1`, `12`, `1.234.567`).
    static func isValidGroupedInteger(_ s: Substring) -> Bool {
        if !s.contains(".") { return !s.isEmpty && s.allSatisfy(\.isASCIIDigit) }
        let groups = s.split(separator: ".", omittingEmptySubsequences: false)
        guard groups.count >= 2 else { return false }
        for (i, g) in groups.enumerated() {
            guard !g.isEmpty, g.allSatisfy(\.isASCIIDigit) else { return false }
            if i == 0 { guard (1...3).contains(g.count) else { return false } }
            else { guard g.count == 3 else { return false } }
        }
        return true
    }

    /// True if the UTF-8 bytes are a valid XML-schema double: optional sign, digits,
    /// optional fraction, optional exponent — and at least one digit.
    static func isXSDDouble(_ u: [UInt8]) -> Bool {
        var i = 0; let n = u.count
        func digit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
        if i < n, u[i] == 0x2B || u[i] == 0x2D { i += 1 }           // + / -
        var sawDigit = false
        while i < n, digit(u[i]) { i += 1; sawDigit = true }
        if i < n, u[i] == 0x2E {                                    // .
            i += 1
            while i < n, digit(u[i]) { i += 1; sawDigit = true }
        }
        if !sawDigit { return false }
        if i < n, u[i] == 0x65 || u[i] == 0x45 {                    // e / E
            i += 1
            if i < n, u[i] == 0x2B || u[i] == 0x2D { i += 1 }
            var expDigit = false
            while i < n, digit(u[i]) { i += 1; expDigit = true }
            if !expDigit { return false }
        }
        return i == n
    }

    /// Append text into a `<t>` body, escaping `& < >` and dropping characters XML 1.0
    /// forbids entirely (control chars except tab/newline/CR can't be represented).
    static func appendXMLText(_ s: String, into out: inout [UInt8]) {
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out.append(contentsOf: "&amp;".utf8)
            case "<": out.append(contentsOf: "&lt;".utf8)
            case ">": out.append(contentsOf: "&gt;".utf8)
            default:
                let v = scalar.value
                if v == 0x09 || v == 0x0A || v == 0x0D || (v >= 0x20 && v != 0xFFFE && v != 0xFFFF) {
                    out.append(contentsOf: String(scalar).utf8)
                }
                // else: control char illegal in XML 1.0 → drop
            }
        }
    }

    /// 0-based column index → uppercase letters ("A", …, "Z", "AA", …) as UTF-8.
    static func columnLetters(_ index: Int) -> [UInt8] {
        var n = index, out = [UInt8]()
        repeat {
            out.append(UInt8(0x41 + n % 26))
            n = n / 26 - 1
        } while n >= 0
        return out.reversed()
    }

    /// Decimal ASCII digits of a non-negative integer.
    static func ascii(_ value: Int) -> [UInt8] { Array(String(value).utf8) }

    // MARK: Static XML fragments (UTF-8)

    private static let cellRefAttr = Array(" r=\"".utf8)
    private static let vOpen = Array("<v>".utf8)
    private static let vCloseCClose = Array("</v></c>".utf8)
    private static let inlineStrOpen = Array(" t=\"inlineStr\"><is><t xml:space=\"preserve\">".utf8)
    private static let inlineStrClose = Array("</t></is></c>".utf8)
    private static let rowOpen = Array("<row r=\"".utf8)
    private static let rowOpenClose = Array("\">".utf8)
    private static let rowClose = Array("</row>".utf8)

    private static let sheetPrefix = Array((
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
        + "<sheetData>").utf8)
    private static let sheetSuffix = Array("</sheetData></worksheet>".utf8)

    private static let contentTypesXML = Array((
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        + "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
        + "<Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        + "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
        + "</Types>").utf8)

    private static let rootRelsXML = Array((
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>"
        + "</Relationships>").utf8)

    private static let workbookXML = Array((
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        + "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" "
        + "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
        + "<sheets><sheet name=\"Sheet1\" sheetId=\"1\" r:id=\"rId1\"/></sheets>"
        + "</workbook>").utf8)

    private static let workbookRelsXML = Array((
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/>"
        + "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        + "</Relationships>").utf8)

    private static let stylesXML = Array((
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        + "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
        + "<fonts count=\"1\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts>"
        + "<fills count=\"1\"><fill><patternFill patternType=\"none\"/></fill></fills>"
        + "<borders count=\"1\"><border/></borders>"
        + "<cellStyleXfs count=\"1\"><xf/></cellStyleXfs>"
        + "<cellXfs count=\"1\"><xf/></cellXfs>"
        + "</styleSheet>").utf8)
}

private extension Character {
    /// True for an ASCII digit 0–9 (excludes non-ASCII numerals `Character.isNumber` accepts).
    var isASCIIDigit: Bool {
        guard let a = asciiValue else { return false }
        return a >= 0x30 && a <= 0x39
    }
}
