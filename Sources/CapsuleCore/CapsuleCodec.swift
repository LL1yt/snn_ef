import Foundation
import SharedInfrastructure

public struct CapsuleEncoder: Sendable {
    public let config: ConfigRoot.Capsule

    public init(config: ConfigRoot.Capsule) {
        self.config = config
    }

    public func encode(_ input: Data) throws -> CapsuleBlock {
        let maxLen = config.maxInputBytes
        guard input.count <= maxLen else {
            throw CapsuleError.inputTooLong(max: maxLen, actual: input.count)
        }

        let payloadBytes = [UInt8](input)
        let crc = CRC32.compute(payloadBytes)
        let header = CapsuleHeader(length: UInt16(input.count), flags: 0, crc32: crc)

        var block = [UInt8](repeating: 0, count: config.blockSize)
        let headerBytes = header.encode()
        precondition(headerBytes.count == CapsuleHeader.byteCount)
        block.replaceSubrange(0..<CapsuleHeader.byteCount, with: headerBytes)
        block.replaceSubrange(CapsuleHeader.byteCount..<(CapsuleHeader.byteCount + payloadBytes.count), with: payloadBytes)

        // Apply PRP (placeholder for now)
        PRP.apply(inoutBytes: &block, config: config)

        LoggingHub.emit(process: "capsule.encode", level: .debug, message: "encoded len=\(input.count) block=\(config.blockSize) prp=\(config.prp)")
        return try CapsuleBlock(blockSize: config.blockSize, bytes: block)
    }
}

public struct CapsuleDecoder: Sendable {
    public let config: ConfigRoot.Capsule

    public init(config: ConfigRoot.Capsule) {
        self.config = config
    }

    public func decode(_ block: CapsuleBlock) throws -> Data {
        precondition(block.blockSize == config.blockSize)
        var bytes = block.bytes

        // Inverse PRP (placeholder for now)
        PRP.inverse(inoutBytes: &bytes, config: config)

        let header = try CapsuleHeader.decode(from: bytes.prefix(CapsuleHeader.byteCount))
        let len = Int(header.length)
        let payloadSlice = bytes[CapsuleHeader.byteCount..<(CapsuleHeader.byteCount + len)]
        let payload = Array(payloadSlice)
        let actualCRC = CRC32.compute(payload)
        guard actualCRC == header.crc32 else {
            throw CapsuleError.crcMismatch(expected: header.crc32, actual: actualCRC)
        }

        LoggingHub.emit(process: "capsule.decode", level: .debug, message: "decoded len=\(len) block=\(config.blockSize) prp=\(config.prp)")
        return Data(payload)
    }
}
