import XCTest
@testable import EnergeticCore

final class FlowSeedsTests: XCTestCase {
    func testRingSeedsPositions() {
        let cfg = FlowConfig(
            T: 5,
            radius: 10,
            bins: 8,
            seedLayout: "ring",
            seedRadius: 2,
            finalWeightPower: 1.0,
            lif: .init(decay: 0.9, threshold: 0.5, resetValue: 0.0, surrogate: "fast_sigmoid"),
            dynamics: .init(radialBias: 0.1, spikeKick: 0.0, gainSpikeKickScale: 0.0, noiseStdPos: 0.0, noiseStdDir: 0.0, maxSpeed: 1.0, energyAlpha: 0.9, energyFloor: 1e-5, energySpikeGain: 0.0, energyGainBias: 0.0, energyCap: 0.0)
        )
        let energies: [UInt16] = [1,2,3,4]
        let seeds = FlowSeeds.makeSeeds(energies: energies, cfg: cfg, seed: 0)
        XCTAssertEqual(seeds.count, energies.count)
        for p in seeds {
            let r = length(p.pos)
            XCTAssertEqual(r, cfg.seedRadius, accuracy: 1e-4)
        }
        XCTAssertEqual(seeds[0].pos.x, cfg.seedRadius, accuracy: 1e-4)
    }

    func testDiskSeedsWithinRadius() {
        let cfg = FlowConfig(
            T: 5,
            radius: 10,
            bins: 8,
            seedLayout: "disk",
            seedRadius: 2,
            finalWeightPower: 1.0,
            lif: .init(decay: 0.9, threshold: 0.5, resetValue: 0.0, surrogate: "fast_sigmoid"),
            dynamics: .init(radialBias: 0.1, spikeKick: 0.0, gainSpikeKickScale: 0.0, noiseStdPos: 0.0, noiseStdDir: 0.0, maxSpeed: 1.0, energyAlpha: 0.9, energyFloor: 1e-5, energySpikeGain: 0.0, energyGainBias: 0.0, energyCap: 0.0)
        )
        let energies: [UInt16] = [1,2,3,4,5,6]
        let seeds = FlowSeeds.makeSeeds(energies: energies, cfg: cfg, seed: 0)
        XCTAssertEqual(seeds.count, energies.count)
        for p in seeds {
            let r = length(p.pos)
            XCTAssertLessThanOrEqual(r, cfg.seedRadius + 1e-4)
        }
    }
}
