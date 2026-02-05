import Foundation

/// Completion record produced by the fast-path GPU simulator.
///
/// Note: This is intentionally a simple POD shape to match Metal buffer layouts.
public struct GPUCompletion: Sendable {
    public let particleID: Int32
    public let bin: Int32          // -1 if no completion
    public let x: Float
    public let y: Float
    public let energy: Float       // raw energy at completion (gain application is handled by the aggregator)
    public let spiked: UInt8       // 0/1
    public let initialBin: Int32   // -1 if unknown/not provided

    public init(particleID: Int32, bin: Int32, x: Float, y: Float, energy: Float, spiked: UInt8, initialBin: Int32) {
        self.particleID = particleID
        self.bin = bin
        self.x = x
        self.y = y
        self.energy = energy
        self.spiked = spiked
        self.initialBin = initialBin
    }
}

/// Summary from one GPU-run used by the learning fast path.
public struct FlowSimulationSummary: Sendable {
    public let bins: [Float]
    public let spikeCount: UInt32
    public let particleStepCount: UInt32
    public let completionCount: UInt32
    public let completions: [GPUCompletion]

    /// Optional weighted yHat computed on GPU (CompletionAggregator equivalent).
    /// Present only when requested.
    public let weightedYHat: [Float]?

    public init(
        bins: [Float],
        spikeCount: UInt32,
        particleStepCount: UInt32,
        completionCount: UInt32,
        completions: [GPUCompletion],
        weightedYHat: [Float]? = nil
    ) {
        self.bins = bins
        self.spikeCount = spikeCount
        self.particleStepCount = particleStepCount
        self.completionCount = completionCount
        self.completions = completions
        self.weightedYHat = weightedYHat
    }
}
