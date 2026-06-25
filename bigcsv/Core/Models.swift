import Foundation

/// Progress of the background line-indexing pass.
public nonisolated struct IndexProgress: Sendable, Equatable {
    /// Number of rows discovered and fully bounded so far (safe to display).
    public var rowCount: Int
    /// Bytes scanned so far.
    public var bytesScanned: Int
    /// Total bytes to scan (file size, after any BOM).
    public var totalBytes: Int
    /// True once the entire file has been indexed.
    public var isComplete: Bool

    public init(rowCount: Int, bytesScanned: Int, totalBytes: Int, isComplete: Bool) {
        self.rowCount = rowCount
        self.bytesScanned = bytesScanned
        self.totalBytes = totalBytes
        self.isComplete = isComplete
    }

    /// 0...1 fraction of bytes scanned (1 when there is nothing to scan).
    public var fractionComplete: Double {
        guard totalBytes > 0 else { return 1 }
        return min(1, Double(bytesScanned) / Double(totalBytes))
    }

    public static let empty = IndexProgress(rowCount: 0, bytesScanned: 0, totalBytes: 0, isComplete: false)
}
