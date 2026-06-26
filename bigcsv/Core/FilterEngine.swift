import Foundation

/// Streams the display rows that match a `FilterSet`, off-main and cancellable.
///
/// Parses each row on demand through the same byteRange path the table uses,
/// reports matching ORIGINAL display rows (`UInt32`, ascending) via `onMatch`,
/// and progress via `onProgress`. The document accumulates the matches into the
/// `RowProjection.base` subset.
public nonisolated struct FilterEngine: Sendable {

    public init() {}

    public func filter(mapper: FileMapper,
                       index: RecordIndex,
                       dialect: CSVDialect,
                       filterSet: FilterSet,
                       recordOffset: Int,
                       rowCount: Int,
                       onMatch: @Sendable (UInt32) -> Void,
                       onProgress: @Sendable (_ matches: Int, _ fraction: Double, _ isComplete: Bool) -> Void) async {
        guard !filterSet.isEmpty, rowCount > 0 else {
            onProgress(0, 1, true)
            return
        }
        var matches = 0
        for d in 0..<rowCount {
            if Task.isCancelled {
                onProgress(matches, Double(d) / Double(rowCount), false)
                return
            }
            let record = recordOffset + d
            if let range = index.byteRange(forRow: record, mapper: mapper, dialect: dialect) {
                let fields = CSVParser.parseRecord(mapper.bytes(in: range), dialect: dialect)
                if filterSet.matches(fields) {
                    matches += 1
                    onMatch(UInt32(d))
                }
            }
            if d & 0x3FFF == 0 {
                onProgress(matches, Double(d) / Double(rowCount), false)
                await Task.yield()
            }
        }
        onProgress(matches, 1, true)
    }
}
