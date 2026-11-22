import Foundation
import zlib

public enum ZlibError: LocalizedError, Sendable {
    case initFailed(Int32)
    case inflateFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .initFailed(let code):
            return "Zlib başlatılamadı (kod: \(code))"
        case .inflateFailed(let code):
            return "Sıkıştırılmış sözlük açılamadı (kod: \(code))"
        }
    }
}

public enum ZlibDecompressor {
    /// Decompresses gzip / dictzip (.dz / .gz) or zlib data using system libz.
    public static func decompress(_ compressed: Data) throws -> Data {
        guard !compressed.isEmpty else { return Data() }

        var stream = z_stream()
        // 15 + 32 enables automatic gzip and zlib header detection (supports dictzip .dz too)
        let initStatus = inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else {
            throw ZlibError.initFailed(initStatus)
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        let chunkSize = 65_536
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        let status: Int32 = compressed.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: Bytef.self).baseAddress else {
                return Z_DATA_ERROR
            }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: baseAddress)
            stream.avail_in = uInt(compressed.count)

            var lastStatus: Int32 = Z_OK
            repeat {
                let produced: Int = buffer.withUnsafeMutableBytes { outBuf in
                    guard let outPtr = outBuf.bindMemory(to: Bytef.self).baseAddress else {
                        return 0
                    }
                    stream.next_out = outPtr
                    stream.avail_out = uInt(chunkSize)
                    lastStatus = inflate(&stream, Z_NO_FLUSH)
                    return chunkSize - Int(stream.avail_out)
                }

                if produced > 0 {
                    output.append(buffer, count: produced)
                }

                if lastStatus == Z_STREAM_END {
                    // Handle concatenated gzip streams if any
                    if stream.avail_in > 0 {
                        let resetStatus = inflateReset(&stream)
                        if resetStatus != Z_OK {
                            return resetStatus
                        }
                        lastStatus = Z_OK
                    } else {
                        break
                    }
                }
            } while lastStatus == Z_OK

            return lastStatus
        }

        guard status == Z_STREAM_END || status == Z_OK else {
            throw ZlibError.inflateFailed(status)
        }

        return output
    }
}

/// Random-access reader for dictzip (`.dict.dz`) files (RFC 1952 gzip with `RA` extra subfield).
/// Maps the compressed file and inflates only the 1–2 chunks needed for a given byte range,
/// avoiding decompressing hundreds of megabytes of dictionary payloads into RAM.
public final class DictZipReader: @unchecked Sendable {
    private let mappedData: Data
    private let chunkLength: Int
    private let chunkOffsets: [Int] // count == chunkCount + 1 (file byte offsets of each compressed chunk)
    private let lock = NSLock()
    private var chunkCache: [Int: Data] = [:]
    private var cacheOrder: [Int] = []
    private let maxCachedChunks = 8

    public init?(mappedData: Data) {
        // Minimum gzip header is 10 bytes + 2 bytes XLEN
        guard mappedData.count >= 12 else { return nil }

        let parsed: (chunkLen: Int, chunkOffsets: [Int])? = mappedData.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let total = raw.count

            // Check gzip magic (0x1f, 0x8b) and deflate method (8)
            guard base[0] == 0x1F, base[1] == 0x8B, base[2] == 8 else { return nil }
            let flg = base[3]
            // Must have FEXTRA (0x04) for dictzip RA table
            guard (flg & 0x04) != 0 else { return nil }

            var pos = 10
            guard pos + 2 <= total else { return nil }
            let xlen = Int(base[pos]) | (Int(base[pos + 1]) << 8)
            pos += 2
            let extraEnd = pos + xlen
            guard extraEnd <= total else { return nil }

            // Scan extra subfields for 'R','A'
            var chunkLen = 0
            var chunkSizes: [Int] = []
            var subPos = pos
            while subPos + 4 <= extraEnd {
                let si1 = base[subPos]
                let si2 = base[subPos + 1]
                let slen = Int(base[subPos + 2]) | (Int(base[subPos + 3]) << 8)
                subPos += 4
                guard subPos + slen <= extraEnd else { return nil }

                if si1 == 0x52 && si2 == 0x41 && slen >= 6 { // "RA"
                    let ver = Int(base[subPos]) | (Int(base[subPos + 1]) << 8)
                    guard ver == 1 else { return nil }
                    chunkLen = Int(base[subPos + 2]) | (Int(base[subPos + 3]) << 8)
                    let chunkCount = Int(base[subPos + 4]) | (Int(base[subPos + 5]) << 8)
                    guard chunkLen > 0, chunkCount > 0, 6 + chunkCount * 2 <= slen else { return nil }

                    chunkSizes.reserveCapacity(chunkCount)
                    var cPos = subPos + 6
                    for _ in 0..<chunkCount {
                        let sz = Int(base[cPos]) | (Int(base[cPos + 1]) << 8)
                        chunkSizes.append(sz)
                        cPos += 2
                    }
                    break
                }
                subPos += slen
            }

            guard chunkLen > 0, !chunkSizes.isEmpty else { return nil }
            pos = extraEnd

            // Skip optional FNAME (0x08)
            if (flg & 0x08) != 0 {
                while pos < total && base[pos] != 0 { pos += 1 }
                pos += 1
            }
            // Skip optional FCOMMENT (0x10)
            if (flg & 0x10) != 0 {
                while pos < total && base[pos] != 0 { pos += 1 }
                pos += 1
            }
            // Skip optional FHCRC (0x02)
            if (flg & 0x02) != 0 {
                pos += 2
            }
            guard pos < total else { return nil }

            var offsets: [Int] = []
            offsets.reserveCapacity(chunkSizes.count + 1)
            var fileOffset = pos
            offsets.append(fileOffset)
            for sz in chunkSizes {
                fileOffset += sz
                guard fileOffset <= total else { return nil }
                offsets.append(fileOffset)
            }

            return (chunkLen, offsets)
        }

        guard let parsed else { return nil }
        self.mappedData = mappedData
        self.chunkLength = parsed.chunkLen
        self.chunkOffsets = parsed.chunkOffsets
    }

    public func read(offset: UInt64, size: UInt32) -> Data? {
        guard size > 0 else { return Data() }
        guard let start = Int(exactly: offset), start >= 0 else { return nil }
        let len = Int(size)
        let (end, overflow) = start.addingReportingOverflow(len)
        guard !overflow, end > start else { return nil }
        let chunkCount = chunkOffsets.count - 1
        guard chunkCount > 0 else { return nil }

        let firstChunk = start / chunkLength
        let lastChunk = (end - 1) / chunkLength
        guard firstChunk >= 0, lastChunk < chunkCount else { return nil }

        if firstChunk == lastChunk {
            guard let chunkData = loadChunk(firstChunk) else { return nil }
            let localStart = start - firstChunk * chunkLength
            let localEnd = localStart + len
            guard localStart >= 0, localEnd <= chunkData.count else { return nil }
            return chunkData.subdata(in: localStart..<localEnd)
        }

        var result = Data(capacity: len)
        for chunkIdx in firstChunk...lastChunk {
            guard let chunkData = loadChunk(chunkIdx) else { return nil }
            let chunkBase = chunkIdx * chunkLength
            let sliceStart = max(0, start - chunkBase)
            let sliceEnd = min(chunkData.count, end - chunkBase)
            guard sliceStart <= sliceEnd else { return nil }
            result.append(chunkData[sliceStart..<sliceEnd])
        }
        return result.count == len ? result : nil
    }

    private func loadChunk(_ index: Int) -> Data? {
        lock.lock()
        if let cached = chunkCache[index] {
            if let pos = cacheOrder.firstIndex(of: index), pos != cacheOrder.count - 1 {
                cacheOrder.remove(at: pos)
                cacheOrder.append(index)
            }
            lock.unlock()
            return cached
        }
        lock.unlock()

        let compStart = chunkOffsets[index]
        let compEnd = chunkOffsets[index + 1]
        let compLen = compEnd - compStart
        guard compLen > 0, compEnd <= mappedData.count else { return nil }

        guard let inflated = inflateRawChunk(start: compStart, length: compLen) else {
            return nil
        }

        lock.lock()
        if chunkCache[index] == nil {
            if cacheOrder.count >= maxCachedChunks {
                let oldest = cacheOrder.removeFirst()
                chunkCache.removeValue(forKey: oldest)
            }
            chunkCache[index] = inflated
            cacheOrder.append(index)
        }
        lock.unlock()
        return inflated
    }

    private func inflateRawChunk(start: Int, length: Int) -> Data? {
        var stream = z_stream()
        // -MAX_WBITS (-15) selects raw deflate (each dictzip chunk is an independent Z_FULL_FLUSH block)
        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return nil
        }
        defer { inflateEnd(&stream) }

        var output = Data(count: chunkLength)
        let produced: Int = mappedData.withUnsafeBytes { rawIn in
            guard let inBase = rawIn.bindMemory(to: Bytef.self).baseAddress else { return -1 }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inBase.advanced(by: start))
            stream.avail_in = uInt(length)

            return output.withUnsafeMutableBytes { rawOut in
                guard let outBase = rawOut.bindMemory(to: Bytef.self).baseAddress else { return -1 }
                stream.next_out = outBase
                stream.avail_out = uInt(chunkLength)

                let status = inflate(&stream, Z_SYNC_FLUSH)
                if status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR {
                    return chunkLength - Int(stream.avail_out)
                }
                return -1
            }
        }

        guard produced >= 0 else { return nil }
        if produced < output.count {
            output.count = produced
        }
        return output
    }
}
