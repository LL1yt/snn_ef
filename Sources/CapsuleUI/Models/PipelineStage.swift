import Foundation
import CapsuleCore
import SharedInfrastructure

/// Represents a type of transformation stage in the capsule pipeline
public enum PipelineStageType: String, Sendable, Codable, CaseIterable {
    case input              // Original UTF-8 text input
    case blockStructure     // Header + Data + Padding structure
    case prpTransform       // PRP/Feistel transformation applied
    case capsuleBlock       // Final capsule block (post-PRP)
    case baseConversion     // Conversion to base-B digits
    case printableString    // Printable string representation
    case energiesMapping    // Energy values [1..B]
    case normalization      // Normalized values [0..1]
    case reverseProcess     // Reverse transformation (energies → bytes)
    case recovered          // Recovered/decoded text with CRC check
}

/// Container for stage-specific data of various types
public enum StageData: Sendable {
    case text(String)
    case bytes([UInt8])
    case header(header: CapsuleHeader, payload: [UInt8], paddingSize: Int)
    case block(CapsuleBlock)
    case digits([Int])
    case printable(String)
    case energies([Int])
    case normalized([Double])

    /// Extract size information for metrics
    public var sizeInfo: (input: Int, output: Int) {
        switch self {
        case .text(let str):
            let byteCount = str.utf8.count
            return (byteCount, byteCount)
        case .bytes(let b):
            return (b.count, b.count)
        case .header(_, let payload, let paddingSize):
            return (payload.count, CapsuleHeader.byteCount + payload.count + paddingSize)
        case .block(let b):
            return (b.bytes.count, b.bytes.count)
        case .digits(let d):
            return (d.count, d.count)
        case .printable(let s):
            return (s.count, s.count)
        case .energies(let e):
            return (e.count, e.count)
        case .normalized(let n):
            return (n.count, n.count)
        }
    }
}

/// Performance and size metrics for a pipeline stage
public struct StageMetrics: Sendable, Codable {
    public let duration: TimeInterval      // Execution time in seconds
    public let inputSize: Int              // Input data size
    public let outputSize: Int             // Output data size
    public let metadata: [String: String]  // Additional contextual info

    public init(duration: TimeInterval, inputSize: Int, outputSize: Int, metadata: [String: String] = [:]) {
        self.duration = duration
        self.inputSize = inputSize
        self.outputSize = outputSize
        self.metadata = metadata
    }
}

/// Represents a single transformation stage in the pipeline
public struct PipelineStage: Sendable, Identifiable {
    public let id: UUID
    public let type: PipelineStageType
    public let timestamp: Date
    public let data: StageData
    public let metrics: StageMetrics
    public let error: String?  // Error description if stage failed

    public init(
        id: UUID = UUID(),
        type: PipelineStageType,
        timestamp: Date = Date(),
        data: StageData,
        metrics: StageMetrics,
        error: String? = nil
    ) {
        self.id = id
        self.type = type
        self.timestamp = timestamp
        self.data = data
        self.metrics = metrics
        self.error = error
    }

    /// Returns true if this stage completed without errors
    public var isSuccessful: Bool {
        error == nil
    }
}
