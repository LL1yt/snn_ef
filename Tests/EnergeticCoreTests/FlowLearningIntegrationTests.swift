import XCTest
@testable import EnergeticCore

final class FlowLearningIntegrationTests: XCTestCase {
    func testLearningLoopConvergence() {
        // Setup simple flow config
        let flowCfg = FlowConfig(
            T: 10,
            radius: 10.0,
            bins: 8,
            seedLayout: "ring",
            seedRadius: 1.0,
            lif: .init(decay: 0.9, threshold: 0.8, resetValue: 0.0, surrogate: "fast_sigmoid"),
            dynamics: .init(radialBias: 0.15, noiseStdPos: 0.01, noiseStdDir: 0.05, maxSpeed: 1.0, energyAlpha: 0.95, energyFloor: 1e-5)
        )

        let learningCfg = LearningConfig(
            enabled: true,
            epochs: 20,
            stepsPerEpoch: 10,
            targetSpikeRate: 0.2,
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
            lif: .init(decay: 0.9, threshold: 0.7, resetValue: 0.0, surrogate: "fast_sigmoid"),
            dynamics: .init(radialBias: 0.1, noiseStdPos: 0.01, noiseStdDir: 0.03, maxSpeed: 0.8, energyAlpha: 0.95, energyFloor: 1e-5)
        )

        let learningCfg = LearningConfig(
            enabled: true,
            epochs: 5,
            stepsPerEpoch: 8,
            targetSpikeRate: 0.15,
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
            lif: .init(decay: 0.9, threshold: 0.75, resetValue: 0.0, surrogate: "fast_sigmoid"),
            dynamics: .init(radialBias: 0.12, noiseStdPos: 0.01, noiseStdDir: 0.04, maxSpeed: 0.9, energyAlpha: 0.95, energyFloor: 1e-5)
        )

        let learningCfg = LearningConfig(
            enabled: true,
            epochs: 3,
            stepsPerEpoch: 6,
            targetSpikeRate: 0.18,
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
            lif: .init(decay: 0.88, threshold: 0.95, resetValue: 0.0, surrogate: "fast_sigmoid"),  // High threshold
            dynamics: .init(radialBias: 0.1, noiseStdPos: 0.01, noiseStdDir: 0.05, maxSpeed: 1.0, energyAlpha: 0.95, energyFloor: 1e-5)
        )

        let learningCfg = LearningConfig(
            enabled: true,
            epochs: 1,
            stepsPerEpoch: 8,
            targetSpikeRate: 0.3,  // High target
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
}
