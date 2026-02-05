import Foundation

#if canImport(SharedInfrastructure)
import SharedInfrastructure
#endif

// MARK: - Learning Configuration

public struct LearningConfig {
    public enum OutputSignal: String, Sendable {
        case completionCPU = "completion_cpu"
        case weightedBinsGPU = "weighted_bins_gpu"
    }

    public let enabled: Bool
    public let epochs: Int
    public let stepsPerEpoch: Int
    public let targetSpikeRate: Float
    public let logEvery: Int
    public let logEveryUI: Int
    public let outputSignal: OutputSignal
    public let learningRates: LearningRates
    public let lossWeights: LossWeights
    public let negative: NegativeConfig
    public let gainErrorPower: Float
    public let gainErrorScale: Float
    public let bounds: Bounds
    public let aggregatorConfig: AggregatorConfig

    public init(
        enabled: Bool,
        epochs: Int,
        stepsPerEpoch: Int,
        targetSpikeRate: Float,
        logEvery: Int,
        logEveryUI: Int,
        outputSignal: OutputSignal = .completionCPU,
        learningRates: LearningRates,
        lossWeights: LossWeights,
        negative: NegativeConfig = .disabled,
        gainErrorPower: Float = 1.0,
        gainErrorScale: Float = 1.0,
        bounds: Bounds,
        aggregatorConfig: AggregatorConfig
    ) {
        self.enabled = enabled
        self.epochs = epochs
        self.stepsPerEpoch = stepsPerEpoch
        self.targetSpikeRate = targetSpikeRate
        self.logEvery = logEvery
        self.logEveryUI = logEveryUI
        self.outputSignal = outputSignal
        self.learningRates = learningRates
        self.lossWeights = lossWeights
        self.negative = negative
        self.gainErrorPower = gainErrorPower
        self.gainErrorScale = gainErrorScale
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
            outputSignal: OutputSignal(rawValue: (learning.outputSignal ?? "completion_cpu").lowercased()) ?? .completionCPU,
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
            gainErrorPower: Float(learning.gainErrorPower),
            gainErrorScale: Float(learning.gainErrorScale),
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
    private let retriever: HistogramRetriever?


    public init(flowConfig: FlowConfig, learningConfig: LearningConfig, seed: UInt64, retriever: HistogramRetriever? = nil) {
        self.flowConfig = flowConfig
        self.learningConfig = learningConfig
        self.params = LearnableParameters(
            bins: flowConfig.bins,
            lifThreshold: flowConfig.lif.threshold,
            radialBias: flowConfig.dynamics.radialBias,
            spikeKick: flowConfig.dynamics.spikeKick
        )
        self.router = FlowRouter(cfg: flowConfig, seed: seed)
        self.retriever = retriever
    }

    /// Runs one epoch of learning
    public func runEpoch(
        epoch: Int,
        energies: [Float],
        targets: [Float],
        wrongTargets: [[Float]] = [],
        optionTargets: [[Float]] = [],
        correctIndex: Int? = nil,
        inputText: String? = nil,
        answerText: String? = nil,
        applyUpdates: Bool = true,
        emitLog: Bool = true,
        // Performance: allow callers (e.g. CLI dataset cache) to provide pre-normalized targets.
        targetsNormOverride: [Float]? = nil,
        wrongTargetsNormOverride: [[Float]]? = nil
    ) -> LearningMetrics {
        // Create seeds from energies
        let seeds = FlowSeeds.makeSeeds(
            energies: energies,
            layout: flowConfig.seedLayout,
            radius: flowConfig.seedRadius,
            bins: flowConfig.bins
        )
        precondition(params.gains.count == flowConfig.bins, "gains count must match bins")

        // Decide which log payloads to emit.
        // - needsTraceLog triggers the slow path (per-step events/traces), so keep it rare.
        // - needsMetricsLog is served by the fast path.
        let needsMetricsLog = emitLog && (epoch % max(1, learningConfig.logEvery) == 0)
        let needsTraceLog = emitLog && (
            (learningConfig.logEveryUI <= 1)
                || (epoch > 0 && (epoch % learningConfig.logEveryUI == 0))
        )
        let needsAnyLogPayload = needsMetricsLog || needsTraceLog

        var allCompletions: [CompletionEvent] = []
        var totalSpikes: UInt32 = 0
        var totalParticleSteps: UInt32 = 0
        var completionCount: UInt32 = 0
        let initialParticleCount = seeds.count

        // Predicted signal for learning/UI: summed energy histogram over output bins.
        // - Fast path: GPU provides `summary.bins` (sum of completion energies per bin, gain-adjusted).
        // - Slow path: we accumulate from completion events.
        var predictedHistogram: [Float]? = nil

        var gpuMeanRadialMiss: Float? = nil
        var gpuBoundaryLoss: Float? = nil

        let inputHistogram: [Float]? = needsAnyLogPayload ? HistogramBuilder.fromEnergies(energies, bins: flowConfig.bins) : nil

        // Initial bins for alignment weight (dense by seed index; store -1 when unknown)
        var initialBinsByIndex = [Int32](repeating: -1, count: seeds.count)
        let layout = flowConfig.seedLayout.lowercased()
        let seedCount = max(1, seeds.count)
        for (idx, seed) in seeds.enumerated() {
            let binIdx: Int
            if layout == "ring" {
                binIdx = (idx * flowConfig.bins) / seedCount
            } else {
                let theta = atan2(seed.pos.y, seed.pos.x)
                binIdx = FlowProjector.binIndex(theta: theta, bins: flowConfig.bins)
            }
            initialBinsByIndex[idx] = Int32(binIdx)
        }

        // Slow path: per-step events + trace collection (UI only)
        let trackedIDs = Array(seeds.prefix(3).map { $0.id })
        var traceSteps: [Int: [TraceStep]] = [:]
        var pathPoints: [Int: [PathPoint]] = [:]
        var predictedBins: [Int]? = nil
        var projectedHistogram: [Float]? = nil
        if needsTraceLog {
            for id in trackedIDs { traceSteps[id] = [] }
            for id in trackedIDs { pathPoints[id] = [] }

            var lastPosByID = [SIMD2<Float>](repeating: SIMD2<Float>(0, 0), count: initialParticleCount)
            for seed in seeds {
                precondition(seed.id >= 0 && seed.id < lastPosByID.count, "seed id out of range for lastPosByID")
                lastPosByID[seed.id] = seed.pos
            }

            var state = FlowState(step: 0, particles: seeds, bins: flowConfig.bins)
            for step in 0..<learningConfig.stepsPerEpoch {
                guard !state.isEmpty else { break }

                let events = router.stepWithEvents(state: &state, gains: params.gains)
                for event in events {
                    totalParticleSteps &+= 1
                    if event.spiked {
                        totalSpikes &+= 1
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
                    precondition(event.id >= 0 && event.id < lastPosByID.count, "event id out of range for lastPosByID")
                    lastPosByID[event.id] = event.pos
                    if let bin = event.projectedBin {
                        let initialBinIndex: Int?
                        if event.id >= 0 && event.id < initialBinsByIndex.count {
                            let v = Int(initialBinsByIndex[event.id])
                            initialBinIndex = v >= 0 ? v : nil
                        } else {
                            initialBinIndex = nil
                        }
                        let completion = CompletionEvent(
                            particleID: event.id,
                            binIndex: bin,
                            position: event.pos,
                            energy: event.energy,
                            spiked: event.spiked,
                            initialBinIndex: initialBinIndex
                        )
                        allCompletions.append(completion)
                    }
                }
            }
            completionCount = UInt32(allCompletions.count)
            if initialParticleCount > 0 {
                var binsByID = [Int](repeating: 0, count: initialParticleCount)
                var projected = [Float](repeating: 0, count: flowConfig.bins)
                let radius = max(flowConfig.radius, 1e-6)
                for id in 0..<initialParticleCount {
                    let pos = lastPosByID[id]
                    let r = length(pos)
                    let theta = atan2(pos.y, pos.x)
                    let binIdx = FlowProjector.binIndex(theta: theta, bins: flowConfig.bins)
                    binsByID[id] = binIdx
                    let weight: Float
                    if r <= 0 {
                        weight = 0
                    } else if r <= radius {
                        weight = r / radius
                    } else {
                        weight = radius / r
                    }
                    if weight > 0 {
                        projected[binIdx] += min(max(weight, 0), 1)
                    }
                }
                predictedBins = binsByID
                projectedHistogram = projected
            }

            // Predicted histogram (slow path): sum gain-adjusted completion energies by output bin.
            var y = [Float](repeating: 0, count: flowConfig.bins)
            if !allCompletions.isEmpty {
                for comp in allCompletions {
                    let b = comp.binIndex
                    guard b >= 0 && b < flowConfig.bins else { continue }
                    let g = FlowProjector.gain(for: b, bins: flowConfig.bins, gains: params.gains)
                    y[b] += g * max(0, comp.energy)
                }
            }
            predictedHistogram = y
        } else {
            // Fast path: one GPU-run with counters + scalar metrics + histogram readback.
            let summary = router.simulateWithCompletions(
                initial: seeds,
                gains: params.gains,
                steps: learningConfig.stepsPerEpoch,
                initialBins: initialBinsByIndex,
                // Training signal is the summed histogram bins; per-particle completion readback is not required.
                includeCompletions: false,
                // Required: we learn from the predicted histogram.
                includeHistogram: true
            )

            predictedHistogram = summary.bins
            gpuMeanRadialMiss = summary.meanRadialMiss
            gpuBoundaryLoss = summary.boundaryLoss
            completionCount = summary.completionCount
            totalSpikes = summary.spikeCount
            totalParticleSteps = summary.particleStepCount
        }

        // Predicted signal for losses/updates/UI: summed histogram bins.
        let yHat: [Float] = predictedHistogram ?? [Float](repeating: 0, count: flowConfig.bins)

        // Normalize for loss computation (keep raw for UI/metrics)
        let yHatNorm = normalizeBins(yHat)

        let targetNorm: [Float]
        if let cached = targetsNormOverride, cached.count == targets.count {
            targetNorm = cached
        } else {
            targetNorm = normalizeBins(targets)
        }

        // Compute losses
        let binLoss = LossFunctions.binLoss(yHat: yHatNorm, target: targetNorm, gains: params.gains)

        let wrongNorm: [[Float]]
        if learningConfig.negative.enabled, !wrongTargets.isEmpty {
            if let cached = wrongTargetsNormOverride, cached.count == wrongTargets.count {
                wrongNorm = cached
            } else {
                wrongNorm = wrongTargets.map { normalizeBins($0) }
            }
        } else {
            wrongNorm = []
        }
        let negativeLoss: Float
        if !wrongNorm.isEmpty {
            let base = LossFunctions.negativeMarginLoss(yHat: yHatNorm, wrongTargets: wrongNorm, margin: learningConfig.negative.margin)
            negativeLoss = base * learningConfig.negative.weight
        } else {
            negativeLoss = 0
        }
        let spikeRate = totalParticleSteps > 0 ? Float(totalSpikes) / Float(totalParticleSteps) : 0
        let spikeLoss = LossFunctions.spikeRateLoss(observed: spikeRate, target: learningConfig.targetSpikeRate)
        let boundaryLoss = gpuBoundaryLoss ?? LossFunctions.boundaryLoss(completions: allCompletions, radius: flowConfig.radius)
        let totalLoss = LossFunctions.totalLoss(
            binLoss: binLoss,
            negativeLoss: negativeLoss,
            spikeLoss: spikeLoss,
            boundaryLoss: boundaryLoss,
            spikeWeight: learningConfig.lossWeights.spike,
            boundaryWeight: learningConfig.lossWeights.boundary
        )

        let optionAccuracy: Float?
        if let correctIndex, !optionTargets.isEmpty, !yHatNorm.isEmpty {
            let distances = optionTargets.map { option in
                LossFunctions.l2Distance(yHatNorm, normalizeBins(option))
            }
            let minIdx = distances.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
            optionAccuracy = (minIdx == correctIndex) ? 1.0 : 0.0
        } else {
            optionAccuracy = nil
        }

        // Compute metrics
        let completionRate = initialParticleCount > 0 ? Float(completionCount) / Float(initialParticleCount) : 0
        let meanRadialMiss = gpuMeanRadialMiss ?? computeMeanRadialMiss(completions: allCompletions, radius: flowConfig.radius)
        let nonzeroBins: Int
        let yHatStats: LearningMetrics.BinStatistics
        let histogramMatchL1: Float?
        let histogramMatchL2: Float?
        let histogramMatchCosine: Float?
        let retrievalResult: HistogramRetrievalResult?

        nonzeroBins = yHat.filter { $0 > 0 }.count
        yHatStats = computeBinStatistics(yHat)
        if yHatNorm.count == targetNorm.count, !yHatNorm.isEmpty {
            let metricValues = HistogramMetrics.compute(yHatNorm, targetNorm)
            histogramMatchL1 = metricValues.l1
            histogramMatchL2 = metricValues.l2
            histogramMatchCosine = metricValues.cosine
        } else {
            histogramMatchL1 = nil
            histogramMatchL2 = nil
            histogramMatchCosine = nil
        }
        if needsTraceLog, let retriever, !yHatNorm.isEmpty {
            retrievalResult = retriever.retrieve(normalized: yHatNorm).first
        } else {
            retrievalResult = nil
        }

        let paramDeltas: LearningMetrics.ParameterDeltas
        if applyUpdates {
            // Store old parameters for delta computation
            let oldThreshold = params.lifThreshold
            let oldRadialBias = params.radialBias
            let oldSpikeKick = params.spikeKick

            let oldGains = params.gains

            // Update gains on CPU
            ParameterUpdater.updateGains(
                gains: &params.gains,
                yHat: yHatNorm,
                target: targetNorm,
                learningRate: learningConfig.learningRates.gain,
                bounds: learningConfig.bounds.gain,
                errorPower: learningConfig.gainErrorPower,
                errorScale: learningConfig.gainErrorScale
            )
            if !wrongNorm.isEmpty {
                ParameterUpdater.repelGains(
                    gains: &params.gains,
                    yHat: yHatNorm,
                    wrongTargets: wrongNorm,
                    learningRate: learningConfig.learningRates.gain,
                    bounds: learningConfig.bounds.gain,
                    weight: learningConfig.negative.weight,
                    margin: learningConfig.negative.margin,
                    errorPower: learningConfig.gainErrorPower,
                    errorScale: learningConfig.gainErrorScale
                )
            }

            // CPU gain delta stats
            let gainDeltas = zip(oldGains, params.gains).map { $1 - $0 }
            let gainDeltaMean = gainDeltas.reduce(0, +) / Float(gainDeltas.count)
            let gainDeltaVariance = gainDeltas.map { d in
                let delta = d - gainDeltaMean
                return delta * delta
            }.reduce(0, +) / Float(gainDeltas.count)

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
            optionAccuracy: optionAccuracy,
            histogramMatchL1: histogramMatchL1,
            histogramMatchL2: histogramMatchL2,
            histogramMatchCosine: histogramMatchCosine
        )

#if canImport(SharedInfrastructure)
        if needsTraceLog {
            let traces = trackedIDs.compactMap { id -> LearningLogPayload.Trace? in
                guard let steps = traceSteps[id] else { return nil }
                return LearningLogPayload.Trace(id: id, steps: steps)
            }
            let paths = trackedIDs.compactMap { id -> LearningLogPayload.Path? in
                guard let points = pathPoints[id] else { return nil }
                return LearningLogPayload.Path(id: id, points: points)
            }
            emitLearningLog(
                epoch: epoch,
                metrics: metrics,
                params: params,
                yHat: yHat,
                targets: targets,
                inputText: inputText,
                answerText: answerText,
                predictedBins: predictedBins,
                projectedHistogram: projectedHistogram,
                inputHistogram: inputHistogram,
                outputHistogram: (yHat.count == flowConfig.bins) ? yHat : nil,
                targetHistogram: (targets.count == flowConfig.bins) ? targets : nil,
                retrieval: retrievalResult,
                traces: traces,
                paths: paths
            )
        } else if needsMetricsLog {
            let emptyTraces: [LearningLogPayload.Trace] = []
            let emptyPaths: [LearningLogPayload.Path] = []
            emitLearningLog(
                epoch: epoch,
                metrics: metrics,
                params: params,
                yHat: yHat,
                targets: targets,
                inputText: nil,
                answerText: nil,
                predictedBins: nil,
                projectedHistogram: nil,
                inputHistogram: inputHistogram,
                outputHistogram: (yHat.count == flowConfig.bins) ? yHat : nil,
                targetHistogram: (targets.count == flowConfig.bins) ? targets : nil,
                retrieval: nil,
                traces: emptyTraces,
                paths: emptyPaths
            )
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
            gainSpikeKickScale: flowConfig.dynamics.gainSpikeKickScale,
            noiseStdPos: flowConfig.dynamics.noiseStdPos,
            noiseStdDir: flowConfig.dynamics.noiseStdDir,
            maxSpeed: flowConfig.dynamics.maxSpeed,
            energyAlpha: flowConfig.dynamics.energyAlpha,
            energyFloor: flowConfig.dynamics.energyFloor,
            energySpikeGain: flowConfig.dynamics.energySpikeGain,
            energyGainBias: flowConfig.dynamics.energyGainBias,
            energyCap: flowConfig.dynamics.energyCap
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
        inputText: String?,
        answerText: String?,
        predictedBins: [Int]?,
        projectedHistogram: [Float]?,
        inputHistogram: [Float]?,
        outputHistogram: [Float]?,
        targetHistogram: [Float]?,
        retrieval: HistogramRetrievalResult?,
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
            histogramMatchL1: metrics.histogramMatchL1,
            histogramMatchL2: metrics.histogramMatchL2,
            histogramMatchCosine: metrics.histogramMatchCosine,
            inputText: inputText,
            answerText: answerText,
            predictedBins: predictedBins,
            projectedHistogram: projectedHistogram,
            inputHistogram: inputHistogram,
            outputHistogram: outputHistogram,
            targetHistogram: targetHistogram,
            retrieval: retrieval.map { .init(text: $0.text, score: $0.score, metric: $0.metric.rawValue) },
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
        struct Retrieval: Codable { let text: String; let score: Float; let metric: String }
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
        let histogramMatchL1: Float?
        let histogramMatchL2: Float?
        let histogramMatchCosine: Float?
        let inputText: String?
        let answerText: String?
        let predictedBins: [Int]?
        let projectedHistogram: [Float]?
        let inputHistogram: [Float]?
        let outputHistogram: [Float]?
        let targetHistogram: [Float]?
        let retrieval: Retrieval?
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
