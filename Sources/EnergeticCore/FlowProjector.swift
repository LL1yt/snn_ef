import Foundation

public enum FlowProjector {
    /// Maps angle (radians, [-π, π]) into bin index [0, bins).
    @inline(__always)
    public static func binIndex(theta: Float, bins: Int) -> Int {
        let twoPi: Float = 2 * .pi
        var t = theta
        // normalize to [0, 2π)
        while t < 0 { t += twoPi }
        while t >= twoPi { t -= twoPi }
        let x = t / twoPi
        let idx = Int(floor(x * Float(bins)))
        return min(max(idx, 0), bins - 1)
    }

    /// Projects particle to boundary bin and accumulates its energy, returning true if removed.
    @inline(__always)
    public static func projectIfNeeded(_ p: inout FlowParticle, cfg: FlowConfig, outputs: inout [Float], gains: [Float]? = nil) -> Bool {
        let r = length(p.pos)
        if r >= cfg.radius {
            let theta = atan2(p.pos.y, p.pos.x)
            let b = binIndex(theta: theta, bins: cfg.bins)
            let g = gain(for: b, bins: cfg.bins, gains: gains)
            outputs[b] += g * max(0, p.energy)
            return true
        }
        return false
    }
    /// Projects particle to a bin with weight based on distance to radius (final projection at T).
    @inline(__always)
    public static func projectFinal(_ p: FlowParticle, cfg: FlowConfig, outputs: inout [Float], gains: [Float]? = nil) {
        let theta = atan2(p.pos.y, p.pos.x)
        let b = binIndex(theta: theta, bins: cfg.bins)
        let g = gain(for: b, bins: cfg.bins, gains: gains)
        let r = length(p.pos)
        let ratio = max(0, min(r / max(cfg.radius, 1e-6), 1))
        let weight = pow(ratio, cfg.finalWeightPower)
        outputs[b] += g * max(0, p.energy) * weight
    }

    @inline(__always)
    public static func gain(for bin: Int, bins: Int, gains: [Float]?) -> Float {
        guard let gains, gains.count == bins else { return 1.0 }
        return gains[bin]
    }
}
