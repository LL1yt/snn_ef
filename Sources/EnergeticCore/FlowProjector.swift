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
    public static func projectIfNeeded(_ p: inout FlowParticle, cfg: FlowConfig, outputs: inout [Float]) -> Bool {
        let r = length(p.pos)
        if r >= cfg.radius {
            let theta = atan2(p.pos.y, p.pos.x)
            let b = binIndex(theta: theta, bins: cfg.bins)
            outputs[b] += max(0, p.energy)
            return true
        }
        return false
    }
}
