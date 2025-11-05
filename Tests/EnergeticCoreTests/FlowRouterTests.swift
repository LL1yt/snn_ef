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
            lif: .init(decay: 0.9, threshold: 0.3, resetValue: 0.0, surrogate: "fast_sigmoid"),
            dynamics: .init(radialBias: 0.2, noiseStdPos: 0.0, noiseStdDir: 0.0, maxSpeed: 1.0, energyAlpha: 0.95, energyFloor: 1e-5)
        )
        let energies = [UInt16](repeating: 50, count: 6)
        let seeds = FlowSeeds.makeSeeds(energies: energies, cfg: cfg, seed: 42)
        let router = FlowRouter(cfg: cfg, seed: 123)
        let bins = router.run(initial: seeds)
        XCTAssertEqual(bins.count, cfg.bins)
        XCTAssertGreaterThan(bins.reduce(0, +), 0.0)
    }
}
