import Foundation
import SharedInfrastructure

public enum EnergyMapper {
    // digits in [0..B-1] -> energies in [1..B]
    public static func toEnergies(fromDigits digits: [Int], baseB: Int) -> [Int] {
        digits.map { min(max($0, 0), baseB - 1) + 1 }
    }

    // energies in [1..B] -> digits in [0..B-1]
    public static func toDigits(fromEnergies energies: [Int], baseB: Int) -> [Int] {
        energies.map { min(max($0, 1), baseB) - 1 }
    }

    // Normalized floats x = E/(B+1) in (0, 1)
    public static func normalize(_ energies: [Int], baseB: Int) -> [Double] {
        let denom = Double(baseB + 1)
        return energies.map { Double($0) / denom }
    }
}

public enum CapsuleBridge {
    public struct EnergiesBatch: Sendable {
        public let digitsCount: Int
        public let energies: [Int] // length = digitsCount, range 1..B
        public let normalized: [Double] // optional normalization E/(B+1)
    }

    // Encode input payload into block, then convert whole block bytes -> base-B digits -> energies [1..B].
    public static func makeEnergies(from data: Data, config: ConfigRoot.Capsule) throws -> (batch: EnergiesBatch, block: CapsuleBlock) {
        let encoder = CapsuleEncoder(config: config)
        let block = try encoder.encode(data)
        let digits = ByteDigitsConverter.toDigits(bytes: block.bytes, baseB: config.base)
        let energies = EnergyMapper.toEnergies(fromDigits: digits, baseB: config.base)
        let normalized = config.normalization == "e_over_bplus1" ? EnergyMapper.normalize(energies, baseB: config.base) : []
        let batch = EnergiesBatch(digitsCount: digits.count, energies: energies, normalized: normalized)
        return (batch, block)
    }

    // Rebuild capsule block from energies and decode payload using CRC guard.
    public static func recoverCapsule(from energies: [Int], config: ConfigRoot.Capsule) throws -> Data {
        let digits = EnergyMapper.toDigits(fromEnergies: energies, baseB: config.base)
        let blockSize = config.blockSize
        let bytes = ByteDigitsConverter.toBytes(digitsMSDFirst: digits, baseB: config.base, byteCount: blockSize)
        let block = try CapsuleBlock(blockSize: blockSize, bytes: bytes)
        let decoder = CapsuleDecoder(config: config)
        return try decoder.decode(block)
    }
}
