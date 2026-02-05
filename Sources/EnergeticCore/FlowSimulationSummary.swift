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

public struct FlowLearningScalars: Sendable {
    public let yHatStatsMean: Float
    public let yHatStatsVariance: Float
    public let yHatStatsMin: Float
    public let yHatStatsMax: Float
    public let nonzeroBins: Int

    public let binLoss: Float
    public let negativeLoss: Float
    public let histogramMatchL1: Float
    public let optionAccuracy: Float?

    public let gainDeltaMean: Float
    public let gainDeltaVariance: Float

    public init(
        yHatStatsMean: Float,
        yHatStatsVariance: Float,
        yHatStatsMin: Float,
        yHatStatsMax: Float,
        nonzeroBins: Int,
        binLoss: Float,
        negativeLoss: Float,
        histogramMatchL1: Float,
        optionAccuracy: Float?,
        gainDeltaMean: Float,
        gainDeltaVariance: Float
    ) {
        self.yHatStatsMean = yHatStatsMean
        self.yHatStatsVariance = yHatStatsVariance
        self.yHatStatsMin = yHatStatsMin
        self.yHatStatsMax = yHatStatsMax
        self.nonzeroBins = nonzeroBins
        self.binLoss = binLoss
        self.negativeLoss = negativeLoss
        self.histogramMatchL1 = histogramMatchL1
        self.optionAccuracy = optionAccuracy
        self.gainDeltaMean = gainDeltaMean
        self.gainDeltaVariance = gainDeltaVariance
    }
}

/// Summary from one GPU-run used by the learning fast path.
public struct FlowSimulationSummary: Sendable {
    /// Optional bins output.
    ///
    /// - Note: This array can be empty if the caller requested `includeHistogram: false` to skip
    ///   histogram accumulation/readback for maximum training throughput.
    public let bins: [Float]
    public let spikeCount: UInt32
    public let particleStepCount: UInt32
    public let completionCount: UInt32

    /// Per-particle completion records.
    ///
    /// - Note: This array can be empty even when `completionCount > 0` if the caller requested
    ///   `includeCompletions: false` to avoid GPU→CPU readback.
    public let completions: [GPUCompletion]

    /// GPU-reduced scalar metrics for the epoch window.
    /// These match the CPU reference implementations in FlowLearningLoop/LossFunctions.
    public let meanRadialMiss: Float
    public let boundaryLoss: Float

    /// Optional weighted yHat computed on GPU (CompletionAggregator equivalent).
    /// Present only when requested.
    public let weightedYHat: [Float]?

    /// Optional GPU-computed learning scalars (losses/stats) based on `weightedYHat`.
    /// Present only when explicitly requested by the caller.
    public let learningScalars: FlowLearningScalars?

    public init(
        bins: [Float],
        spikeCount: UInt32,
        particleStepCount: UInt32,
        completionCount: UInt32,
        completions: [GPUCompletion],
        meanRadialMiss: Float = 0,
        boundaryLoss: Float = 0,
        weightedYHat: [Float]? = nil,
        learningScalars: FlowLearningScalars? = nil
    ) {
        self.bins = bins
        self.spikeCount = spikeCount
        self.particleStepCount = particleStepCount
        self.completionCount = completionCount
        self.completions = completions
        self.meanRadialMiss = meanRadialMiss
        self.boundaryLoss = boundaryLoss
        self.weightedYHat = weightedYHat
        self.learningScalars = learningScalars
    }
}
