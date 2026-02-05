import Foundation

#if canImport(SharedInfrastructure)
import SharedInfrastructure
#endif

public enum PrecomputedDataset {
    public struct Metadata: Codable, Sendable, Equatable {
        public let type: String
        public let schemaVersion: Int
        public let bins: Int
        public let capsuleBase: Int
        public let blockSize: Int
        public let prp: String
        public let feistelRounds: Int
        public let keyHex: String
        public let normalization: String
        public let endian: String
        public let floatFormat: String

        public init(
            schemaVersion: Int,
            bins: Int,
            capsuleBase: Int,
            blockSize: Int,
            prp: String,
            feistelRounds: Int,
            keyHex: String,
            normalization: String,
            endian: String = "little",
            floatFormat: String = "float32"
        ) {
            self.type = "metadata"
            self.schemaVersion = schemaVersion
            self.bins = bins
            self.capsuleBase = capsuleBase
            self.blockSize = blockSize
            self.prp = prp
            self.feistelRounds = feistelRounds
            self.keyHex = keyHex
            self.normalization = normalization
            self.endian = endian
            self.floatFormat = floatFormat
        }
    }

    public struct Record: Codable, Sendable {
        public let id: String
        public let split: String
        public let energiesB64: String
        public let targetsB64: String
        public let targetsNormB64: String
        public let wrongTargetsB64: String
        public let wrongTargetsNormB64: String
        public let wrongCount: Int

        enum CodingKeys: String, CodingKey {
            case id
            case split
            case energiesB64 = "energies_b64"
            case targetsB64 = "targets_b64"
            case targetsNormB64 = "targets_norm_b64"
            case wrongTargetsB64 = "wrong_targets_b64"
            case wrongTargetsNormB64 = "wrong_targets_norm_b64"
            case wrongCount = "wrong_count"
        }
    }

    public struct Sample: Sendable {
        public let id: String
        public let split: String
        public let energies: [Float]
        public let targets: [Float]
        public let targetsNorm: [Float]
        public let wrongTargets: [[Float]]
        public let wrongTargetsNorm: [[Float]]
        public let optionTargets: [[Float]]
        public let correctIndex: Int
    }

    public enum Error: LocalizedError {
        case invalidBase64
        case invalidLength(expectedMultiple: Int, actual: Int)
        case metadataMissing
        case metadataMismatch(String)
        case binsMismatch(expected: Int, actual: Int)
        case wrongTargetsCountMismatch(expected: Int, actual: Int)
        case unsupportedFloatFormat(String)
        case unsupportedEndian(String)

        public var errorDescription: String? {
            switch self {
            case .invalidBase64:
                return "Invalid base64 payload in precomputed dataset"
            case let .invalidLength(expectedMultiple, actual):
                return "Invalid payload length: expected multiple of \(expectedMultiple), got \(actual)"
            case .metadataMissing:
                return "Precomputed dataset metadata is missing"
            case let .metadataMismatch(reason):
                return "Precomputed dataset metadata mismatch: \(reason)"
            case let .binsMismatch(expected, actual):
                return "Precomputed dataset bins mismatch: expected \(expected), got \(actual)"
            case let .wrongTargetsCountMismatch(expected, actual):
                return "Precomputed dataset wrong_targets length mismatch: expected \(expected), got \(actual)"
            case let .unsupportedFloatFormat(fmt):
                return "Unsupported float format '\(fmt)' in precomputed metadata (expected float32)"
            case let .unsupportedEndian(endian):
                return "Unsupported endian '\(endian)' in precomputed metadata (expected little)"
            }
        }
    }

    // MARK: - Metadata

#if canImport(SharedInfrastructure)
    public static func makeMetadata(config: ConfigRoot.Capsule, bins: Int) -> Metadata {
        Metadata(
            schemaVersion: 1,
            bins: bins,
            capsuleBase: config.base,
            blockSize: config.blockSize,
            prp: config.prp,
            feistelRounds: config.feistelRounds,
            keyHex: config.keyHex,
            normalization: config.normalization
        )
    }

    public static func validateMetadata(_ meta: Metadata, config: ConfigRoot.Capsule, bins: Int) throws {
        if meta.bins != bins {
            throw Error.binsMismatch(expected: bins, actual: meta.bins)
        }
        if meta.capsuleBase != config.base {
            throw Error.metadataMismatch("capsule.base expected \(config.base), got \(meta.capsuleBase)")
        }
        if meta.blockSize != config.blockSize {
            throw Error.metadataMismatch("capsule.block_size expected \(config.blockSize), got \(meta.blockSize)")
        }
        if meta.prp != config.prp {
            throw Error.metadataMismatch("capsule.prp expected \(config.prp), got \(meta.prp)")
        }
        if meta.feistelRounds != config.feistelRounds {
            throw Error.metadataMismatch("capsule.feistel_rounds expected \(config.feistelRounds), got \(meta.feistelRounds)")
        }
        if meta.keyHex != config.keyHex {
            throw Error.metadataMismatch("capsule.key_hex expected \(config.keyHex), got \(meta.keyHex)")
        }
        if meta.normalization != config.normalization {
            throw Error.metadataMismatch("capsule.normalization expected \(config.normalization), got \(meta.normalization)")
        }
        if meta.floatFormat.lowercased() != "float32" {
            throw Error.unsupportedFloatFormat(meta.floatFormat)
        }
        if meta.endian.lowercased() != "little" {
            throw Error.unsupportedEndian(meta.endian)
        }
    }
#endif

    // MARK: - Encoding helpers

    public static func makeRecord(
        id: String,
        split: String,
        energies: [Float],
        targets: [Float],
        targetsNorm: [Float],
        wrongTargets: [[Float]],
        wrongTargetsNorm: [[Float]]
    ) -> Record {
        let energiesU16: [UInt16] = energies.map {
            let v = Int($0.rounded())
            precondition(v >= 0 && v <= Int(UInt16.max), "energy out of UInt16 range")
            return UInt16(v)
        }
        let wrongFlat = wrongTargets.flatMap { $0 }
        let wrongNormFlat = wrongTargetsNorm.flatMap { $0 }
        return Record(
            id: id,
            split: split,
            energiesB64: encodeUInt16LE(energiesU16),
            targetsB64: encodeFloat32LE(targets),
            targetsNormB64: encodeFloat32LE(targetsNorm),
            wrongTargetsB64: encodeFloat32LE(wrongFlat),
            wrongTargetsNormB64: encodeFloat32LE(wrongNormFlat),
            wrongCount: wrongTargets.count
        )
    }

    // MARK: - Decoding helpers

    public static func decodeRecord(_ record: Record, bins: Int) throws -> Sample {
        let energiesU16 = try decodeUInt16LE(record.energiesB64)
        let energies = energiesU16.map { Float($0) }
        let targets = try decodeFloat32LE(record.targetsB64)
        let targetsNorm = try decodeFloat32LE(record.targetsNormB64)
        let wrongFlat = try decodeFloat32LE(record.wrongTargetsB64)
        let wrongNormFlat = try decodeFloat32LE(record.wrongTargetsNormB64)

        if targets.count != bins || targetsNorm.count != bins {
            throw Error.binsMismatch(expected: bins, actual: max(targets.count, targetsNorm.count))
        }

        let expectedWrongCount = record.wrongCount * bins
        if wrongFlat.count != expectedWrongCount || wrongNormFlat.count != expectedWrongCount {
            throw Error.wrongTargetsCountMismatch(expected: expectedWrongCount, actual: max(wrongFlat.count, wrongNormFlat.count))
        }

        var wrongTargets: [[Float]] = []
        var wrongTargetsNorm: [[Float]] = []
        wrongTargets.reserveCapacity(record.wrongCount)
        wrongTargetsNorm.reserveCapacity(record.wrongCount)
        for i in 0..<record.wrongCount {
            let start = i * bins
            let end = start + bins
            wrongTargets.append(Array(wrongFlat[start..<end]))
            wrongTargetsNorm.append(Array(wrongNormFlat[start..<end]))
        }

        let optionTargets = [targets] + wrongTargets
        return Sample(
            id: record.id,
            split: record.split,
            energies: energies,
            targets: targets,
            targetsNorm: targetsNorm,
            wrongTargets: wrongTargets,
            wrongTargetsNorm: wrongTargetsNorm,
            optionTargets: optionTargets,
            correctIndex: 0
        )
    }

    // MARK: - I/O

#if canImport(SharedInfrastructure)
    public static func loadJSONL(paths: [String], config: ConfigRoot.Capsule, bins: Int) throws -> [Sample] {
        guard !paths.isEmpty else { return [] }
        let decoder = JSONDecoder()
        var metadata: Metadata?
        var samples: [Sample] = []

        try forEachJSONLLine(paths: paths) { line in
            if let meta = try? decoder.decode(Metadata.self, from: line), meta.type == "metadata" {
                if let existing = metadata {
                    if existing != meta {
                        throw Error.metadataMismatch("multiple metadata headers do not match")
                    }
                } else {
                    try validateMetadata(meta, config: config, bins: bins)
                    metadata = meta
                }
                return
            }

            let record = try decoder.decode(Record.self, from: line)
            let sample = try decodeRecord(record, bins: bins)
            samples.append(sample)
        }

        if metadata == nil {
            throw Error.metadataMissing
        }
        return samples
    }

    public static func writeJSONL(metadata: Metadata, records: [Record], to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        fm.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        let encoder = JSONEncoder()
        try writeLine(metadata, encoder: encoder, to: handle)
        for record in records {
            try writeLine(record, encoder: encoder, to: handle)
        }
    }
#endif

    // MARK: - Base64 helpers

    public static func encodeUInt16LE(_ values: [UInt16]) -> String {
        var data = Data(count: values.count * MemoryLayout<UInt16>.stride)
        data.withUnsafeMutableBytes { raw in
            var offset = 0
            for v in values {
                var le = v.littleEndian
                raw.storeBytes(of: le, toByteOffset: offset, as: UInt16.self)
                offset += MemoryLayout<UInt16>.stride
            }
        }
        return data.base64EncodedString()
    }

    public static func decodeUInt16LE(_ base64: String) throws -> [UInt16] {
        guard let data = Data(base64Encoded: base64) else { throw Error.invalidBase64 }
        if data.count % MemoryLayout<UInt16>.stride != 0 {
            throw Error.invalidLength(expectedMultiple: MemoryLayout<UInt16>.stride, actual: data.count)
        }
        let count = data.count / MemoryLayout<UInt16>.stride
        var out = [UInt16](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                let v: UInt16 = raw.loadUnaligned(fromByteOffset: i * MemoryLayout<UInt16>.stride, as: UInt16.self)
                out[i] = UInt16(littleEndian: v)
            }
        }
        return out
    }

    public static func encodeFloat32LE(_ values: [Float]) -> String {
        var data = Data(count: values.count * MemoryLayout<UInt32>.stride)
        data.withUnsafeMutableBytes { raw in
            var offset = 0
            for v in values {
                var bits = v.bitPattern.littleEndian
                raw.storeBytes(of: bits, toByteOffset: offset, as: UInt32.self)
                offset += MemoryLayout<UInt32>.stride
            }
        }
        return data.base64EncodedString()
    }

    public static func decodeFloat32LE(_ base64: String) throws -> [Float] {
        guard let data = Data(base64Encoded: base64) else { throw Error.invalidBase64 }
        if data.count % MemoryLayout<UInt32>.stride != 0 {
            throw Error.invalidLength(expectedMultiple: MemoryLayout<UInt32>.stride, actual: data.count)
        }
        let count = data.count / MemoryLayout<UInt32>.stride
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                let bits: UInt32 = raw.loadUnaligned(fromByteOffset: i * MemoryLayout<UInt32>.stride, as: UInt32.self)
                out[i] = Float(bitPattern: UInt32(littleEndian: bits))
            }
        }
        return out
    }

    // MARK: - JSONL helpers

    private static func writeLine<T: Encodable>(_ value: T, encoder: JSONEncoder, to handle: FileHandle) throws {
        let data = try encoder.encode(value)
        handle.write(data)
        handle.write(Data([0x0A]))
    }

    private static func forEachJSONLLine(paths: [String], _ body: (Data) throws -> Void) throws {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        for url in urls {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            var buffer = Data()
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let lineSlice = buffer[..<nl]
                    buffer.removeSubrange(..<buffer.index(after: nl))
                    var line = Data(lineSlice)
                    if line.last == 0x0D { line.removeLast() }
                    if line.isEmpty { continue }
                    try body(line)
                }
            }

            if !buffer.isEmpty {
                var line = buffer
                if line.last == 0x0D { line.removeLast() }
                if !line.isEmpty {
                    try body(line)
                }
            }
        }
    }
}
