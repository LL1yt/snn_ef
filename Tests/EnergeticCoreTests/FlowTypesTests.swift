import XCTest
@testable import EnergeticCore

final class FlowTypesTests: XCTestCase {
    func testFlowConfigInit() {
        let cfg = FlowConfig(
            T: 10,
            radius: 10,
            bins: 16,
            seedLayout: "ring",
            seedRadius: 1,
            lif: .init(decay: 0.9, threshold: 0.5, resetValue: 0.0, surrogate: "fast_sigmoid"),
            dynamics: .init(radialBias: 0.1, noiseStdPos: 0.0, noiseStdDir: 0.0, maxSpeed: 1.0, energyAlpha: 0.9, energyFloor: 1e-5)
        )
        XCTAssertEqual(cfg.T, 10)
        XCTAssertEqual(cfg.bins, 16)
        XCTAssertEqual(cfg.seedLayout, "ring")
    }
}
