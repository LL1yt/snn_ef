import XCTest
@testable import EnergeticCore

final class FlowRouterTests: XCTestCase {
    func testRunProjectsToBins() {
        let cfg = FlowConfig(
            T: 16,
            radius: 5,
            bins: 12,
            seedLayout: "ring",
            seedRadius: 1,
            finalWeightPower: 1.0,
            lif: .init(decay: 0.9, threshold: 0.3, resetValue: 0.0, surrogate: "fast_sigmoid"),
            dynamics: .init(radialBias: 0.2, spikeKick: 0.5, noiseStdPos: 0.0, noiseStdDir: 0.0, maxSpeed: 1.0, energyAlpha: 0.95, energyFloor: 1e-5)
        )
        let energies = [UInt16](repeating: 50, count: 6)
        let seeds = FlowSeeds.makeSeeds(energies: energies, cfg: cfg, seed: 42)
        let router = FlowRouter(cfg: cfg, seed: 123)
        let bins = router.run(initial: seeds)
        XCTAssertEqual(bins.count, cfg.bins)
        XCTAssertGreaterThan(bins.reduce(0, +), 0.0)
    }

    func testFinalProjectionWeightsByRadius() {
        let cfg = FlowConfig(
            T: 1,
            radius: 10,
            bins: 8,
            seedLayout: "ring",
            seedRadius: 1,
            finalWeightPower: 1.0,
            lif: .init(decay: 0.9, threshold: 0.5, resetValue: 0.0, surrogate: "fast_sigmoid"),
            dynamics: .init(radialBias: 0.0, spikeKick: 0.0, noiseStdPos: 0.0, noiseStdDir: 0.0, maxSpeed: 1.0, energyAlpha: 1.0, energyFloor: 0.0)
        )

        var outputs = [Float](repeating: 0, count: cfg.bins)
        let near = FlowParticle(id: 0, pos: SIMD2<Float>(5, 0), vel: .zero, energy: 10, V: 0)
        let atBoundary = FlowParticle(id: 1, pos: SIMD2<Float>(10, 0), vel: .zero, energy: 10, V: 0)

        FlowProjector.projectFinal(near, cfg: cfg, outputs: &outputs, gains: nil)
        let nearContribution = outputs[0]
        outputs = [Float](repeating: 0, count: cfg.bins)
        FlowProjector.projectFinal(atBoundary, cfg: cfg, outputs: &outputs, gains: nil)
        let boundaryContribution = outputs[0]

        XCTAssertGreaterThan(boundaryContribution, nearContribution)
        XCTAssertEqual(nearContribution, 5.0, accuracy: 1e-4)
        XCTAssertEqual(boundaryContribution, 10.0, accuracy: 1e-4)
    }
}
