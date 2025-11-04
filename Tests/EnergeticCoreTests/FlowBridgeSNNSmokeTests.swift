import XCTest
@testable import EnergeticCore

final class FlowBridgeSNNSmokeTests: XCTestCase {
    func testSimulateReturnsBins() {
        let cfg = FlowConfig(
            T: 10,
            radius: 6,
            bins: 16,
            seedLayout: "ring",
            seedRadius: 1,
            lif: .init(decay: 0.9, threshold: 0.4, resetValue: 0.0, surrogate: "fast_sigmoid"),
            dynamics: .init(radialBias: 0.2, noiseStdPos: 0.01, noiseStdDir: 0.05, maxSpeed: 1.0, energyAlpha: 0.9, energyFloor: 1e-6)
        )
        let energies: [UInt16] = Array(repeating: 80, count: 8)
        let out = FlowBridgeSNN.simulate(energies: energies, cfg: cfg, seed: 1)
        XCTAssertEqual(out.count, cfg.bins)
        XCTAssertGreaterThan(out.reduce(0, +), 0.0)
    }
}
