import Foundation
import SharedInfrastructure

public struct CapsuleHeader: Sendable, Equatable {
    public let length: UInt16 // original payload length in bytes
    public let flags: UInt8   // reserved for future use
    public let crc32: UInt32  // CRC32 of original payload

    public static let byteCount: Int = 7

    public init(length: UInt16, flags: UInt8 = 0, crc32: UInt32) {
        self.length = length
        self.flags = flags
        self.crc32 = crc32
    }

    public func encode() -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Self.byteCount)
        // Little-endian encoding
        bytes.append(UInt8(truncatingIfNeeded: length & 0x00FF))
        bytes.append(UInt8(truncatingIfNeeded: (length >> 8) & 0x00FF))
        bytes.append(flags)
        let c = crc32
        bytes.append(UInt8(truncatingIfNeeded: c & 0x000000FF))
        bytes.append(UInt8(truncatingIfNeeded: (c >> 8) & 0x000000FF))
        bytes.append(UInt8(truncatingIfNeeded: (c >> 16) & 0x000000FF))
        bytes.append(UInt8(truncatingIfNeeded: (c >> 24) & 0x000000FF))
        return bytes
    }

    public static func decode(from bytes: ArraySlice<UInt8>) throws -> CapsuleHeader {
        guard bytes.count >= Self.byteCount else {
            throw CapsuleError.malformedHeader
        }
        let b0 = UInt16(bytes[bytes.startIndex + 0])
        let b1 = UInt16(bytes[bytes.startIndex + 1])
        let length = (b1 << 8) | b0 // little-endian
        let flags = bytes[bytes.startIndex + 2]
        let c0 = UInt32(bytes[bytes.startIndex + 3])
        let c1 = UInt32(bytes[bytes.startIndex + 4])
        let c2 = UInt32(bytes[bytes.startIndex + 5])
        let c3 = UInt32(bytes[bytes.startIndex + 6])
        let crc32 = (c3 << 24) | (c2 << 16) | (c1 << 8) | c0
        return CapsuleHeader(length: length, flags: flags, crc32: crc32)
    }
}

public struct CapsuleBlock: Sendable, Equatable {
    public let blockSize: Int
    public let bytes: [UInt8]

    public init(blockSize: Int, bytes: [UInt8]) throws {
        guard bytes.count == blockSize else {
            throw CapsuleError.invalidBlockSize(expected: blockSize, actual: bytes.count)
        }
        self.blockSize = blockSize
        self.bytes = bytes
    }

    public func header() throws -> CapsuleHeader {
        try CapsuleHeader.decode(from: bytes.prefix(CapsuleHeader.byteCount))
    }

    public func payload() throws -> ArraySlice<UInt8> {
        let header = try header()
        let len = Int(header.length)
        let start = CapsuleHeader.byteCount
        let end = start + len
        guard end <= bytes.count else { throw CapsuleError.malformedHeader }
        return bytes[start..<end]
    }
}

public enum CapsuleError: Error, LocalizedError, Equatable {
    case inputTooLong(max: Int, actual: Int)
    case malformedHeader
    case crcMismatch(expected: UInt32, actual: UInt32)
    case invalidBlockSize(expected: Int, actual: Int)
    case invalidBlockStructure(reason: String)

    public var errorDescription: String? {
        switch self {
        case let .inputTooLong(max, actual):
            return "Input length \(actual) exceeds max_input_bytes=\(max)"
        case .malformedHeader:
            return "Malformed capsule header"
        case let .crcMismatch(expected, actual):
            return "CRC mismatch: expected=\(String(format: "0x%08X", expected)) actual=\(String(format: "0x%08X", actual))"
        case let .invalidBlockSize(expected, actual):
            return "Invalid block size: expected=\(expected) actual=\(actual)"
        case let .invalidBlockStructure(reason):
            return "Invalid block structure: \(reason)"
        }
    }
}
