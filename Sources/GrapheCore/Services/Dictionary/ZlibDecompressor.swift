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
