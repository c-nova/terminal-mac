import Compression
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum GuestImage {
    public static let maximumEncodedBytes = 64 * 1024 * 1024
    public static let maximumPixelCount = 7680 * 4320
    public static let maximumDecodedBytes = 128 * 1024 * 1024

    public static func validateDimensions(width: Int, height: Int) throws {
        guard (1...8192).contains(width), (1...8192).contains(height),
              width <= maximumPixelCount / height else { throw Failure("Invalid or oversized guest image dimensions") }
    }

    public static func pixelByteCount(width: Int, height: Int, bytesPerRow: Int) throws -> Int {
        try validateDimensions(width: width, height: height)
        guard (width * 4...width * 4 + 1024).contains(bytesPerRow),
              bytesPerRow <= maximumDecodedBytes / height else { throw Failure("Invalid or oversized guest pixel buffer") }
        return bytesPerRow * height
    }

    public static func pixels(_ compressed: Data, width: Int, height: Int, bytesPerRow: Int) throws -> Data {
        let expected = try pixelByteCount(width: width, height: height, bytesPerRow: bytesPerRow)
        guard !compressed.isEmpty, compressed.count <= maximumEncodedBytes else { throw Failure("Invalid guest compressed frame") }
        var output = Data(count: expected + 1)
        try compressed.withUnsafeBytes { source in
            try output.withUnsafeMutableBytes { destination in
                var stream = compression_stream(dst_ptr: destination.bindMemory(to: UInt8.self).baseAddress!, dst_size: 0,
                                                src_ptr: source.bindMemory(to: UInt8.self).baseAddress!, src_size: 0, state: nil)
                guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZ4) == COMPRESSION_STATUS_OK else {
                    throw Failure("Cannot initialize guest frame decoder")
                }
                defer { compression_stream_destroy(&stream) }
                stream.src_ptr = source.bindMemory(to: UInt8.self).baseAddress!
                stream.src_size = source.count
                stream.dst_ptr = destination.bindMemory(to: UInt8.self).baseAddress!
                stream.dst_size = destination.count
                while true {
                    let previousSource = stream.src_size, previousDestination = stream.dst_size
                    let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    if status == COMPRESSION_STATUS_END {
                        guard stream.dst_size == 1, stream.src_size == 0 else { throw Failure("Guest frame length mismatch") }
                        break
                    }
                    guard status == COMPRESSION_STATUS_OK, stream.dst_size > 0,
                          stream.src_size < previousSource || stream.dst_size < previousDestination else {
                        throw Failure("Invalid or oversized guest compressed frame")
                    }
                }
            }
        }
        output.removeLast()
        return output
    }

    public static func pngSource(_ data: Data) throws -> CGImageSource {
        guard !data.isEmpty, data.count <= maximumEncodedBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            throw Failure("Invalid guest PNG")
        }
        let width = try jsonInteger(properties[kCGImagePropertyPixelWidth as String], range: 1...8192)
        let height = try jsonInteger(properties[kCGImagePropertyPixelHeight as String], range: 1...8192)
        _ = try jsonInteger(properties[kCGImagePropertyDepth as String], range: 1...8)
        try validateDimensions(width: width, height: height)
        return source
    }

    public static func png(_ data: Data) throws -> CGImage {
        let source = try pngSource(data)
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw Failure("Cannot decode guest PNG")
        }
        try validateDimensions(width: image.width, height: image.height)
        return image
    }
}