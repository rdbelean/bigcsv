import Foundation

/// Incremental CRC-32 (IEEE 802.3, polynomial 0xEDB88320) — required by the ZIP
/// format. `value` is the finalized checksum.
struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    private var running: UInt32 = 0xFFFF_FFFF

    mutating func update(_ bytes: [UInt8]) {
        var c = running
        for b in bytes { c = Self.table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        running = c
    }

    var value: UInt32 { running ^ 0xFFFF_FFFF }

    static func checksum(_ data: [UInt8]) -> UInt32 {
        var c = CRC32(); c.update(data); return c.value
    }
}

/// Minimal streaming ZIP writer using STORED (uncompressed) entries with correct
/// CRC-32s and a central directory — enough to assemble a valid `.xlsx`. STORED (no
/// DEFLATE dependency) keeps it dependency-free and lets large worksheet parts be
/// copied straight from a temp file. 32-bit offsets/sizes (no ZIP64): a part or the
/// archive exceeding 4 GB throws `tooLarge`.
final class ZipWriter {
    enum ZipError: Error { case tooLarge }

    private let handle: FileHandle
    private var pos = 0
    private struct Entry { let name: [UInt8]; let crc: UInt32; let size: UInt32; let offset: UInt32 }
    private var entries: [Entry] = []

    init(handle: FileHandle) { self.handle = handle }

    /// Add an entry whose bytes are already in memory (the small XML parts).
    func addStored(name: String, data: [UInt8]) throws {
        try addEntry(name: name, crc: CRC32.checksum(data), size: data.count) { h in
            try h.write(contentsOf: Data(data))
            return data.count
        }
    }

    /// Add an entry by streaming an existing file's bytes (the big worksheet part).
    /// `crc`/`size` were computed while the file was written.
    func addStoredFromFile(name: String, fileURL: URL, crc: UInt32, size: Int) throws {
        try addEntry(name: name, crc: crc, size: size) { h in
            let reader = try FileHandle(forReadingFrom: fileURL)
            defer { try? reader.close() }
            var copied = 0
            while let chunk = try reader.read(upToCount: 256 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()        // stay responsive during a large tail copy
                try h.write(contentsOf: chunk)
                copied += chunk.count
            }
            return copied
        }
    }

    private func addEntry(name: String, crc: UInt32, size: Int, writeBody: (FileHandle) throws -> Int) throws {
        guard pos <= Int(UInt32.max), size <= Int(UInt32.max) else { throw ZipError.tooLarge }
        let nameBytes = Array(name.utf8)
        let offset = UInt32(pos)
        let header = Self.localFileHeader(name: nameBytes, crc: crc, size: UInt32(size))
        try handle.write(contentsOf: Data(header))
        pos += header.count
        let written = try writeBody(handle)
        pos += written
        entries.append(Entry(name: nameBytes, crc: crc, size: UInt32(size), offset: offset))
    }

    /// Write the central directory + end-of-central-directory record.
    func finish() throws {
        let cdOffset = pos
        var cd = [UInt8]()
        for e in entries {
            le32(0x0201_4b50, &cd)                 // central file header signature
            le16(20, &cd); le16(20, &cd)           // version made by / needed
            le16(0, &cd); le16(0, &cd)             // gp flag / method (stored)
            le16(0, &cd); le16(0x21, &cd)          // mod time / date (1980-01-01)
            le32(e.crc, &cd)
            le32(e.size, &cd); le32(e.size, &cd)   // compressed == uncompressed
            le16(UInt16(e.name.count), &cd)
            le16(0, &cd); le16(0, &cd)             // extra / comment length
            le16(0, &cd); le16(0, &cd)             // disk start / internal attrs
            le32(0, &cd)                           // external attrs
            le32(e.offset, &cd)                    // local header offset
            cd.append(contentsOf: e.name)
        }
        try handle.write(contentsOf: Data(cd))
        pos += cd.count

        guard cdOffset <= Int(UInt32.max) else { throw ZipError.tooLarge }
        var eocd = [UInt8]()
        le32(0x0605_4b50, &eocd)                   // EOCD signature
        le16(0, &eocd); le16(0, &eocd)             // disk numbers
        le16(UInt16(entries.count), &eocd)
        le16(UInt16(entries.count), &eocd)
        le32(UInt32(cd.count), &eocd)              // central directory size
        le32(UInt32(cdOffset), &eocd)              // central directory offset
        le16(0, &eocd)                             // comment length
        try handle.write(contentsOf: Data(eocd))
        pos += eocd.count
    }

    private static func localFileHeader(name: [UInt8], crc: UInt32, size: UInt32) -> [UInt8] {
        var h = [UInt8]()
        le32(0x0403_4b50, &h)                      // local file header signature
        le16(20, &h)                               // version needed
        le16(0, &h); le16(0, &h)                   // gp flag / method (stored)
        le16(0, &h); le16(0x21, &h)                // mod time / date (1980-01-01)
        le32(crc, &h)
        le32(size, &h); le32(size, &h)             // compressed == uncompressed
        le16(UInt16(name.count), &h)
        le16(0, &h)                                // extra length
        h.append(contentsOf: name)
        return h
    }
}

private func le16(_ v: UInt16, _ a: inout [UInt8]) {
    a.append(UInt8(v & 0xFF)); a.append(UInt8((v >> 8) & 0xFF))
}
private func le32(_ v: UInt32, _ a: inout [UInt8]) {
    a.append(UInt8(v & 0xFF)); a.append(UInt8((v >> 8) & 0xFF))
    a.append(UInt8((v >> 16) & 0xFF)); a.append(UInt8((v >> 24) & 0xFF))
}
