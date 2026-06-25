import Foundation

/// Streaming, cancellable full-text search over the memory-mapped file.
///
/// Scans the raw bytes for the query (case-insensitive over ASCII by default,
/// exact for other bytes — so umlauts etc. match case-sensitively for now), maps
/// each byte hit back to its record via `RecordIndex`, and reports each matching
/// record once (records are non-decreasing as the byte scan moves forward).
public nonisolated struct SearchEngine: Sendable {

    public init() {}

    @inline(__always)
    private static func foldASCII(_ b: UInt8) -> UInt8 {
        (b >= 0x41 && b <= 0x5A) ? b + 0x20 : b      // A–Z → a–z
    }

    /// Find the first index of `query` in `bytes` at or after `start`.
    static func firstIndex(of query: [UInt8],
                           in bytes: UnsafeRawBufferPointer,
                           from start: Int,
                           caseSensitive: Bool) -> Int? {
        let n = bytes.count
        let m = query.count
        guard m > 0, n >= m, start <= n - m else { return nil }
        let first = query[0]
        var i = start
        while i <= n - m {
            // Fast-forward to a position whose first byte can match.
            if caseSensitive {
                if bytes[i] != first { i += 1; continue }
            } else {
                if foldASCII(bytes[i]) != first { i += 1; continue }
            }
            var j = 1
            while j < m {
                let a = bytes[i + j]
                let match = caseSensitive ? (a == query[j]) : (foldASCII(a) == query[j])
                if !match { break }
                j += 1
            }
            if j == m { return i }
            i += 1
        }
        return nil
    }

    /// Search the whole file. `onMatch` is called once per matching record (row),
    /// in increasing order; `onProgress` is called periodically and once at the
    /// end with `isComplete == true`. Honors task cancellation.
    public func search(mapper: FileMapper,
                       index: RecordIndex,
                       dialect: CSVDialect,
                       query: String,
                       caseSensitive: Bool,
                       onMatch: @Sendable (Int) -> Void,
                       onProgress: @Sendable (_ matches: Int, _ fraction: Double, _ isComplete: Bool) -> Void) async {
        let needle: [UInt8] = caseSensitive ? Array(query.utf8) : Array(query.lowercased().utf8)
        let bytes = mapper.bytes
        let n = bytes.count
        guard !needle.isEmpty, n >= needle.count else {
            onProgress(0, 1, true)
            return
        }

        var pos = 0
        var lastRow = -1
        var matches = 0
        var scanned = 0

        while pos <= n - needle.count {
            if Task.isCancelled { onProgress(matches, Double(pos) / Double(n), false); return }
            guard let hit = SearchEngine.firstIndex(of: needle, in: bytes, from: pos,
                                                    caseSensitive: caseSensitive) else { break }
            let row = index.row(forByteOffset: hit, mapper: mapper, dialect: dialect)
            if row != lastRow {
                lastRow = row
                matches += 1
                onMatch(row)
            }
            pos = hit + needle.count
            scanned += 1
            if scanned & 0x3FF == 0 { await Task.yield() }            // stay cancellable
            if scanned & 0x3FFF == 0 { onProgress(matches, Double(hit) / Double(n), false) }
        }
        onProgress(matches, 1, true)
    }
}
