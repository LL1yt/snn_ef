import Foundation

#if canImport(SharedInfrastructure)
import SharedInfrastructure
#endif

// MARK: - Learning Configuration

public struct LearningConfig {
    public let enabled: Bool
    public let epochs: Int
    public let stepsPerEpoch: Int
    public let targetSpikeRate: Float
    public let logEvery: Int
    public let logEveryUI: Int
    public let learningRates: LearningRates
    public let lossWeights: LossWeights
    public let negative: NegativeConfig
    public let bounds: Bounds
    public let aggregatorConfig: AggregatorConfig

    public init(
        enabled: Bool,
        epochs: Int,
        stepsPerEpoch: Int,
        targetSpikeRate: Float,
        logEvery: Int,
        logEveryUI: Int,
        learningRates: LearningRates,
        lossWeights: LossWeights,
        negative: NegativeConfig = .disabled,
        bounds: Bounds,
        aggregatorConfig: AggregatorConfig
    ) {
        self.enabled = enabled
        self.epochs = epochs
        self.stepsPerEpoch = stepsPerEpoch
        self.targetSpikeRate = targetSpikeRate
        self.logEvery = logEvery
        self.logEveryUI = logEveryUI
        self.learningRates = learningRates
        self.lossWeights = lossWeights
        self.negative = negative
        self.bounds = bounds
        self.aggregatorConfig = aggregatorConfig
    }

    public struct LearningRates {
        public let gain: Float
        public let lif: Float
        public let dynamics: Float

        public init(gain: Float, lif: Float, dynamics: Float) {
            self.gain = gain
            self.lif = lif
            self.dynamics = dynamics
        }
    }

    public struct LossWeights {
        public let spike: Float
        public let boundary: Float

        public init(spike: Float, boundary: Float) {
            self.spike = spike
            self.boundary = boundary
        }
    }

    public struct NegativeConfig {
        public let enabled: Bool
        public let weight: Float
        public let margin: Float

        public init(enabled: Bool, weight: Float, margin: Float) {
            self.enabled = enabled
            self.weight = weight
            self.margin = margin
        }

        public static let disabled = NegativeConfig(enabled: false, weight: 0, margin: 0)
    }

    public struct Bounds {
        public let theta: (min: Float, max: Float)
        public let radialBias: (min: Float, max: Float)
        public let spikeKick: (min: Float, max: Float)
        public let gain: (min: Float, max: Float)

        public init(theta: (Float, Float), radialBias: (Float, Float), spikeKick: (Float, Float), gain: (Float, Float)) {
            self.theta = theta
            self.radialBias = radialBias
            self.spikeKick = spikeKick
            self.gain = gain
        }
    }

    #if canImport(SharedInfrastructure)
    public static func from(_ cfg: ConfigRoot.Router.Flow, radius: Float) -> LearningConfig {
        let learning = cfg.learning
        return LearningConfig(
            enabled: learning.enabled,
            epochs: learning.epochs,
            stepsPerEpoch: learning.stepsPerEpoch,
            targetSpikeRate: Float(learning.targetSpikeRate),
            logEvery: learning.logEvery,
            logEveryUI: learning.logEveryUI,
            learningRates: .init(
                gain: Float(learning.lr.gain),
                lif: Float(learning.lr.lif),
                dynamics: Float(learning.lr.dynamics)
            ),
            lossWeights: .init(
                spike: Float(learning.weights.spike),
                boundary: Float(learning.weights.boundary)
            ),
            negative: .init(
                enabled: learning.negative.enabled,
                weight: Float(learning.negative.weight),
                margin: Float(learning.negative.margin)
            ),
            bounds: .init(
                theta: (Float(learning.bounds.theta[0]), Float(learning.bounds.theta[1])),
                radialBias: (Float(learning.bounds.radialBias[0]), Float(learning.bounds.radialBias[1])),
                spikeKick: (Float(learning.bounds.spikeKick[0]), Float(learning.bounds.spikeKick[1])),
                gain: (Float(learning.bounds.gain[0]), Float(learning.bounds.gain[1]))
            ),
            aggregatorConfig: AggregatorConfig.from(learning, radius: radius)
        )
    }
    #endif
}

// MARK: - Learning Loop

/// Main coordinator for the learning pipeline
public final class FlowLearningLoop {
    private let flowConfig: FlowConfig
    private let learningConfig: LearningConfig
    private var params: LearnableParameters
    private var router: FlowRouter
    private var previousBinLoss: Float = .infinity

    public init(flowConfig: FlowConfig, learningConfig: LearningConfig, seed: UInt64) {
        self.flowConfig = flowConfig
        self.learningConfig = learningConfig
        self.params = LearnableParameters(
            bins: flowConfig.bins,
            lifThreshold: flowConfig.lif.threshold,
            radialBias: flowConfig.dynamics.radialBias,
            spikeKick: flowConfig.dynamics.spikeKick
        )
        self.router = FlowRouter(cfg: flowConfig, seed: seed)
    }

    /// Runs one epoch of learning
    public func runEpoch(
        epoch: Int,
        energies: [Float],
        targets: [Float],
        wrongTargets: [[Float]] = [],
        optionTargets: [[Float]] = [],
        correctIndex: Int? = nil,
        applyUpdates: Bool = true,
        emitLog: Bool = true
    ) -> LearningMetrics {
        // Create seeds from energies
        let seeds = FlowSeeds.makeSeeds(
            energies: energies,
            layout: flowConfig.seedLayout,
            radius: flowConfig.seedRadius,
            bins: flowConfig.bins
        )
        precondition(params.gains.count == flowConfig.bins, "gains count must match bins")

        // Run simulation with event tracking
        var state = FlowState(step: 0, particles: seeds, bins: flowConfig.bins)
        var allCompletions: [CompletionEvent] = []
        var totalSpikes = 0
        var totalParticleSteps = 0
        let initialParticleCount = seeds.count
        let trackedIDs = Array(seeds.prefix(3).map { $0.id })
        var traceSteps: [Int: [TraceStep]] = [:]
        var pathPoints: [Int: [PathPoint]] = [:]
        for id in trackedIDs { traceSteps[id] = [] }
        for id in trackedIDs { pathPoints[id] = [] }

        // Store initial bin indices for alignment weight
        var initialBins: [Int: Int] = [:]
        for (idx, seed) in seeds.enumerated() {
            let theta = atan2(seed.pos.y, seed.pos.x)
            let binIdx = FlowProjector.binIndex(theta: theta, bins: flowConfig.bins)
            initialBins[seed.id] = binIdx
        }

        for step in 0..<learningConfig.stepsPerEpoch {
            guard !state.isEmpty else { break }

            let events = router.stepWithEvents(state: &state, gains: params.gains)

            for event in events {
                totalParticleSteps += 1
                if event.spiked {
                    totalSpikes += 1
                }
                if traceSteps[event.id] != nil {
                    let r = length(event.pos)
                    let theta = atan2(event.pos.y, event.pos.x)
                    let speed = length(event.vel)
                    let dir = normalizeOrZero(event.pos)
                    let radialSpeed = (dir.x * event.vel.x) + (dir.y * event.vel.y)
                    let stepInfo = TraceStep(
                        t: step,
                        r: r,
                        theta: theta,
                        energy: event.energy,
                        V: event.V,
                        spiked: event.spiked,
                        bin: event.projectedBin,
                        speed: speed,
                        radialSpeed: radialSpeed
                    )
                    traceSteps[event.id]?.append(stepInfo)
                    let point = PathPoint(
                        t: step,
                        x: event.pos.x,
                        y: event.pos.y,
                        spiked: event.spiked,
                        bin: event.projectedBin,
                        speed: speed,
                        radialSpeed: radialSpeed
                    )
                    pathPoints[event.id]?.append(point)
                }
                if let bin = event.projectedBin {
                    let completion = CompletionEvent(
                        particleID: event.id,
                        binIndex: bin,
                        position: event.pos,
                        energy: event.energy,
                        spiked: event.spiked,
                        initialBinIndex: initialBins[event.id]
                    )
                    allCompletions.append(completion)
                }
            }
        }

        // Aggregate completions
        let yHat = CompletionAggregator.aggregate(
            completions: allCompletions,
            targets: targets,
            config: learningConfig.aggregatorConfig,
            bins: flowConfig.bins,
            gains: params.gains
        )
        // Normalize for loss computation (keep raw for UI/metrics)
        let yHatNorm = normalizeBins(yHat)
        let targetNorm = normalizeBins(targets)

        // Compute losses
        let binLoss = LossFunctions.binLoss(yHat: yHatNorm, target: targetNorm, gains: params.gains)
        let negativeLoss: Float
        if learningConfig.negative.enabled, !wrongTargets.isEmpty {
            let wrongNorm = wrongTargets.map { normalizeBins($0) }
            let base = LossFunctions.negativeMarginLoss(yHat: yHatNorm, wrongTargets: wrongNorm, margin: learningConfig.negative.margin)
            negativeLoss = base * learningConfig.negative.weight
        } else {
            negativeLoss = 0
        }
        let spikeRate = totalParticleSteps > 0 ? Float(totalSpikes) / Float(totalParticleSteps) : 0
        let spikeLoss = LossFunctions.spikeRateLoss(observed: spikeRate, target: learningConfig.targetSpikeRate)
        let boundaryLoss = LossFunctions.boundaryLoss(completions: allCompletions, radius: flowConfig.radius)
        let totalLoss = LossFunctions.totalLoss(
            binLoss: binLoss,
            negativeLoss: negativeLoss,
            spikeLoss: spikeLoss,
            boundaryLoss: boundaryLoss,
            spikeWeight: learningConfig.lossWeights.spike,
            boundaryWeight: learningConfig.lossWeights.boundary
        )

        let optionAccuracy: Float?
        if let correctIndex, !optionTargets.isEmpty {
            let distances = optionTargets.map { LossFunctions.l2Distance(yHat, $0) }
            let minIdx = distances.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
            optionAccuracy = (minIdx == correctIndex) ? 1.0 : 0.0
        } else {
            optionAccuracy = nil
        }

        // Compute metrics
        let completionRate = initialParticleCount > 0 ? Float(allCompletions.count) / Float(initialParticleCount) : 0
        let meanRadialMiss = computeMeanRadialMiss(completions: allCompletions, radius: flowConfig.radius)
        let nonzeroBins = yHat.filter { $0 > 0 }.count
        let yHatStats = computeBinStatistics(yHat)

        let paramDeltas: LearningMetrics.ParameterDeltas
        if applyUpdates {
            // Store old parameters for delta computation
            let oldGains = params.gains
            let oldThreshold = params.lifThreshold
            let oldRadialBias = params.radialBias
            let oldSpikeKick = params.spikeKick

            // Update parameters
            ParameterUpdater.updateGains(
                gains: &params.gains,
                yHat: yHatNorm,
                target: targetNorm,
                learningRate: learningConfig.learningRates.gain,
                bounds: learningConfig.bounds.gain
            )

            ParameterUpdater.updateLifThreshold(
                threshold: &params.lifThreshold,
                observedRate: spikeRate,
                targetRate: learningConfig.targetSpikeRate,
                learningRate: learningConfig.learningRates.lif,
                bounds: learningConfig.bounds.theta
            )

            ParameterUpdater.updateRadialBias(
                radialBias: &params.radialBias,
                completionRate: completionRate,
                meanRadialMiss: meanRadialMiss,
                learningRate: learningConfig.learningRates.dynamics,
                bounds: learningConfig.bounds.radialBias
            )

            let binLossTrend = binLoss - previousBinLoss
            ParameterUpdater.updateSpikeKick(
                spikeKick: &params.spikeKick,
                meanRadialMiss: meanRadialMiss,
                binLossTrend: binLossTrend,
                learningRate: learningConfig.learningRates.dynamics,
                bounds: learningConfig.bounds.spikeKick
            )

            previousBinLoss = binLoss

            // Compute parameter deltas
            let gainDeltas = zip(oldGains, params.gains).map { $1 - $0 }
            let gainDeltaMean = gainDeltas.reduce(0, +) / Float(gainDeltas.count)
            let gainDeltaVariance = gainDeltas.map { d in (d - gainDeltaMean) * (d - gainDeltaMean) }.reduce(0, +) / Float(gainDeltas.count)

            paramDeltas = LearningMetrics.ParameterDeltas(
                gainMean: gainDeltaMean,
                gainVariance: gainDeltaVariance,
                lifThreshold: params.lifThreshold - oldThreshold,
                radialBias: params.radialBias - oldRadialBias,
                spikeKick: params.spikeKick - oldSpikeKick
            )

            // Update router config with new parameters (for next epoch)
            updateRouterConfig()
        } else {
            paramDeltas = LearningMetrics.ParameterDeltas(gainMean: 0, gainVariance: 0, lifThreshold: 0, radialBias: 0, spikeKick: 0)
        }

        let metrics = LearningMetrics(
            epoch: epoch,
            totalLoss: totalLoss,
            binLoss: binLoss,
            negativeLoss: negativeLoss,
            spikeLoss: spikeLoss,
            boundaryLoss: boundaryLoss,
            spikeRate: spikeRate,
            completionRate: completionRate,
            meanRadialMiss: meanRadialMiss,
            nonzeroBins: nonzeroBins,
            yHatStats: yHatStats,
            paramDeltas: paramDeltas,
            optionAccuracy: optionAccuracy
        )

#if canImport(SharedInfrastructure)
        if emitLog && (epoch % max(1, learningConfig.logEveryUI) == 0) {
            let traces = trackedIDs.compactMap { id -> LearningLogPayload.Trace? in
                guard let steps = traceSteps[id] else { return nil }
                return LearningLogPayload.Trace(id: id, steps: steps)
            }
            let paths = trackedIDs.compactMap { id -> LearningLogPayload.Path? in
                guard let points = pathPoints[id] else { return nil }
                return LearningLogPayload.Path(id: id, points: points)
            }
            emitLearningLog(epoch: epoch, metrics: metrics, params: params, yHat: yHat, targets: targets, traces: traces, paths: paths)
        }
#endif

        return metrics
    }

    /// Returns current learnable parameters
    public func getParameters() -> LearnableParameters {
        return params
    }

    /// Loads parameters from a checkpoint
    public func loadParameters(_ params: LearnableParameters) {
        self.params = params
        updateRouterConfig()
    }

    // MARK: - Private Helpers

    private func updateRouterConfig() {
        // Create new FlowConfig with updated parameters
        let updatedLIF = FlowConfig.LIF(
            decay: flowConfig.lif.decay,
            threshold: params.lifThreshold,
            resetValue: flowConfig.lif.resetValue,
            surrogate: flowConfig.lif.surrogate
        )
        let updatedDynamics = FlowConfig.Dynamics(
            radialBias: params.radialBias,
            spikeKick: params.spikeKick,
            noiseStdPos: flowConfig.dynamics.noiseStdPos,
            noiseStdDir: flowConfig.dynamics.noiseStdDir,
            maxSpeed: flowConfig.dynamics.maxSpeed,
            energyAlpha: flowConfig.dynamics.energyAlpha,
            energyFloor: flowConfig.dynamics.energyFloor
        )
        let updatedConfig = FlowConfig(
            T: flowConfig.T,
            radius: flowConfig.radius,
            bins: flowConfig.bins,
            seedLayout: flowConfig.seedLayout,
            seedRadius: flowConfig.seedRadius,
            finalWeightPower: flowConfig.finalWeightPower,
            lif: updatedLIF,
            dynamics: updatedDynamics
        )
        router.updateConfig(updatedConfig)
    }

    private func computeMeanRadialMiss(completions: [CompletionEvent], radius: Float) -> Float {
        guard !completions.isEmpty else { return 0 }
        let sum: Float = completions.reduce(Float(0.0)) { (sum: Float, comp: CompletionEvent) -> Float in
            let r = length(comp.position)
            let diff = r - radius
            return sum + Swift.abs(diff)
        }
        return sum / Float(completions.count)
    }

    private func computeBinStatistics(_ bins: [Float]) -> LearningMetrics.BinStatistics {
        guard !bins.isEmpty else {
            return LearningMetrics.BinStatistics(mean: 0, variance: 0, min: 0, max: 0)
        }

        let mean = bins.reduce(0, +) / Float(bins.count)
        let variance = bins.map { b in (b - mean) * (b - mean) }.reduce(0, +) / Float(bins.count)
        let min = bins.min() ?? 0
        let max = bins.max() ?? 0

        return LearningMetrics.BinStatistics(mean: mean, variance: variance, min: min, max: max)
    }

#if canImport(SharedInfrastructure)
    private func normalizeBins(_ bins: [Float]) -> [Float] {
        let sum = bins.reduce(0, +)
        guard sum > 0 else { return bins }
        return bins.map { $0 / sum }
    }
#else
    private func normalizeBins(_ bins: [Float]) -> [Float] {
        let sum = bins.reduce(0, +)
        guard sum > 0 else { return bins }
        return bins.map { $0 / sum }
    }
#endif
#if canImport(SharedInfrastructure)
    private static let learningLogPrefix = "learning.metrics "

    private func emitLearningLog(
        epoch: Int,
        metrics: LearningMetrics,
        params: LearnableParameters,
        yHat: [Float],
        targets: [Float],
        traces: [LearningLogPayload.Trace],
        paths: [LearningLogPayload.Path]
    ) {
        let gainCount = Float(max(params.gains.count, 1))
        let gainMean = params.gains.reduce(0, +) / gainCount
        let gainVar = params.gains.map { diff in
            let delta = diff - gainMean
            return delta * delta
        }.reduce(0, +) / gainCount

        let histogram: LearningLogPayload.Histogram?
        if yHat.count == flowConfig.bins {
            let targetPayload = targets.count == flowConfig.bins ? targets : nil
            histogram = LearningLogPayload.Histogram(yHat: yHat, target: targetPayload)
        } else {
            histogram = nil
        }

        let payload = LearningLogPayload(
            epoch: epoch,
            loss: .init(total: metrics.totalLoss, bins: metrics.binLoss, negative: metrics.negativeLoss, spike: metrics.spikeLoss, boundary: metrics.boundaryLoss),
            rates: .init(spike: metrics.spikeRate, completion: metrics.completionRate),
            radius: .init(meanMiss: metrics.meanRadialMiss, R: flowConfig.radius),
            optionAccuracy: metrics.optionAccuracy,
            params: .init(
                lif: params.lifThreshold,
                radialBias: params.radialBias,
                spikeKick: params.spikeKick,
                gainMean: gainMean,
                gainVariance: gainVar
            ),
            bins: .init(
                nonzero: metrics.nonzeroBins,
                mean: metrics.yHatStats.mean,
                variance: metrics.yHatStats.variance,
                min: metrics.yHatStats.min,
                max: metrics.yHatStats.max
            ),
            histogram: histogram,
            traces: traces,
            paths: paths
        )

        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        LoggingHub.emit(process: "trainer.loop", level: .info, message: Self.learningLogPrefix + json)
    }

    private struct LearningLogPayload: Codable {
        struct Loss: Codable { let total: Float; let bins: Float; let negative: Float; let spike: Float; let boundary: Float }
        struct Rates: Codable { let spike: Float; let completion: Float }
        struct Radius: Codable { let meanMiss: Float; let R: Float }
        struct Params: Codable { let lif: Float; let radialBias: Float; let spikeKick: Float; let gainMean: Float; let gainVariance: Float }
        struct Bins: Codable { let nonzero: Int; let mean: Float; let variance: Float; let min: Float; let max: Float }
        struct Histogram: Codable { let yHat: [Float]; let target: [Float]? }
        struct TraceStep: Codable {
            let t: Int
            let r: Float
            let theta: Float
            let energy: Float
            let V: Float
            let spiked: Bool
            let bin: Int?
            let speed: Float
            let radialSpeed: Float
        }
        struct Trace: Codable { let id: Int; let steps: [TraceStep] }
        struct PathPoint: Codable {
            let t: Int
            let x: Float
            let y: Float
            let spiked: Bool
            let bin: Int?
            let speed: Float
            let radialSpeed: Float
        }
        struct Path: Codable { let id: Int; let points: [PathPoint] }

        let epoch: Int
        let loss: Loss
        let rates: Rates
        let radius: Radius
        let optionAccuracy: Float?
        let params: Params
        let bins: Bins
        let histogram: Histogram?
        let traces: [Trace]
        let paths: [Path]
    }

    private typealias TraceStep = LearningLogPayload.TraceStep
    private typealias PathPoint = LearningLogPayload.PathPoint
#endif
}
