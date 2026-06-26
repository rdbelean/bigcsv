import Foundation

/// Streams the display rows that match a `FilterSet`, off-main and cancellable.
///
/// Makes ONE sequential pass over the mapped bytes (the same record-boundary walk
/// the indexer uses), parsing each row and testing the filter. This is O(file
/// size) — crucially NOT `index.byteRange(forRow:)` per row, which re-scans from
/// the nearest checkpoint every call and is quadratic over a full sequential scan.
public nonisolated struct FilterEngine: Sendable {

    public init() {}

    public func filter(mapper: FileMapper,
                       dialect: CSVDialect,
                       filterSet: FilterSet,
                       recordOffset: Int,
                       rowCount: Int,
                       onMatch: @Sendable (_ displayRow: UInt32, _ byteOffset: Int) -> Void,
                       onProgress: @Sendable (_ matches: Int, _ fraction: Double, _ isComplete: Bool) -> Void) async {
        guard !filterSet.isEmpty, rowCount > 0 else {
            onProgress(0, 1, true)
            return
        }
        let bytes = mapper.bytes
        let n = bytes.count
        let delimiter = dialect.delimiter.byte
        let quote = dialect.quote

        // Skip the BOM and any header / leading records.
        var pos = RecordScanner.utf8BOMLength(bytes)
        var skipped = 0
        while skipped < recordOffset && pos < n {
            pos = RecordScanner.nextRecordStart(bytes, from: pos, delimiter: delimiter, quote: quote)
            skipped += 1
        }

        var matches = 0
        var d = 0
        while pos < n && d < rowCount {
            if Task.isCancelled {
                onProgress(matches, Double(d) / Double(rowCount), false)
                return
            }
            let next = RecordScanner.nextRecordStart(bytes, from: pos, delimiter: delimiter, quote: quote)
            let record = UnsafeRawBufferPointer(rebasing: bytes[pos..<min(next, n)])
            if filterSet.matches(CSVParser.parseRecord(record, dialect: dialect)) {
                matches += 1
                onMatch(UInt32(d), pos)         // pos = this record's byte start
            }
            pos = next
            d += 1
            if d & 0x3FFF == 0 {
                onProgress(matches, Double(d) / Double(rowCount), false)
                await Task.yield()
            }
        }
        onProgress(matches, 1, true)
    }
}
