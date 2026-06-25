import Foundation

/// A sparse, growable index of record (row) start offsets.
///
/// Instead of storing one offset per row (8 bytes/row → hundreds of MB on huge
/// files), we store a "checkpoint" offset every `stride` records plus the total
/// count. Any row is resolved by seeking the nearest checkpoint and re-scanning
/// that ~`stride`-record block from the memory-mapped bytes (microseconds, since
/// the bytes are already page-resident).
///
/// `@unchecked Sendable`: the background `LineIndexer` appends checkpoints while
/// the main thread resolves rows; all shared mutable state is guarded by `lock`.
public nonisolated final class RecordIndex: @unchecked Sendable {

    /// Records between checkpoints. 1024 keeps checkpoint memory tiny
    /// (~8 bytes per 1024 rows) while bounding any single resolve scan.
    public let stride: Int

    private let lock = NSLock()
    private var checkpoints: [Int] = []   // checkpoints[c] = byte offset of record c*stride
    private var _count = 0
    private var _endOffset = 0
    private var _complete = false

    public init(stride: Int = 1024) {
        precondition(stride > 0)
        self.stride = stride
    }

    // MARK: Builder API (called off-main by LineIndexer)

    /// Append the start offset of record `c*stride` (the indexer calls this for
    /// record indices that are exact multiples of `stride`).
    func appendCheckpoint(_ offset: Int) {
        lock.lock(); defer { lock.unlock() }
        checkpoints.append(offset)
    }

    /// Publish the count of fully-bounded rows discovered so far.
    func publish(count: Int, endOffset: Int) {
        lock.lock(); defer { lock.unlock() }
        _count = count
        _endOffset = endOffset
    }

    /// Mark indexing finished with the final totals.
    func markComplete(count: Int, endOffset: Int) {
        lock.lock(); defer { lock.unlock() }
        _count = count
        _endOffset = endOffset
        _complete = true
    }

    // MARK: Consumer API (main thread)

    /// Number of rows currently available to display.
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return _count
    }

    /// True once the whole file has been indexed.
    public var isComplete: Bool {
        lock.lock(); defer { lock.unlock() }
        return _complete
    }

    public var endOffset: Int {
        lock.lock(); defer { lock.unlock() }
        return _endOffset
    }

    /// Byte range of a single row, resolved against `mapper`'s bytes.
    public func byteRange(forRow row: Int,
                          mapper: FileMapper,
                          dialect: CSVDialect) -> Range<Int>? {
        byteRanges(forRows: row..<(row + 1), mapper: mapper, dialect: dialect).first
    }

    /// Byte ranges for a contiguous range of rows, resolved in a SINGLE scan from
    /// the nearest checkpoint. The table always asks for a contiguous visible
    /// window, so this is O(stride + window), not O(window · stride).
    public func byteRanges(forRows rows: Range<Int>,
                           mapper: FileMapper,
                           dialect: CSVDialect) -> [Range<Int>] {
        // Snapshot the shared state we need under the lock.
        lock.lock()
        let total = _count
        let end = _endOffset
        let checkpointForFirst: Int
        let firstCheckpointIndex = rows.lowerBound / stride
        if rows.isEmpty || rows.lowerBound < 0 || rows.lowerBound >= total
            || firstCheckpointIndex >= checkpoints.count {
            lock.unlock()
            return []
        }
        checkpointForFirst = checkpoints[firstCheckpointIndex]
        lock.unlock()

        let upper = min(rows.upperBound, total)
        guard upper > rows.lowerBound else { return [] }

        let bytes = mapper.bytes
        let delim = dialect.delimiter.byte
        let quote = dialect.quote

        // Scan forward from the checkpoint, collecting record-start offsets.
        // We need starts for rows [lowerBound ... upper] (one extra for the end
        // of the last requested row).
        var current = checkpointForFirst
        var recordIndex = firstCheckpointIndex * stride

        // Skip from the checkpoint up to the first requested row.
        while recordIndex < rows.lowerBound {
            current = RecordScanner.nextRecordStart(bytes, from: current,
                                                    delimiter: delim, quote: quote)
            recordIndex += 1
        }

        var starts: [Int] = []
        starts.reserveCapacity(upper - rows.lowerBound + 1)
        starts.append(current)
        var r = rows.lowerBound
        while r < upper {
            let next = RecordScanner.nextRecordStart(bytes, from: current,
                                                     delimiter: delim, quote: quote)
            // For the last row of the whole file, `next` == bytes.count == end.
            current = next
            starts.append(current)
            r += 1
        }

        // Build ranges; clamp the final end to `end` for safety.
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(starts.count - 1)
        for i in 0..<(starts.count - 1) {
            let lo = starts[i]
            let hi = max(lo, min(starts[i + 1], end))
            ranges.append(lo..<hi)
        }
        return ranges
    }
}
