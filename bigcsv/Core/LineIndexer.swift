import Foundation

/// Builds a `RecordIndex` by making one quote-aware pass over a memory-mapped
/// file, off the main thread, reporting progress and supporting cancellation.
///
/// The pass is inherently sequential (you can't know if byte N is inside a
/// quoted field without scanning from a known-unquoted point), which is why
/// "instant open" means "first screen immediately, index streams in" rather than
/// "whole index instantly".
public nonisolated struct LineIndexer: Sendable {

    /// How many rows between progress callbacks (also a `Task.yield` cadence).
    public let progressRowInterval: Int

    public init(progressRowInterval: Int = 65_536) {
        precondition(progressRowInterval > 0)
        self.progressRowInterval = progressRowInterval
    }

    /// Scan all of `mapper`'s bytes, populating `index`. Honors task cancellation;
    /// `onProgress` is called periodically and once at completion. `onProgress`
    /// must be safe to call from a background executor (the app hops to the main
    /// actor inside it).
    public func index(_ mapper: FileMapper,
                      dialect: CSVDialect,
                      into index: RecordIndex,
                      onProgress: @Sendable (IndexProgress) -> Void) async {
        let bytes = mapper.bytes
        let n = bytes.count
        let scanStart = RecordScanner.utf8BOMLength(bytes)
        let total = n - scanStart
        let delimiter = dialect.delimiter.byte
        let quote = dialect.quote

        mapper.advise(MADV_SEQUENTIAL)
        defer { mapper.advise(MADV_RANDOM) }

        // Empty file (or BOM-only): zero rows.
        guard scanStart < n else {
            index.markComplete(count: 0, endOffset: n)
            onProgress(IndexProgress(rowCount: 0, bytesScanned: total,
                                     totalBytes: total, isComplete: true))
            return
        }

        var recordStart = scanStart
        var j = 0                              // index of the record currently started
        index.appendCheckpoint(recordStart)    // record 0

        while true {
            if Task.isCancelled {
                index.publish(count: j, endOffset: recordStart)
                onProgress(IndexProgress(rowCount: j, bytesScanned: recordStart - scanStart,
                                         totalBytes: total, isComplete: false))
                return
            }

            let next = RecordScanner.nextRecordStart(bytes, from: recordStart,
                                                     delimiter: delimiter, quote: quote)
            if next >= n {
                // Record j is the final record (no trailing record follows).
                let finalCount = j + 1
                index.markComplete(count: finalCount, endOffset: n)
                onProgress(IndexProgress(rowCount: finalCount, bytesScanned: total,
                                         totalBytes: total, isComplete: true))
                return
            }

            j += 1
            if j % index.stride == 0 {
                index.appendCheckpoint(next)   // checkpoint for record j (multiple of stride)
            }
            recordStart = next

            if j % progressRowInterval == 0 {
                index.publish(count: j, endOffset: recordStart)
                onProgress(IndexProgress(rowCount: j, bytesScanned: recordStart - scanStart,
                                         totalBytes: total, isComplete: false))
                await Task.yield()
            }
        }
    }
}
