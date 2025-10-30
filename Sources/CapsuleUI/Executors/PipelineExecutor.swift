import Foundation
import CapsuleCore
import SharedInfrastructure

public enum PipelineExecutionError: LocalizedError {
    case inputTooLarge(actualBytes: Int, allowedBytes: Int)

    public var errorDescription: String? {
        switch self {
        case let .inputTooLarge(actual, allowed):
            return "Input is \(actual) bytes in UTF-8, but the capsule supports at most \(allowed) bytes."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .inputTooLarge:
            return "Reduce the input length or increase capsule.max_input_bytes and block_size in the configuration."
        }
    }
}

/// Orchestrates pipeline execution and captures detailed stage data for visualization
public actor PipelineExecutor {
    private let config: ConfigRoot.Capsule
    private var currentSnapshot: PipelineSnapshot?

    public init(config: ConfigRoot.Capsule) {
        self.config = config
    }

    // MARK: - Public API

    /// Execute full forward pipeline: text → capsule → energies
    public func executeForward(_ input: String) async throws -> PipelineSnapshot {
        let startTime = Date()
        var stages: [PipelineStage] = []

        LoggingHub.emit(process: "ui.pipeline", level: .info, message: "Starting forward pipeline for input length \(input.count)")

        // Stage 1: Input
        stages.append(captureInputStage(input))

        // Stage 2: Block Structure (before PRP)
        let (blockStage, blockBytes) = try captureBlockStructureStage(input)
        stages.append(blockStage)

        // Stage 3: PRP Transform
        let (prpStage, capsuleBlock) = try capturePRPStage(blockBytes)
        stages.append(prpStage)

        // Stage 4: Capsule Block
        stages.append(captureCapsuleBlockStage(capsuleBlock))

        // Stage 5: Base Conversion
        let (digitsStage, digits) = captureBaseConversionStage(capsuleBlock)
        stages.append(digitsStage)

        // Stage 6: Printable String
        stages.append(capturePrintableStage(digits))

        // Stage 7: Energies Mapping
        let (energiesStage, energies) = captureEnergiesStage(digits)
        stages.append(energiesStage)

        // Stage 8: Normalization
        if config.normalization == "e_over_bplus1" {
            stages.append(captureNormalizationStage(energies))
        }

        let totalDuration = Date().timeIntervalSince(startTime)
        let snapshot = PipelineSnapshot(
            generatedAt: startTime,
            inputText: input,
            config: config,
            stages: stages,
            totalDuration: totalDuration,
            success: stages.allSatisfy { $0.isSuccessful }
        )

        currentSnapshot = snapshot
        LoggingHub.emit(
            process: "ui.pipeline",
            level: .info,
            message: "Forward pipeline completed in \(totalDuration * 1000)ms, \(stages.count) stages"
        )

        return snapshot
    }

    /// Execute reverse pipeline: energies → capsule → text
    public func executeReverse(from energies: [Int]) async throws -> PipelineSnapshot {
        let startTime = Date()
        var stages: [PipelineStage] = []

        LoggingHub.emit(process: "ui.pipeline", level: .info, message: "Starting reverse pipeline from \(energies.count) energies")

        // Stage 9: Reverse Process
        let (reverseStage, recoveredData) = try captureReverseStage(energies)
        stages.append(reverseStage)

        // Stage 10: Recovered
        stages.append(captureRecoveredStage(recoveredData))

        let totalDuration = Date().timeIntervalSince(startTime)
        let snapshot = PipelineSnapshot(
            generatedAt: startTime,
            inputText: "",
            config: config,
            stages: stages,
            totalDuration: totalDuration,
            success: stages.allSatisfy { $0.isSuccessful }
        )

        LoggingHub.emit(
            process: "ui.pipeline",
            level: .info,
            message: "Reverse pipeline completed in \(totalDuration * 1000)ms"
        )

        return snapshot
    }

    /// Execute full roundtrip: forward + reverse
    public func executeRoundtrip(_ input: String) async throws -> PipelineSnapshot {
        let startTime = Date()
        var stages: [PipelineStage] = []

        LoggingHub.emit(process: "ui.pipeline", level: .info, message: "Starting roundtrip pipeline")

        // Forward stages
        stages.append(captureInputStage(input))
        let (blockStage, blockBytes) = try captureBlockStructureStage(input)
        stages.append(blockStage)
        let (prpStage, capsuleBlock) = try capturePRPStage(blockBytes)
        stages.append(prpStage)
        stages.append(captureCapsuleBlockStage(capsuleBlock))
        let (digitsStage, digits) = captureBaseConversionStage(capsuleBlock)
        stages.append(digitsStage)
        stages.append(capturePrintableStage(digits))
        let (energiesStage, energies) = captureEnergiesStage(digits)
        stages.append(energiesStage)
        if config.normalization == "e_over_bplus1" {
            stages.append(captureNormalizationStage(energies))
        }

        // Reverse stages
        let (reverseStage, recoveredData) = try captureReverseStage(energies)
        stages.append(reverseStage)
        stages.append(captureRecoveredStage(recoveredData))

        let totalDuration = Date().timeIntervalSince(startTime)
        let snapshot = PipelineSnapshot(
            generatedAt: startTime,
            inputText: input,
            config: config,
            stages: stages,
            totalDuration: totalDuration,
            success: stages.allSatisfy { $0.isSuccessful }
        )

        currentSnapshot = snapshot
        LoggingHub.emit(
            process: "ui.pipeline",
            level: .info,
            message: "Roundtrip completed: \(stages.count) stages, \(totalDuration * 1000)ms, success=\(snapshot.success)"
        )

        return snapshot
    }

    // MARK: - Stage Capture Helpers

    private func captureInputStage(_ input: String) -> PipelineStage {
        let startTime = Date()
        let byteCount = input.utf8.count

        let metrics = StageMetrics(
            duration: Date().timeIntervalSince(startTime),
            inputSize: byteCount,
            outputSize: byteCount,
            metadata: [
                "char_count": "\(input.count)",
                "byte_count": "\(byteCount)"
            ]
        )

        LoggingHub.emit(process: "ui.pipeline.input", level: .debug, message: "Input stage: \(byteCount) bytes")

        return PipelineStage(
            type: .input,
            data: .text(input),
            metrics: metrics
        )
    }

    private func captureBlockStructureStage(_ input: String) throws -> (PipelineStage, [UInt8]) {
        let startTime = Date()
        let data = Data(input.utf8)
        let payloadBytes = [UInt8](data)
        let maxPayloadBytes = max(0, min(config.maxInputBytes, config.blockSize - CapsuleHeader.byteCount))

        guard payloadBytes.count <= maxPayloadBytes else {
            throw PipelineExecutionError.inputTooLarge(
                actualBytes: payloadBytes.count,
                allowedBytes: maxPayloadBytes
            )
        }

        let crc = CRC32.compute(payloadBytes)
        let header = CapsuleHeader(length: UInt16(data.count), flags: 0, crc32: crc)

        var blockBytes = [UInt8](repeating: 0, count: config.blockSize)
        let headerBytes = header.encode()
        blockBytes.replaceSubrange(0..<CapsuleHeader.byteCount, with: headerBytes)
        blockBytes.replaceSubrange(CapsuleHeader.byteCount..<(CapsuleHeader.byteCount + payloadBytes.count), with: payloadBytes)

        let paddingSize = config.blockSize - CapsuleHeader.byteCount - payloadBytes.count

        let metrics = StageMetrics(
            duration: Date().timeIntervalSince(startTime),
            inputSize: data.count,
            outputSize: config.blockSize,
            metadata: [
                "header_size": "\(CapsuleHeader.byteCount)",
                "payload_size": "\(payloadBytes.count)",
                "padding_size": "\(paddingSize)",
                "crc32": String(format: "0x%08X", crc)
            ]
        )

        LoggingHub.emit(
            process: "ui.pipeline.block",
            level: .debug,
            message: "Block structure: header=\(CapsuleHeader.byteCount) payload=\(payloadBytes.count) padding=\(paddingSize)"
        )

        let stage = PipelineStage(
            type: .blockStructure,
            data: .header(header: header, payload: payloadBytes, paddingSize: paddingSize),
            metrics: metrics
        )

        return (stage, blockBytes)
    }

    private func capturePRPStage(_ blockBytes: [UInt8]) throws -> (PipelineStage, CapsuleBlock) {
        let startTime = Date()
        var transformedBytes = blockBytes
        PRP.apply(inoutBytes: &transformedBytes, config: config)

        let block = try CapsuleBlock(blockSize: config.blockSize, bytes: transformedBytes)

        let metrics = StageMetrics(
            duration: Date().timeIntervalSince(startTime),
            inputSize: blockBytes.count,
            outputSize: transformedBytes.count,
            metadata: [
                "prp_type": config.prp,
                "rounds": "\(config.feistelRounds)"
            ]
        )

        LoggingHub.emit(
            process: "ui.pipeline.prp",
            level: .debug,
            message: "PRP applied: \(config.prp), \(config.feistelRounds) rounds"
        )

        let stage = PipelineStage(
            type: .prpTransform,
            data: .bytes(transformedBytes),
            metrics: metrics
        )

        return (stage, block)
    }

    private func captureCapsuleBlockStage(_ block: CapsuleBlock) -> PipelineStage {
        let startTime = Date()

        let metrics = StageMetrics(
            duration: Date().timeIntervalSince(startTime),
            inputSize: block.bytes.count,
            outputSize: block.bytes.count,
            metadata: [
                "block_size": "\(block.blockSize)"
            ]
        )

        LoggingHub.emit(process: "ui.pipeline.capsule", level: .debug, message: "Capsule block: \(block.bytes.count) bytes")

        return PipelineStage(
            type: .capsuleBlock,
            data: .block(block),
            metrics: metrics
        )
    }

    private func captureBaseConversionStage(_ block: CapsuleBlock) -> (PipelineStage, [Int]) {
        let startTime = Date()
        let digits = ByteDigitsConverter.toDigits(bytes: block.bytes, baseB: config.base)

        let metrics = StageMetrics(
            duration: Date().timeIntervalSince(startTime),
            inputSize: block.bytes.count,
            outputSize: digits.count,
            metadata: [
                "base": "\(config.base)",
                "digits_count": "\(digits.count)"
            ]
        )

        LoggingHub.emit(
            process: "ui.pipeline.base_conversion",
            level: .debug,
            message: "Base-\(config.base) conversion: \(block.bytes.count) bytes → \(digits.count) digits"
        )

        let stage = PipelineStage(
            type: .baseConversion,
            data: .digits(digits),
            metrics: metrics
        )

        return (stage, digits)
    }

    private func capturePrintableStage(_ digits: [Int]) -> PipelineStage {
        let startTime = Date()
        let printable = DigitStringConverter.digitsToString(digits, alphabet: config.alphabet)

        let metrics = StageMetrics(
            duration: Date().timeIntervalSince(startTime),
            inputSize: digits.count,
            outputSize: printable.count,
            metadata: [
                "alphabet_size": "\(config.alphabet.count)",
                "string_length": "\(printable.count)"
            ]
        )

        LoggingHub.emit(
            process: "ui.pipeline.printable",
            level: .debug,
            message: "Printable string: \(printable.count) characters"
        )

        return PipelineStage(
            type: .printableString,
            data: .printable(printable),
            metrics: metrics
        )
    }

    private func captureEnergiesStage(_ digits: [Int]) -> (PipelineStage, [Int]) {
        let startTime = Date()
        let energies = EnergyMapper.toEnergies(fromDigits: digits, baseB: config.base)

        let min = energies.min() ?? 0
        let max = energies.max() ?? 0
        let sum = energies.reduce(0, +)
        let mean = Double(sum) / Double(energies.count)

        let metrics = StageMetrics(
            duration: Date().timeIntervalSince(startTime),
            inputSize: digits.count,
            outputSize: energies.count,
            metadata: [
                "min": "\(min)",
                "max": "\(max)",
                "mean": String(format: "%.2f", mean),
                "sum": "\(sum)"
            ]
        )

        LoggingHub.emit(
            process: "ui.pipeline.energies",
            level: .debug,
            message: "Energies: count=\(energies.count), range=[\(min)..\(max)], sum=\(sum)"
        )

        let stage = PipelineStage(
            type: .energiesMapping,
            data: .energies(energies),
            metrics: metrics
        )

        return (stage, energies)
    }

    private func captureNormalizationStage(_ energies: [Int]) -> PipelineStage {
        let startTime = Date()
        let normalized = EnergyMapper.normalize(energies, baseB: config.base)

        let min = normalized.min() ?? 0
        let max = normalized.max() ?? 0
        let mean = normalized.reduce(0, +) / Double(normalized.count)

        let metrics = StageMetrics(
            duration: Date().timeIntervalSince(startTime),
            inputSize: energies.count,
            outputSize: normalized.count,
            metadata: [
                "min": String(format: "%.6f", min),
                "max": String(format: "%.6f", max),
                "mean": String(format: "%.6f", mean),
                "method": config.normalization
            ]
        )

        LoggingHub.emit(
            process: "ui.pipeline.normalization",
            level: .debug,
            message: "Normalized: count=\(normalized.count), range=[\(min)..\(max)]"
        )

        return PipelineStage(
            type: .normalization,
            data: .normalized(normalized),
            metrics: metrics
        )
    }

    private func captureReverseStage(_ energies: [Int]) throws -> (PipelineStage, Data) {
        let startTime = Date()

        let recoveredData = try CapsuleBridge.recoverCapsule(from: energies, config: config)

        let metrics = StageMetrics(
            duration: Date().timeIntervalSince(startTime),
            inputSize: energies.count,
            outputSize: recoveredData.count,
            metadata: [
                "recovered_bytes": "\(recoveredData.count)"
            ]
        )

        LoggingHub.emit(
            process: "ui.pipeline.reverse",
            level: .debug,
            message: "Reverse process: \(energies.count) energies → \(recoveredData.count) bytes"
        )

        let stage = PipelineStage(
            type: .reverseProcess,
            data: .bytes([UInt8](recoveredData)),
            metrics: metrics
        )

        return (stage, recoveredData)
    }

    private func captureRecoveredStage(_ data: Data) -> PipelineStage {
        let startTime = Date()
        let recovered = String(decoding: data, as: UTF8.self)

        let metrics = StageMetrics(
            duration: Date().timeIntervalSince(startTime),
            inputSize: data.count,
            outputSize: recovered.utf8.count,
            metadata: [
                "char_count": "\(recovered.count)",
                "byte_count": "\(recovered.utf8.count)"
            ]
        )

        LoggingHub.emit(
            process: "ui.pipeline.recovered",
            level: .debug,
            message: "Recovered text: \(recovered.utf8.count) bytes"
        )

        return PipelineStage(
            type: .recovered,
            data: .text(recovered),
            metrics: metrics
        )
    }

    // MARK: - Accessor

    public func getCurrentSnapshot() -> PipelineSnapshot? {
        currentSnapshot
    }
}
