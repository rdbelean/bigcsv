import Foundation

/// Memory-maps a file read-only and vends its bytes without ever copying the
/// whole file into memory.
///
/// We use raw `mmap` (not `Data(…, .mappedIfSafe)`, which can silently fall
/// back to a full read on large files). The mapping is `PROT_READ`/`MAP_PRIVATE`
/// and is immutable for the lifetime of the object, which is why this class can
/// be `@unchecked Sendable`: concurrent readers from any isolation domain are
/// data-race-free because nothing is ever written.
///
/// Sandbox note: the caller is responsible for security-scoped access — call
/// `startAccessingSecurityScopedResource()` on the URL *before* constructing a
/// `FileMapper` and keep that scope open for the mapper's lifetime, because
/// faulting in a page later re-reads from the file descriptor.
public nonisolated final class FileMapper: @unchecked Sendable {

    public enum MapError: Error, Sendable, Equatable {
        case openFailed(errno: Int32)
        case statFailed(errno: Int32)
        case notRegularFile
        case mmapFailed(errno: Int32)
    }

    /// Number of mapped bytes (the file size). Zero for an empty file.
    public let count: Int

    /// The source URL, retained for diagnostics / reopen.
    public let url: URL

    private let address: UnsafeRawPointer?   // nil for an empty file
    private let mappedLength: Int            // bytes passed to mmap (0 if empty)
    private let fileDescriptor: Int32

    public convenience init(url: URL) throws {
        try self.init(path: url.path, url: url)
    }

    /// Designated initializer. `path` is opened; `url` is retained for metadata.
    public init(path: String, url: URL? = nil) throws {
        self.url = url ?? URL(fileURLWithPath: path)

        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw MapError.openFailed(errno: errno) }

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            let e = errno; close(fd); throw MapError.statFailed(errno: e)
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            close(fd); throw MapError.notRegularFile
        }

        let size = Int(st.st_size)
        self.fileDescriptor = fd
        self.count = size

        if size == 0 {
            // mmap of length 0 fails with EINVAL — represent an empty file as a
            // valid "zero bytes" mapping instead.
            self.address = nil
            self.mappedLength = 0
            return
        }

        guard let raw = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0),
              raw != MAP_FAILED else {
            let e = errno; close(fd); throw MapError.mmapFailed(errno: e)
        }
        self.address = UnsafeRawPointer(raw)
        self.mappedLength = size
    }

    deinit {
        if let address, mappedLength > 0 {
            munmap(UnsafeMutableRawPointer(mutating: address), mappedLength)
        }
        if fileDescriptor >= 0 {
            close(fileDescriptor)
        }
    }

    /// A read-only view over the entire mapped region (empty if the file is empty).
    public var bytes: UnsafeRawBufferPointer {
        guard let address, mappedLength > 0 else {
            return UnsafeRawBufferPointer(start: nil, count: 0)
        }
        return UnsafeRawBufferPointer(start: address, count: mappedLength)
    }

    /// A bounds-checked read-only view over `range` of the file.
    public func bytes(in range: Range<Int>) -> UnsafeRawBufferPointer {
        precondition(range.lowerBound >= 0 && range.upperBound <= count,
                     "byte range \(range) out of bounds 0..<\(count)")
        guard let address, !range.isEmpty else {
            return UnsafeRawBufferPointer(start: nil, count: 0)
        }
        return UnsafeRawBufferPointer(start: address + range.lowerBound,
                                      count: range.count)
    }

    /// Advise the kernel about the upcoming access pattern (e.g. `MADV_SEQUENTIAL`
    /// during the initial index scan, `MADV_RANDOM` for on-demand row reads).
    public func advise(_ advice: Int32) {
        guard let address, mappedLength > 0 else { return }
        madvise(UnsafeMutableRawPointer(mutating: address), mappedLength, advice)
    }
}
