import Foundation

// MARK: - Completion Event

/// Represents a single particle completion at the boundary
public struct CompletionEvent: Sendable {
    public let particleID: Int
    public let binIndex: Int
    public let position: SIMD2<Float>
    public let energy: Float
    public let spiked: Bool
    public let initialBinIndex: Int?  // Seed's initial bin for alignment weight

    public init(particleID: Int, binIndex: Int, position: SIMD2<Float>, energy: Float, spiked: Bool, initialBinIndex: Int? = nil) {
        self.particleID = particleID
        self.binIndex = binIndex
        self.position = position
        self.energy = energy
        self.spiked = spiked
        self.initialBinIndex = initialBinIndex
    }
}

// MARK: - Learnable Parameters

/// Mutable parameters that are updated during learning
public struct LearnableParameters: Sendable {
    public var gains: [Float]           // Per-bin gains [B]
    public var lifThreshold: Float      // LIF threshold θ
    public var radialBias: Float        // Dynamics radial bias β_r
    public var spikeKick: Float         // Spike kick magnitude κ

    public init(bins: Int, lifThreshold: Float, radialBias: Float, spikeKick: Float) {
        self.gains = [Float](repeating: 1.0, count: bins)
        self.lifThreshold = lifThreshold
        self.radialBias = radialBias
        self.spikeKick = spikeKick
    }
}

// MARK: - Learning Metrics

/// Metrics collected during one training epoch
public struct LearningMetrics: Sendable, Codable {
    public let epoch: Int
    public let totalLoss: Float
    public let binLoss: Float
    public let spikeLoss: Float
    public let boundaryLoss: Float
    public let spikeRate: Float
    public let completionRate: Float
    public let meanRadialMiss: Float
    public let nonzeroBins: Int
    public let yHatStats: BinStatistics
    public let paramDeltas: ParameterDeltas

    public init(epoch: Int, totalLoss: Float, binLoss: Float, spikeLoss: Float, boundaryLoss: Float, spikeRate: Float, completionRate: Float, meanRadialMiss: Float, nonzeroBins: Int, yHatStats: BinStatistics, paramDeltas: ParameterDeltas) {
        self.epoch = epoch
        self.totalLoss = totalLoss
        self.binLoss = binLoss
        self.spikeLoss = spikeLoss
        self.boundaryLoss = boundaryLoss
        self.spikeRate = spikeRate
        self.completionRate = completionRate
        self.meanRadialMiss = meanRadialMiss
        self.nonzeroBins = nonzeroBins
        self.yHatStats = yHatStats
        self.paramDeltas = paramDeltas
    }

    public struct BinStatistics: Sendable, Codable {
        public let mean: Float
        public let variance: Float
        public let min: Float
        public let max: Float

        public init(mean: Float, variance: Float, min: Float, max: Float) {
            self.mean = mean
            self.variance = variance
            self.min = min
            self.max = max
        }
    }

    public struct ParameterDeltas: Sendable, Codable {
        public let gainMean: Float
        public let gainVariance: Float
        public let lifThreshold: Float
        public let radialBias: Float
        public let spikeKick: Float

        public init(gainMean: Float, gainVariance: Float, lifThreshold: Float, radialBias: Float, spikeKick: Float) {
            self.gainMean = gainMean
            self.gainVariance = gainVariance
            self.lifThreshold = lifThreshold
            self.radialBias = radialBias
            self.spikeKick = spikeKick
        }
    }
}

// MARK: - Learning State

/// Complete learning state (for checkpointing)
public struct RouterLearningState: Sendable, Codable {
    public let epoch: Int
    public let params: SerializableParameters
    public let metrics: LearningMetrics

    public init(epoch: Int, params: SerializableParameters, metrics: LearningMetrics) {
        self.epoch = epoch
        self.params = params
        self.metrics = metrics
    }

    public struct SerializableParameters: Sendable, Codable {
        public let gains: [Float]
        public let lifThreshold: Float
        public let radialBias: Float
        public let spikeKick: Float

        public init(gains: [Float], lifThreshold: Float, radialBias: Float, spikeKick: Float) {
            self.gains = gains
            self.lifThreshold = lifThreshold
            self.radialBias = radialBias
            self.spikeKick = spikeKick
        }

        public init(from params: LearnableParameters) {
            self.gains = params.gains
            self.lifThreshold = params.lifThreshold
            self.radialBias = params.radialBias
            self.spikeKick = params.spikeKick
        }
    }
}

// MARK: - Aggregator Configuration

#if canImport(SharedInfrastructure)
import SharedInfrastructure

public struct AggregatorConfig {
    public let sigmaR: Float
    public let sigmaE: Float
    public let alpha: Float
    public let beta: Float
    public let gamma: Float
    public let tau: Float
    public let radius: Float

    public init(sigmaR: Float, sigmaE: Float, alpha: Float, beta: Float, gamma: Float, tau: Float, radius: Float) {
        self.sigmaR = sigmaR
        self.sigmaE = sigmaE
        self.alpha = alpha
        self.beta = beta
        self.gamma = gamma
        self.tau = tau
        self.radius = radius
    }

    public static func from(_ cfg: ConfigRoot.Router.Flow.Learning, radius: Float) -> AggregatorConfig {
        let agg = cfg.aggregator
        return AggregatorConfig(
            sigmaR: Float(agg.sigmaR),
            sigmaE: Float(agg.sigmaE),
            alpha: Float(agg.alpha),
            beta: Float(agg.beta),
            gamma: Float(agg.gamma),
            tau: Float(agg.tau),
            radius: radius
        )
    }
}
#endif
