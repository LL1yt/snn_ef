import XCTest
@testable import EnergeticCore

final class FlowLearningTests: XCTestCase {
    // MARK: - Completion Aggregator Tests

    func testAggregatorSimpleBinning() {
        let config = AggregatorConfig(
            sigmaR: 1.0,
            sigmaE: 1.0,
            alpha: 1.0,
            beta: 1.0,
            gamma: 0.0,  // No alignment weight
            tau: 1.0,
            radius: 10.0
        )

        let completions: [CompletionEvent] = [
            CompletionEvent(particleID: 0, binIndex: 0, position: SIMD2(10.0, 0.0), energy: 5.0, spiked: false),
            CompletionEvent(particleID: 1, binIndex: 0, position: SIMD2(10.1, 0.0), energy: 3.0, spiked: false),
            CompletionEvent(particleID: 2, binIndex: 1, position: SIMD2(0.0, 10.0), energy: 8.0, spiked: true),
        ]

        let yHat = CompletionAggregator.aggregate(
            completions: completions,
            targets: nil,
            config: config,
            bins: 4
        )

        XCTAssertEqual(yHat.count, 4)
        XCTAssertGreaterThan(yHat[0], 0)  // Bin 0 has 2 completions
        XCTAssertGreaterThan(yHat[1], 0)  // Bin 1 has 1 completion
        XCTAssertEqual(yHat[2], 0)        // Bin 2 is empty
        XCTAssertEqual(yHat[3], 0)        // Bin 3 is empty
    }

    func testAggregatorWeightedAverage() {
        let config = AggregatorConfig(
            sigmaR: 1.0,
            sigmaE: 5.0,
            alpha: 1.0,
            beta: 1.0,
            gamma: 0.0,
            tau: 1.0,
            radius: 10.0
        )

        let targets: [Float] = [5.0, 10.0, 0.0, 0.0]

        // Two completions in bin 0: one close to boundary and target, one far
        let completions: [CompletionEvent] = [
            CompletionEvent(particleID: 0, binIndex: 0, position: SIMD2(10.0, 0.0), energy: 5.0, spiked: false),  // r=10, E=5 (perfect)
            CompletionEvent(particleID: 1, binIndex: 0, position: SIMD2(8.0, 0.0), energy: 2.0, spiked: false),   // r=8, E=2 (far)
        ]

        let yHat = CompletionAggregator.aggregate(
            completions: completions,
            targets: targets,
            config: config,
            bins: 4
        )

        // The first completion should dominate due to higher weight
        XCTAssertGreaterThan(yHat[0], 3.0)  // Closer to 5.0 than 2.0
        XCTAssertLessThan(yHat[0], 5.5)
    }

    // MARK: - Loss Functions Tests

    func testBinLoss() {
        let yHat: [Float] = [1.0, 2.0, 3.0, 4.0]
        let target: [Float] = [1.5, 2.0, 2.5, 4.0]
        let gains: [Float] = [1.0, 1.0, 1.0, 1.0]

        let loss = LossFunctions.binLoss(yHat: yHat, target: target, gains: gains, lambdaG: 0.0)

        // Expected: (1.0-1.5)^2 + (2.0-2.0)^2 + (3.0-2.5)^2 + (4.0-4.0)^2
        //         = 0.25 + 0 + 0.25 + 0 = 0.5
        XCTAssertEqual(loss, 0.5, accuracy: 1e-5)
    }

    func testBinLossWithRegularization() {
        let yHat: [Float] = [1.0, 2.0]
        let target: [Float] = [1.0, 2.0]
        let gains: [Float] = [2.0, 3.0]

        let loss = LossFunctions.binLoss(yHat: yHat, target: target, gains: gains, lambdaG: 0.1)

        // MSE = 0 (perfect match)
        // Reg = 0.1 * (2^2 + 3^2) = 0.1 * 13 = 1.3
        XCTAssertEqual(loss, 1.3, accuracy: 1e-5)
    }

    func testSpikeRateLoss() {
        let observed: Float = 0.25
        let target: Float = 0.15

        let loss = LossFunctions.spikeRateLoss(observed: observed, target: target)

        // (0.25 - 0.15)^2 = 0.01
        XCTAssertEqual(loss, 0.01, accuracy: 1e-5)
    }

    func testBoundaryLoss() {
        let completions: [CompletionEvent] = [
            CompletionEvent(particleID: 0, binIndex: 0, position: SIMD2(10.0, 0.0), energy: 5.0, spiked: false),  // r=10, miss=0
            CompletionEvent(particleID: 1, binIndex: 1, position: SIMD2(9.0, 0.0), energy: 3.0, spiked: false),   // r=9, miss=1
            CompletionEvent(particleID: 2, binIndex: 2, position: SIMD2(11.0, 0.0), energy: 4.0, spiked: false),  // r=11, miss=1
        ]

        let loss = LossFunctions.boundaryLoss(completions: completions, radius: 10.0, eps: 0.01)

        // miss[0] = max(0, |10-10| - 0.01) = 0
        // miss[1] = max(0, |9-10| - 0.01) = 0.99
        // miss[2] = max(0, |11-10| - 0.01) = 0.99
        // mean = (0 + 0.99 + 0.99) / 3 = 0.66
        XCTAssertEqual(loss, 0.66, accuracy: 1e-2)
    }

    func testTotalLoss() {
        let binLoss: Float = 1.0
        let spikeLoss: Float = 0.5
        let boundaryLoss: Float = 0.2
        let spikeWeight: Float = 0.1
        let boundaryWeight: Float = 0.05

        let total = LossFunctions.totalLoss(
            binLoss: binLoss,
            spikeLoss: spikeLoss,
            boundaryLoss: boundaryLoss,
            spikeWeight: spikeWeight,
            boundaryWeight: boundaryWeight
        )

        // 1.0 + 0.1*0.5 + 0.05*0.2 = 1.0 + 0.05 + 0.01 = 1.06
        XCTAssertEqual(total, 1.06, accuracy: 1e-5)
    }

    // MARK: - Parameter Update Tests

    func testUpdateGains() {
        var gains: [Float] = [1.0, 1.0, 1.0]
        let yHat: [Float] = [2.0, 3.0, 1.0]
        let target: [Float] = [1.5, 3.0, 2.0]
        let lr: Float = 0.1
        let bounds: (min: Float, max: Float) = (0.1, 2.0)

        ParameterUpdater.updateGains(
            gains: &gains,
            yHat: yHat,
            target: target,
            learningRate: lr,
            bounds: bounds
        )

        // gradient[0] = 2*(2.0-1.5) = 1.0  ->  gains[0] = 1.0 - 0.1*1.0 = 0.9
        // gradient[1] = 2*(3.0-3.0) = 0.0  ->  gains[1] = 1.0
        // gradient[2] = 2*(1.0-2.0) = -2.0 ->  gains[2] = 1.0 - 0.1*(-2.0) = 1.2
        XCTAssertEqual(gains[0], 0.9, accuracy: 1e-5)
        XCTAssertEqual(gains[1], 1.0, accuracy: 1e-5)
        XCTAssertEqual(gains[2], 1.2, accuracy: 1e-5)
    }

    func testUpdateGainsWithBounds() {
        var gains: [Float] = [0.15, 1.9]
        let yHat: [Float] = [10.0, 0.0]
        let target: [Float] = [0.0, 10.0]
        let lr: Float = 0.5
        let bounds: (min: Float, max: Float) = (0.1, 2.0)

        ParameterUpdater.updateGains(
            gains: &gains,
            yHat: yHat,
            target: target,
            learningRate: lr,
            bounds: bounds
        )

        // gains[0] would go below 0.1 -> clamped to 0.1
        XCTAssertEqual(gains[0], 0.1, accuracy: 1e-5)
        // gains[1] would go above 2.0 -> clamped to 2.0
        XCTAssertEqual(gains[1], 2.0, accuracy: 1e-5)
    }

    func testUpdateLifThreshold() {
        var theta: Float = 0.8
        let observedRate: Float = 0.3
        let targetRate: Float = 0.15
        let lr: Float = 0.05
        let bounds: (min: Float, max: Float) = (0.5, 1.0)

        ParameterUpdater.updateLifThreshold(
            threshold: &theta,
            observedRate: observedRate,
            targetRate: targetRate,
            learningRate: lr,
            bounds: bounds
        )

        // observedRate > targetRate -> increase threshold
        XCTAssertGreaterThan(theta, 0.8)
        XCTAssertEqual(theta, 0.85, accuracy: 1e-5)
    }

    func testUpdateRadialBias() {
        var radialBias: Float = 0.15
        let completionRate: Float = 0.6  // Low
        let meanRadialMiss: Float = 0.3  // High
        let lr: Float = 0.01
        let bounds: (min: Float, max: Float) = (0.0, 0.5)

        ParameterUpdater.updateRadialBias(
            radialBias: &radialBias,
            completionRate: completionRate,
            meanRadialMiss: meanRadialMiss,
            learningRate: lr,
            bounds: bounds
        )

        // Low completion and high miss -> increase bias
        XCTAssertGreaterThan(radialBias, 0.15)
        XCTAssertEqual(radialBias, 0.16, accuracy: 1e-5)
    }

    func testUpdateSpikeKick() {
        var spikeKick: Float = 0.5
        let meanRadialMiss: Float = 0.15  // High
        let binLossTrend: Float = -0.1    // Improving
        let lr: Float = 0.05
        let bounds: (min: Float, max: Float) = (0.0, 1.0)

        ParameterUpdater.updateSpikeKick(
            spikeKick: &spikeKick,
            meanRadialMiss: meanRadialMiss,
            binLossTrend: binLossTrend,
            learningRate: lr,
            bounds: bounds
        )

        // High miss -> increase kick
        XCTAssertGreaterThan(spikeKick, 0.5)
        XCTAssertEqual(spikeKick, 0.55, accuracy: 1e-5)
    }

    // MARK: - Target Loader Tests

    func testTargetFromCapsuleDigits() {
        let energies: [Float] = [1.5, 2.3, 5.7, 10.2, 3.8]
        let bins = 8

        let targets = TargetLoader.fromCapsuleDigits(energies: energies, bins: bins)

        XCTAssertEqual(targets.count, bins)
        // bin = floor(E) % bins
        // E=1.5 -> bin 1, E=2.3 -> bin 2, E=5.7 -> bin 5, E=10.2 -> bin 2 (10%8=2), E=3.8 -> bin 3
        XCTAssertGreaterThan(targets[1], 0)  // 1.5
        XCTAssertGreaterThan(targets[2], 0)  // 2.3 + 10.2
        XCTAssertGreaterThan(targets[3], 0)  // 3.8
        XCTAssertGreaterThan(targets[5], 0)  // 5.7
    }

    // MARK: - Checkpoint Tests

    func testCheckpointSaveLoad() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let params = RouterLearningState.SerializableParameters(
            gains: [1.0, 1.1, 0.9],
            lifThreshold: 0.85,
            radialBias: 0.2,
            spikeKick: 0.5
        )
        let metrics = LearningMetrics(
            epoch: 10,
            totalLoss: 1.5,
            binLoss: 1.0,
            spikeLoss: 0.3,
            boundaryLoss: 0.2,
            spikeRate: 0.15,
            completionRate: 0.85,
            meanRadialMiss: 0.1,
            nonzeroBins: 50,
            yHatStats: .init(mean: 2.0, variance: 0.5, min: 0.0, max: 10.0),
            paramDeltas: .init(gainMean: 0.01, gainVariance: 0.001, lifThreshold: 0.02, radialBias: 0.005, spikeKick: 0.01)
        )
        let state = RouterLearningState(epoch: 10, params: params, metrics: metrics)

        try CheckpointManager.save(state: state, to: tempDir, filename: "test_checkpoint.json")

        let loaded = try CheckpointManager.load(from: tempDir.appendingPathComponent("test_checkpoint.json"))

        XCTAssertEqual(loaded.epoch, 10)
        XCTAssertEqual(loaded.params.lifThreshold, 0.85, accuracy: 1e-5)
        XCTAssertEqual(loaded.metrics.totalLoss, 1.5, accuracy: 1e-5)
    }
}
