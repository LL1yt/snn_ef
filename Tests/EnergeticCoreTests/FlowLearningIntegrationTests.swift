import XCTest
@testable import EnergeticCore

final class FlowLearningIntegrationTests: XCTestCase {
    func testGPUScalarMetricsMatchCPU() {
        let flowCfg = FlowConfig(
            T: 20,
            radius: 10.0,
            bins: 8,
            seedLayout: "ring",
            seedRadius: 1.0,
            finalWeightPower: 1.0,
            lif: .init(decay: 0.9, threshold: 0.8, resetValue: 0.0, surrogate: "fast_sigmoid"),
            dynamics: .init(radialBias: 0.15, spikeKick: 0.5, gainSpikeKickScale: 0.0, noiseStdPos: 0.01, noiseStdDir: 0.05, maxSpeed: 1.0, energyAlpha: 0.95, energyFloor: 1e-5, energySpikeGain: 0.0, energyGainBias: 0.0, energyCap: 0.0)
        )
        let router = FlowRouter(cfg: flowCfg, seed: 123)

        let energies: [Float] = [10, 20, 15, 8, 12, 18, 22, 14]
        let seeds = FlowSeeds.makeSeeds(energies: energies, layout: flowCfg.seedLayout, radius: flowCfg.seedRadius, bins: flowCfg.bins)

        var initialBins: [Int32] = []
        initialBins.reserveCapacity(seeds.count)
        for s in seeds {
            let theta = atan2(s.pos.y, s.pos.x)
            initialBins.append(Int32(FlowProjector.binIndex(theta: theta, bins: flowCfg.bins)))
        }

        let gains = [Float](repeating: 1.0, count: flowCfg.bins)
        let summary = router.simulateWithCompletions(
            initial: seeds,
            gains: gains,
            steps: 20,
            initialBins: initialBins
        )

        var completions: [CompletionEvent] = []
        completions.reserveCapacity(Int(summary.completionCount))
        for c in summary.completions where c.bin >= 0 {
            let initial = c.initialBin >= 0 ? Int(c.initialBin) : nil
            completions.append(
                CompletionEvent(
                    particleID: Int(c.particleID),
                    binIndex: Int(c.bin),
                    position: SIMD2<Float>(c.x, c.y),
                    energy: c.energy,
                    spiked: c.spiked != 0,
                    initialBinIndex: initial
                )
            )
        }

        let meanMissCPU: Float
        if completions.isEmpty {
            meanMissCPU = 0
        } else {
            let sum = completions.reduce(Float(0.0)) { acc, comp in
                let r = length(comp.position)
                return acc + abs(r - flowCfg.radius)
            }
            meanMissCPU = sum / Float(completions.count)
        }

        let boundaryCPU = LossFunctions.boundaryLoss(completions: completions, radius: flowCfg.radius, eps: 0.01)

        XCTAssertEqual(summary.meanRadialMiss, meanMissCPU, accuracy: 1e-3)
        XCTAssertEqual(summary.boundaryLoss, boundaryCPU, accuracy: 1e-3)
    }

    func testGPUWeightedYHatWithoutCompletionsReadback() {
        let flowCfg = FlowConfig(
            T: 40,
            radius: 6.0,
            bins: 8,
            seedLayout: "ring",
            seedRadius: 1.0,
            finalWeightPower: 1.0,
            lif: .init(decay: 0.9, threshold: 0.8, resetValue: 0.0, surrogate: "fast_sigmoid"),
            dynamics: .init(radialBias: 0.25, spikeKick: 0.5, gainSpikeKickScale: 0.0, noiseStdPos: 0.01, noiseStdDir: 0.05, maxSpeed: 1.0, energyAlpha: 0.97, energyFloor: 1e-5, energySpikeGain: 0.0, energyGainBias: 0.0, energyCap: 0.0)
        )
        let agg = AggregatorConfig(
            sigmaR: 2.5,
            sigmaE: 5.0,
            alpha: 1.0,
            beta: 1.0,
            gamma: 0.5,
            tau: 1.0,
            radius: flowCfg.radius
        )
        let router = FlowRouter(cfg: flowCfg, seed: 123)

        let energies: [Float] = [10, 20, 15, 8, 12, 18, 22, 14]
        let targets = TargetLoader.fromCapsuleDigits(energies: energies, bins: flowCfg.bins)
        let seeds = FlowSeeds.makeSeeds(energies: energies, layout: flowCfg.seedLayout, radius: flowCfg.seedRadius, bins: flowCfg.bins)

        var initialBins: [Int32] = []
        initialBins.reserveCapacity(seeds.count)
        for s in seeds {
            let theta = atan2(s.pos.y, s.pos.x)
            initialBins.append(Int32(FlowProjector.binIndex(theta: theta, bins: flowCfg.bins)))
        }

        let gains = [Float](repeating: 1.0, count: flowCfg.bins)
        let summary = router.simulateWithCompletions(
            initial: seeds,
            gains: gains,
            steps: 40,
            initialBins: initialBins,
            targetsRaw: targets,
            aggregator: agg,
            includeCompletions: false,
            includeHistogram: false
        )

        XCTAssertNotNil(summary.weightedYHat)
        XCTAssertTrue(summary.completions.isEmpty)
        XCTAssertTrue(summary.bins.isEmpty)
    }

    func testGPUWeightedYHatMatchesCPUAggregator() {
        let flowCfg = FlowConfig(
            T: 20,
            radius: 10.0,
            bins: 8,
            seedLayout: "ring",
            seedRadius: 1.0,
            finalWeightPower: 1.0,
            lif: .init(decay: 0.9, threshold: 0.8, resetValue: 0.0, surrogate: "fast_sigmoid"),
            dynamics: .init(radialBias: 0.15, spikeKick: 0.5, gainSpikeKickScale: 0.0, noiseStdPos: 0.01, noiseStdDir: 0.05, maxSpeed: 1.0, energyAlpha: 0.95, energyFloor: 1e-5, energySpikeGain: 0.0, energyGainBias: 0.0, energyCap: 0.0)
        )
        let agg = AggregatorConfig(
            sigmaR: 2.5,
            sigmaE: 5.0,
            alpha: 1.0,
            beta: 1.0,
            gamma: 0.5,
            tau: 1.0,
            radius: 10.0
        )
        let router = FlowRouter(cfg: flowCfg, seed: 123)

        let energies: [Float] = [10, 20, 15, 8, 12, 18, 22, 14]
        let targets = TargetLoader.fromCapsuleDigits(energies: energies, bins: flowCfg.bins)
        let seeds = FlowSeeds.makeSeeds(energies: energies, layout: flowCfg.seedLayout, radius: flowCfg.seedRadius, bins: flowCfg.bins)

        var initialBins: [Int32] = []
        initialBins.reserveCapacity(seeds.count)
        for s in seeds {
            let theta = atan2(s.pos.y, s.pos.x)
            initialBins.append(Int32(FlowProjector.binIndex(theta: theta, bins: flowCfg.bins)))
        }

        let gains = [Float](repeating: 1.0, count: flowCfg.bins)
        let summary = router.simulateWithCompletions(
            initial: seeds,
            gains: gains,
            steps: 20,
            initialBins: initialBins,
            targetsRaw: targets,
            aggregator: agg
        )

        guard let yHatGPU = summary.weightedYHat else {
            XCTFail("expected weightedYHat")
            return
        }

        var completions: [CompletionEvent] = []
        completions.reserveCapacity(Int(summary.completionCount))
        for c in summary.completions where c.bin >= 0 {
            let initial = c.initialBin >= 0 ? Int(c.initialBin) : nil
            completions.append(
                CompletionEvent(
                    particleID: Int(c.particleID),
                    binIndex: Int(c.bin),
                    position: SIMD2<Float>(c.x, c.y),
                    energy: c.energy,
                    spiked: c.spiked != 0,
                    initialBinIndex: initial
                )
            )
        }

        let yHatCPU = CompletionAggregator.aggregate(
            completions: completions,
            targets: targets,
            config: agg,
            bins: flowCfg.bins,
            gains: gains
        )

        XCTAssertEqual(yHatCPU.count, yHatGPU.count)
        for i in 0..<yHatCPU.count {
            XCTAssertEqual(yHatCPU[i], yHatGPU[i], accuracy: 1e-2)
        }
    }

    func testGPULearningScalarsMatchCPUReference() {
        func normalize(_ bins: [Float]) -> [Float] {
            let s = bins.reduce(0, +)
            guard s > 0 else { return bins }
            return bins.map { $0 / s }
        }

        func binStats(_ bins: [Float]) -> (mean: Float, variance: Float, min: Float, max: Float, nonzero: Int) {
            guard !bins.isEmpty else { return (0, 0, 0, 0, 0) }
            let mean = bins.reduce(0, +) / Float(bins.count)
            let variance = bins.map { v in
                let d = v - mean
                return d * d
            }.reduce(0, +) / Float(bins.count)
            let minV = bins.min() ?? 0
            let maxV = bins.max() ?? 0
            let nonzero = bins.filter { $0 > 0 }.count
            return (mean, variance, minV, maxV, nonzero)
        }

        let flowCfg = FlowConfig(
            T: 30,
            radius: 8.0,
            bins: 8,
            seedLayout: "ring",
            seedRadius: 1.0,
            finalWeightPower: 1.0,
            lif: .init(decay: 0.9, threshold: 0.8, resetValue: 0.0, surrogate: "fast_sigmoid"),
            dynamics: .init(radialBias: 0.2, spikeKick: 0.5, gainSpikeKickScale: 0.0, noiseStdPos: 0.01, noiseStdDir: 0.05, maxSpeed: 1.0, energyAlpha: 0.96, energyFloor: 1e-5, energySpikeGain: 0.0, energyGainBias: 0.0, energyCap: 0.0)
        )
        let agg = AggregatorConfig(
            sigmaR: 2.5,
            sigmaE: 5.0,
            alpha: 1.0,
            beta: 1.0,
            gamma: 0.5,
            tau: 1.0,
            radius: flowCfg.radius
        )
        let router = FlowRouter(cfg: flowCfg, seed: 123)

        let energies: [Float] = [10, 20, 15, 8, 12, 18, 22, 14]
        let targets = TargetLoader.fromCapsuleDigits(energies: energies, bins: flowCfg.bins)
        let targetNorm = normalize(targets)

        let seeds = FlowSeeds.makeSeeds(energies: energies, layout: flowCfg.seedLayout, radius: flowCfg.seedRadius, bins: flowCfg.bins)

        var initialBins: [Int32] = []
        initialBins.reserveCapacity(seeds.count)
        for s in seeds {
            let theta = atan2(s.pos.y, s.pos.x)
            initialBins.append(Int32(FlowProjector.binIndex(theta: theta, bins: flowCfg.bins)))
        }

        // Wrong targets: rotate by 1 and 2 bins
        let wrong1 = Array(targets.dropFirst()) + [targets.first ?? 0]
        let wrong2 = Array(wrong1.dropFirst()) + [wrong1.first ?? 0]
        let wrongNorm = [normalize(wrong1), normalize(wrong2)]

        let optionTargets = [targets, wrong1, wrong2]
        let correctIndex = 0

        let gains = [Float](repeating: 1.0, count: flowCfg.bins)
        let req = FlowMetalLearningRequest(
            targetNorm: targetNorm,
            wrongTargetsNorm: wrongNorm,
            optionTargetsRaw: optionTargets,
            correctIndex: correctIndex,
            doUpdateGains: false,
            gainLearningRate: 0,
            gainBounds: (min: 0.1, max: 2.0),
            errorPower: 1.0,
            errorScale: 1.0,
            lambdaG: 0.01,
            negativeWeight: 0.5,
            negativeMargin: 0.4
        )

        let summary = router.simulateWithCompletionsLearningGPU(
            initial: seeds,
            gains: gains,
            steps: 30,
            initialBins: initialBins,
            targetsRaw: targets,
            aggregator: agg,
            includeCompletions: false,
            includeHistogram: false,
            learning: req
        )

        guard let yHat = summary.weightedYHat else {
            XCTFail("expected weightedYHat")
            return
        }
        guard let gpu = summary.learningScalars else {
            XCTFail("expected learningScalars")
            return
        }

        let yHatNorm = normalize(yHat)
        let binLossCPU = LossFunctions.binLoss(yHat: yHatNorm, target: targetNorm, gains: gains, lambdaG: 0.01)
        let negBaseCPU = LossFunctions.negativeMarginLoss(yHat: yHatNorm, wrongTargets: wrongNorm, margin: 0.4)
        let negativeLossCPU = negBaseCPU * 0.5
        let l1CPU: Float = zip(yHatNorm, targetNorm).reduce(0) { $0 + abs($1.0 - $1.1) }

        let stats = binStats(yHat)

        // Option accuracy CPU reference
        let distances = optionTargets.map { LossFunctions.l2Distance(yHat, $0) }
        let minIdx = distances.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
        let optionAccCPU: Float = (minIdx == correctIndex) ? 1.0 : 0.0

        XCTAssertEqual(gpu.binLoss, binLossCPU, accuracy: 1e-3)
        XCTAssertEqual(gpu.negativeLoss, negativeLossCPU, accuracy: 1e-3)
        XCTAssertEqual(gpu.histogramMatchL1, l1CPU, accuracy: 1e-3)
        XCTAssertEqual(gpu.yHatStatsMean, stats.mean, accuracy: 1e-3)
        XCTAssertEqual(gpu.yHatStatsVariance, stats.variance, accuracy: 1e-3)
        XCTAssertEqual(gpu.yHatStatsMin, stats.min, accuracy: 1e-3)
        XCTAssertEqual(gpu.yHatStatsMax, stats.max, accuracy: 1e-3)
        XCTAssertEqual(gpu.nonzeroBins, stats.nonzero)
        XCTAssertEqual(gpu.optionAccuracy, optionAccCPU, accuracy: 1e-3)
        XCTAssertEqual(gpu.gainDeltaMean, 0, accuracy: 1e-6)
        XCTAssertEqual(gpu.gainDeltaVariance, 0, accuracy: 1e-6)
    }

    func testGPUGainsUpdateMatchesCPUParameterUpdater() {
        func normalize(_ bins: [Float]) -> [Float] {
            let s = bins.reduce(0, +)
            guard s > 0 else { return bins }
            return bins.map { $0 / s }
        }

        let flowCfg = FlowConfig(
            T: 35,
            radius: 8.0,
            bins: 8,
            seedLayout: "ring",
            seedRadius: 1.0,
            finalWeightPower: 1.0,
            lif: .init(decay: 0.9, threshold: 0.8, resetValue: 0.0, surrogate: "fast_sigmoid"),
            dynamics: .init(radialBias: 0.2, spikeKick: 0.5, gainSpikeKickScale: 0.0, noiseStdPos: 0.01, noiseStdDir: 0.05, maxSpeed: 1.0, energyAlpha: 0.96, energyFloor: 1e-5, energySpikeGain: 0.0, energyGainBias: 0.0, energyCap: 0.0)
        )
        let agg = AggregatorConfig(
            sigmaR: 2.5,
            sigmaE: 5.0,
            alpha: 1.0,
            beta: 1.0,
            gamma: 0.5,
            tau: 1.0,
            radius: flowCfg.radius
        )
        let router = FlowRouter(cfg: flowCfg, seed: 123)

        let energies: [Float] = [10, 20, 15, 8, 12, 18, 22, 14]
        let targets = TargetLoader.fromCapsuleDigits(energies: energies, bins: flowCfg.bins)
        let targetNorm = normalize(targets)

        let seeds = FlowSeeds.makeSeeds(energies: energies, layout: flowCfg.seedLayout, radius: flowCfg.seedRadius, bins: flowCfg.bins)

        var initialBins: [Int32] = []
        initialBins.reserveCapacity(seeds.count)
        for s in seeds {
            let theta = atan2(s.pos.y, s.pos.x)
            initialBins.append(Int32(FlowProjector.binIndex(theta: theta, bins: flowCfg.bins)))
        }

        // Wrong targets: rotate by 1 and 2 bins
        let wrong1 = Array(targets.dropFirst()) + [targets.first ?? 0]
        let wrong2 = Array(wrong1.dropFirst()) + [wrong1.first ?? 0]
        let wrongNorm = [normalize(wrong1), normalize(wrong2)]

        var gains0: [Float] = [1.0, 0.9, 1.1, 1.05, 0.95, 1.2, 0.8, 1.0]
        XCTAssertEqual(gains0.count, flowCfg.bins)

        let lr: Float = 0.02
        let bounds = (min: Float(0.1), max: Float(2.0))
        let negWeight: Float = 0.5
        let margin: Float = 0.4

        let req = FlowMetalLearningRequest(
            targetNorm: targetNorm,
            wrongTargetsNorm: wrongNorm,
            optionTargetsRaw: [],
            correctIndex: nil,
            doUpdateGains: true,
            gainLearningRate: lr,
            gainBounds: bounds,
            errorPower: 1.0,
            errorScale: 1.0,
            lambdaG: 0.01,
            negativeWeight: negWeight,
            negativeMargin: margin
        )

        let summary = router.simulateWithCompletionsLearningGPU(
            initial: seeds,
            gains: gains0,
            steps: 35,
            initialBins: initialBins,
            targetsRaw: targets,
            aggregator: agg,
            includeCompletions: false,
            includeHistogram: false,
            learning: req,
            useExistingGains: false,
            includeWeightedYHatReadback: true
        )

        guard let yHat = summary.weightedYHat else {
            XCTFail("expected weightedYHat")
            return
        }
        guard let gpu = summary.learningScalars else {
            XCTFail("expected learningScalars")
            return
        }

        // CPU reference update
        let yHatNorm = normalize(yHat)
        var gainsCPU = gains0
        ParameterUpdater.updateGains(
            gains: &gainsCPU,
            yHat: yHatNorm,
            target: targetNorm,
            learningRate: lr,
            bounds: bounds,
            errorPower: 1.0,
            errorScale: 1.0
        )
        ParameterUpdater.repelGains(
            gains: &gainsCPU,
            yHat: yHatNorm,
            wrongTargets: wrongNorm,
            learningRate: lr,
            bounds: bounds,
            weight: negWeight,
            margin: margin,
            errorPower: 1.0,
            errorScale: 1.0
        )

        // GPU-updated gains
        let gainsGPU = router.readGainsFromGPU()

        XCTAssertEqual(gainsCPU.count, gainsGPU.count)
        for i in 0..<gainsCPU.count {
            XCTAssertEqual(gainsCPU[i], gainsGPU[i], accuracy: 1e-3)
        }

        // Delta stats parity
        let deltas = zip(gains0, gainsCPU).map { $1 - $0 }
        let mean = deltas.reduce(0, +) / Float(deltas.count)
        let variance = deltas.map { d in
            let x = d - mean
            return x * x
        }.reduce(0, +) / Float(deltas.count)

        XCTAssertEqual(gpu.gainDeltaMean, mean, accuracy: 1e-4)
        XCTAssertEqual(gpu.gainDeltaVariance, variance, accuracy: 1e-4)
    }

    func testGPULearningScalarsWorkWithoutYHatReadback() {
        func normalize(_ bins: [Float]) -> [Float] {
            let s = bins.reduce(0, +)
            guard s > 0 else { return bins }
            return bins.map { $0 / s }
        }

        let flowCfg = FlowConfig(
            T: 40,
            radius: 8.0,
            bins: 8,
            seedLayout: "ring",
            seedRadius: 1.0,
            finalWeightPower: 1.0,
            lif: .init(decay: 0.9, threshold: 0.8, resetValue: 0.0, surrogate: "fast_sigmoid"),
            dynamics: .init(radialBias: 0.2, spikeKick: 0.5, gainSpikeKickScale: 0.0, noiseStdPos: 0.01, noiseStdDir: 0.05, maxSpeed: 1.0, energyAlpha: 0.96, energyFloor: 1e-5, energySpikeGain: 0.0, energyGainBias: 0.0, energyCap: 0.0)
        )
        let agg = AggregatorConfig(
            sigmaR: 2.5,
            sigmaE: 5.0,
            alpha: 1.0,
            beta: 1.0,
            gamma: 0.5,
            tau: 1.0,
            radius: flowCfg.radius
        )
        let router = FlowRouter(cfg: flowCfg, seed: 123)

        let energies: [Float] = [10, 20, 15, 8, 12, 18, 22, 14]
        let targets = TargetLoader.fromCapsuleDigits(energies: energies, bins: flowCfg.bins)
        let targetNorm = normalize(targets)

        let seeds = FlowSeeds.makeSeeds(energies: energies, layout: flowCfg.seedLayout, radius: flowCfg.seedRadius, bins: flowCfg.bins)

        var initialBins: [Int32] = []
        initialBins.reserveCapacity(seeds.count)
        for s in seeds {
            let theta = atan2(s.pos.y, s.pos.x)
            initialBins.append(Int32(FlowProjector.binIndex(theta: theta, bins: flowCfg.bins)))
        }

        let wrong1 = Array(targets.dropFirst()) + [targets.first ?? 0]
        let wrongNorm = [normalize(wrong1)]

        let gains0: [Float] = [1.0, 0.9, 1.1, 1.05, 0.95, 1.2, 0.8, 1.0]
        let lr: Float = 0.02
        let bounds = (min: Float(0.1), max: Float(2.0))

        let req = FlowMetalLearningRequest(
            targetNorm: targetNorm,
            wrongTargetsNorm: wrongNorm,
            optionTargetsRaw: [],
            correctIndex: nil,
            doUpdateGains: true,
            gainLearningRate: lr,
            gainBounds: bounds,
            errorPower: 1.0,
            errorScale: 1.0,
            lambdaG: 0.01,
            negativeWeight: 0.5,
            negativeMargin: 0.4
        )

        let summary = router.simulateWithCompletionsLearningGPU(
            initial: seeds,
            gains: gains0,
            steps: 40,
            initialBins: initialBins,
            targetsRaw: targets,
            aggregator: agg,
            includeCompletions: false,
            includeHistogram: false,
            learning: req,
            useExistingGains: false,
            includeWeightedYHatReadback: false
        )

        XCTAssertNil(summary.weightedYHat)
        XCTAssertNotNil(summary.learningScalars)
        XCTAssertTrue(summary.completions.isEmpty)
        XCTAssertTrue(summary.bins.isEmpty)

        let gainsAfter = router.readGainsFromGPU()
        let maxAbsDelta = zip(gains0, gainsAfter).map { abs($1 - $0) }.max() ?? 0
        XCTAssertGreaterThan(maxAbsDelta, 0)
    }

    func testFastPathParityWithSlowPath() {
        let flowCfg = FlowConfig(
            T: 12,
            radius: 10.0,
            bins: 8,
            seedLayout: "ring",
            seedRadius: 1.0,
            finalWeightPower: 1.0,
            lif: .init(decay: 0.9, threshold: 0.8, resetValue: 0.0, surrogate: "fast_sigmoid"),
            dynamics: .init(radialBias: 0.15, spikeKick: 0.5, gainSpikeKickScale: 0.0, noiseStdPos: 0.01, noiseStdDir: 0.05, maxSpeed: 1.0, energyAlpha: 0.95, energyFloor: 1e-5, energySpikeGain: 0.0, energyGainBias: 0.0, energyCap: 0.0)
        )

        let learningCfg = LearningConfig(
            enabled: true,
            epochs: 1,
            stepsPerEpoch: 12,
            targetSpikeRate: 0.2,
            logEvery: 1,
            logEveryUI: 1,
            learningRates: .init(gain: 0.0, lif: 0.0, dynamics: 0.0),
            lossWeights: .init(spike: 0.1, boundary: 0.05),
            bounds: .init(
                theta: (0.5, 1.0),
                radialBias: (0.0, 0.5),
                spikeKick: (0.0, 1.0),
                gain: (0.1, 2.0)
            ),
            aggregatorConfig: AggregatorConfig(
                sigmaR: 2.5,
                sigmaE: 5.0,
                alpha: 1.0,
                beta: 1.0,
                gamma: 0.5,
                tau: 1.0,
                radius: 10.0
            )
        )

        let energies: [Float] = [10, 20, 15, 8, 12, 18, 22, 14]
        let targets = TargetLoader.fromCapsuleDigits(energies: energies, bins: flowCfg.bins)

        let seed: UInt64 = 4242
        let loopSlow = FlowLearningLoop(flowConfig: flowCfg, learningConfig: learningCfg, seed: seed)
        let loopFast = FlowLearningLoop(flowConfig: flowCfg, learningConfig: learningCfg, seed: seed)

        // Slow path is triggered when emitLog=true (epoch 0, logEveryUI=1)
        let slow = loopSlow.runEpoch(epoch: 0, energies: energies, targets: targets, applyUpdates: false, emitLog: true)
        // Fast path is triggered when emitLog=false
        let fast = loopFast.runEpoch(epoch: 0, energies: energies, targets: targets, applyUpdates: false, emitLog: false)

        XCTAssertEqual(slow.spikeRate, fast.spikeRate, accuracy: 1e-4)
        XCTAssertEqual(slow.completionRate, fast.completionRate, accuracy: 1e-4)
        XCTAssertEqual(slow.meanRadialMiss, fast.meanRadialMiss, accuracy: 1e-3)
        XCTAssertEqual(slow.binLoss, fast.binLoss, accuracy: 1e-3)
        XCTAssertEqual(slow.negativeLoss, fast.negativeLoss, accuracy: 1e-5)
    }

    func testLearningLoopConvergence() {
        // Setup simple flow config
        let flowCfg = FlowConfig(
            T: 10,
            radius: 10.0,
            bins: 8,
            seedLayout: "ring",
            seedRadius: 1.0,
            finalWeightPower: 1.0,
            lif: .init(decay: 0.9, threshold: 0.8, resetValue: 0.0, surrogate: "fast_sigmoid"),
            dynamics: .init(radialBias: 0.15, spikeKick: 0.5, gainSpikeKickScale: 0.0, noiseStdPos: 0.01, noiseStdDir: 0.05, maxSpeed: 1.0, energyAlpha: 0.95, energyFloor: 1e-5, energySpikeGain: 0.0, energyGainBias: 0.0, energyCap: 0.0)
        )

        let learningCfg = LearningConfig(
            enabled: true,
            epochs: 20,
            stepsPerEpoch: 10,
            targetSpikeRate: 0.2,
            logEvery: 1,
            logEveryUI: 1,
            learningRates: .init(gain: 0.01, lif: 0.02, dynamics: 0.005),
            lossWeights: .init(spike: 0.1, boundary: 0.05),
            bounds: .init(
                theta: (0.5, 1.0),
                radialBias: (0.0, 0.5),
                spikeKick: (0.0, 1.0),
                gain: (0.1, 2.0)
            ),
            aggregatorConfig: AggregatorConfig(
                sigmaR: 2.5,
                sigmaE: 5.0,
                alpha: 1.0,
                beta: 1.0,
                gamma: 0.5,
                tau: 1.0,
                radius: 10.0
            )
        )

        // Create learning loop
        let learningLoop = FlowLearningLoop(flowConfig: flowCfg, learningConfig: learningCfg, seed: 42)

        // Create synthetic energies
        let energies: [Float] = [10, 20, 15, 8, 12, 18, 22, 14]
        let targets: [Float] = [10, 20, 15, 8, 12, 18, 22, 14]  // Match energies

        // Run a few epochs
        var losses: [Float] = []
        for epoch in 0..<5 {
            let metrics = learningLoop.runEpoch(epoch: epoch, energies: energies, targets: targets)
            losses.append(metrics.totalLoss)

            // Basic sanity checks
            XCTAssertGreaterThanOrEqual(metrics.completionRate, 0.0)
            XCTAssertLessThanOrEqual(metrics.completionRate, 1.0)
            XCTAssertGreaterThanOrEqual(metrics.spikeRate, 0.0)
            XCTAssertLessThanOrEqual(metrics.spikeRate, 1.0)
            XCTAssertGreaterThanOrEqual(metrics.meanRadialMiss, 0.0)
        }

        // Check that loss is non-negative and reasonably bounded
        for loss in losses {
            XCTAssertGreaterThanOrEqual(loss, 0.0)
            XCTAssertLessThan(loss, 1000.0)  // Sanity upper bound
        }

        // Final parameters should be within bounds
        let finalParams = learningLoop.getParameters()
        XCTAssertGreaterThanOrEqual(finalParams.lifThreshold, 0.5)
        XCTAssertLessThanOrEqual(finalParams.lifThreshold, 1.0)
        XCTAssertGreaterThanOrEqual(finalParams.radialBias, 0.0)
        XCTAssertLessThanOrEqual(finalParams.radialBias, 0.5)
        XCTAssertGreaterThanOrEqual(finalParams.spikeKick, 0.0)
        XCTAssertLessThanOrEqual(finalParams.spikeKick, 1.0)

        for gain in finalParams.gains {
            XCTAssertGreaterThanOrEqual(gain, 0.1)
            XCTAssertLessThanOrEqual(gain, 2.0)
        }
    }

    func testLearningWithDeterministicSeed() {
        // Setup
        let flowCfg = FlowConfig(
            T: 8,
            radius: 8.0,
            bins: 4,
            seedLayout: "ring",
            seedRadius: 0.5,
            finalWeightPower: 1.0,
            lif: .init(decay: 0.9, threshold: 0.7, resetValue: 0.0, surrogate: "fast_sigmoid"),
            dynamics: .init(radialBias: 0.1, spikeKick: 0.4, gainSpikeKickScale: 0.0, noiseStdPos: 0.01, noiseStdDir: 0.03, maxSpeed: 0.8, energyAlpha: 0.95, energyFloor: 1e-5, energySpikeGain: 0.0, energyGainBias: 0.0, energyCap: 0.0)
        )

        let learningCfg = LearningConfig(
            enabled: true,
            epochs: 5,
            stepsPerEpoch: 8,
            targetSpikeRate: 0.15,
            logEvery: 1,
            logEveryUI: 1,
            learningRates: .init(gain: 0.005, lif: 0.01, dynamics: 0.002),
            lossWeights: .init(spike: 0.1, boundary: 0.05),
            bounds: .init(
                theta: (0.5, 1.0),
                radialBias: (0.0, 0.3),
                spikeKick: (0.0, 0.8),
                gain: (0.2, 1.5)
            ),
            aggregatorConfig: AggregatorConfig(
                sigmaR: 2.0,
                sigmaE: 3.0,
                alpha: 1.0,
                beta: 1.0,
                gamma: 0.0,
                tau: 1.0,
                radius: 8.0
            )
        )

        let energies: [Float] = [5, 10, 7, 12]
        let targets = TargetLoader.fromCapsuleDigits(energies: energies, bins: 4)

        // Run twice with same seed
        let loop1 = FlowLearningLoop(flowConfig: flowCfg, learningConfig: learningCfg, seed: 12345)
        let metrics1 = loop1.runEpoch(epoch: 0, energies: energies, targets: targets)

        let loop2 = FlowLearningLoop(flowConfig: flowCfg, learningConfig: learningCfg, seed: 12345)
        let metrics2 = loop2.runEpoch(epoch: 0, energies: energies, targets: targets)

        // Results should be identical with same seed
        // Note: Due to RNG updates in learning loop, exact match might not hold across epochs,
        // but first epoch should be deterministic
        XCTAssertEqual(metrics1.totalLoss, metrics2.totalLoss, accuracy: 1e-3)
        XCTAssertEqual(metrics1.spikeRate, metrics2.spikeRate, accuracy: 1e-3)
    }

    func testCheckpointRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Setup
        let flowCfg = FlowConfig(
            T: 6,
            radius: 6.0,
            bins: 4,
            seedLayout: "ring",
            seedRadius: 0.5,
            finalWeightPower: 1.0,
            lif: .init(decay: 0.9, threshold: 0.75, resetValue: 0.0, surrogate: "fast_sigmoid"),
            dynamics: .init(radialBias: 0.12, spikeKick: 0.45, gainSpikeKickScale: 0.0, noiseStdPos: 0.01, noiseStdDir: 0.04, maxSpeed: 0.9, energyAlpha: 0.95, energyFloor: 1e-5, energySpikeGain: 0.0, energyGainBias: 0.0, energyCap: 0.0)
        )

        let learningCfg = LearningConfig(
            enabled: true,
            epochs: 3,
            stepsPerEpoch: 6,
            targetSpikeRate: 0.18,
            logEvery: 1,
            logEveryUI: 1,
            learningRates: .init(gain: 0.008, lif: 0.015, dynamics: 0.003),
            lossWeights: .init(spike: 0.12, boundary: 0.06),
            bounds: .init(
                theta: (0.6, 0.95),
                radialBias: (0.0, 0.25),
                spikeKick: (0.0, 0.7),
                gain: (0.3, 1.8)
            ),
            aggregatorConfig: AggregatorConfig(
                sigmaR: 1.8,
                sigmaE: 4.0,
                alpha: 1.0,
                beta: 1.0,
                gamma: 0.3,
                tau: 0.8,
                radius: 6.0
            )
        )

        let learningLoop = FlowLearningLoop(flowConfig: flowCfg, learningConfig: learningCfg, seed: 999)
        let energies: [Float] = [8, 12, 6, 10]
        let targets: [Float] = [8, 12, 6, 10]

        // Run one epoch
        let metrics = learningLoop.runEpoch(epoch: 0, energies: energies, targets: targets)
        let params = learningLoop.getParameters()

        // Save checkpoint
        let state = RouterLearningState(epoch: 0, params: .init(from: params), metrics: metrics)
        try CheckpointManager.save(state: state, to: tempDir)

        // Load checkpoint
        let loaded = try CheckpointManager.load(from: tempDir.appendingPathComponent("learning_epoch_0000.json"))

        XCTAssertEqual(loaded.epoch, 0)
        XCTAssertEqual(loaded.params.gains.count, params.gains.count)
        for (orig, saved) in zip(params.gains, loaded.params.gains) {
            XCTAssertEqual(orig, saved, accuracy: 1e-5)
        }
        XCTAssertEqual(loaded.params.lifThreshold, params.lifThreshold, accuracy: 1e-5)
        XCTAssertEqual(loaded.params.radialBias, params.radialBias, accuracy: 1e-5)
        XCTAssertEqual(loaded.params.spikeKick, params.spikeKick, accuracy: 1e-5)
    }

    func testTargetLoadingFromCapsuleDigits() {
        let energies: [Float] = [3.2, 7.8, 15.1, 22.5, 9.3]
        let bins = 16

        let targets = TargetLoader.fromCapsuleDigits(energies: energies, bins: bins)

        XCTAssertEqual(targets.count, bins)

        // Check that sum of targets matches sum of energies
        let targetSum = targets.reduce(0, +)
        let energySum = energies.reduce(0, +)
        XCTAssertEqual(targetSum, energySum, accuracy: 1e-3)
    }

    func testSpikeRateTuningDirection() {
        // Setup with high spike threshold (should produce low spike rate)
        let flowCfg = FlowConfig(
            T: 8,
            radius: 8.0,
            bins: 4,
            seedLayout: "ring",
            seedRadius: 0.8,
            finalWeightPower: 1.0,
            lif: .init(decay: 0.88, threshold: 0.95, resetValue: 0.0, surrogate: "fast_sigmoid"),  // High threshold
            dynamics: .init(radialBias: 0.1, spikeKick: 0.5, gainSpikeKickScale: 0.0, noiseStdPos: 0.01, noiseStdDir: 0.05, maxSpeed: 1.0, energyAlpha: 0.95, energyFloor: 1e-5, energySpikeGain: 0.0, energyGainBias: 0.0, energyCap: 0.0)
        )

        let learningCfg = LearningConfig(
            enabled: true,
            epochs: 1,
            stepsPerEpoch: 8,
            targetSpikeRate: 0.3,  // High target
            logEvery: 1,
            logEveryUI: 1,
            learningRates: .init(gain: 0.005, lif: 0.05, dynamics: 0.002),  // Large LIF LR
            lossWeights: .init(spike: 1.0, boundary: 0.05),  // High spike weight
            bounds: .init(
                theta: (0.3, 1.0),
                radialBias: (0.0, 0.3),
                spikeKick: (0.0, 0.8),
                gain: (0.2, 1.5)
            ),
            aggregatorConfig: AggregatorConfig(
                sigmaR: 2.0,
                sigmaE: 3.0,
                alpha: 1.0,
                beta: 1.0,
                gamma: 0.0,
                tau: 1.0,
                radius: 8.0
            )
        )

        let learningLoop = FlowLearningLoop(flowConfig: flowCfg, learningConfig: learningCfg, seed: 777)
        let energies: [Float] = [10, 15, 12, 18]
        let targets: [Float] = [10, 15, 12, 18]

        let initialThreshold = learningLoop.getParameters().lifThreshold

        // Run one epoch
        let metrics = learningLoop.runEpoch(epoch: 0, energies: energies, targets: targets)

        let finalThreshold = learningLoop.getParameters().lifThreshold

        // If observed spike rate is below target, threshold should decrease (or stay within bounds)
        if metrics.spikeRate < learningCfg.targetSpikeRate - 0.02 {
            XCTAssertLessThanOrEqual(finalThreshold, initialThreshold)
        }
    }

    func testLearningUpdatesGains() {
        let flowCfg = FlowConfig(
            T: 1,
            radius: 0.5,
            bins: 4,
            seedLayout: "ring",
            seedRadius: 0.49,
            finalWeightPower: 1.0,
            lif: .init(decay: 0.9, threshold: 0.6, resetValue: 0.0, surrogate: "fast_sigmoid"),
            dynamics: .init(radialBias: 0.0, spikeKick: 0.0, gainSpikeKickScale: 0.0, noiseStdPos: 0.0, noiseStdDir: 0.0, maxSpeed: 1.0, energyAlpha: 1.0, energyFloor: 0.0, energySpikeGain: 0.0, energyGainBias: 0.0, energyCap: 0.0)
        )

        let learningCfg = LearningConfig(
            enabled: true,
            epochs: 1,
            stepsPerEpoch: 1,
            targetSpikeRate: 0.1,
            logEvery: 1,
            logEveryUI: 1,
            learningRates: .init(gain: 0.01, lif: 0.0, dynamics: 0.0),
            lossWeights: .init(spike: 0.0, boundary: 0.0),
            bounds: .init(
                theta: (0.1, 1.0),
                radialBias: (0.0, 1.0),
                spikeKick: (0.0, 1.0),
                gain: (0.1, 2.0)
            ),
            aggregatorConfig: AggregatorConfig(
                sigmaR: 1.0,
                sigmaE: 1.0,
                alpha: 1.0,
                beta: 1.0,
                gamma: 0.0,
                tau: 1.0,
                radius: 0.5
            )
        )

        let learningLoop = FlowLearningLoop(flowConfig: flowCfg, learningConfig: learningCfg, seed: 7)
        let energies: [Float] = [5, 4, 3, 2]
        let targets: [Float] = [0, 0, 0, 0]

        let before = learningLoop.getParameters().gains
        _ = learningLoop.runEpoch(epoch: 0, energies: energies, targets: targets)
        let after = learningLoop.getParameters().gains

        XCTAssertNotEqual(before, after)
    }
}
