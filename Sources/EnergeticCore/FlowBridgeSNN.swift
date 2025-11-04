import Foundation

/// High-level entry for flow simulation from capsule energies -> circular histogram
public enum FlowBridgeSNN {
    /// Simulate and return float bins (length = cfg.bins)
    public static func simulate(energies: [UInt16], cfg: FlowConfig, seed: UInt64) -> [Float] {
        let seeds = FlowSeeds.makeSeeds(energies: energies, cfg: cfg, seed: seed)
        let router = FlowRouter(cfg: cfg, seed: seed &+ 0xA5A5A5A5)
        return router.run(initial: seeds)
    }
}
