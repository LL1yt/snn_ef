import Foundation

/// Core stepper for flow-based SNN dynamics on R^2 with circular projection
public final class FlowRouter {
    public let cfg: FlowConfig
    private var rng: FlowRNG

    public init(cfg: FlowConfig, seed: UInt64) {
        self.cfg = cfg
        self.rng = FlowRNG(seed: seed)
    }

    /// Executes one simulation step in-place; removes projected/dead particles
    public func step(state: inout FlowState) {
        var nextParticles: [FlowParticle] = []
        nextParticles.reserveCapacity(state.particles.count)

        for var p in state.particles {
            // LIF membrane
            let energyNorm = min(max(p.energy / Float(cfg.bins), 0), 1) // heuristic scaling
            let noiseDrive = (rng.nextFloat01() - 0.5) * 0.1
            let vUpdated = cfg.lif.decay * p.V + energyNorm + noiseDrive
            var spiked = false
            if vUpdated >= cfg.lif.threshold {
                p.V = cfg.lif.resetValue
                spiked = true
            } else {
                p.V = max(0, vUpdated)
            }

            // Velocity update: outward drift + optional spike kick + directional noise
            var dir = normalizeOrZero(p.pos)
            if dir.x == 0 && dir.y == 0 {
                let ang = rng.nextUniform(min: 0, max: 2 * .pi)
                dir = SIMD2<Float>(cos(ang), sin(ang))
            }
            var vel = p.vel
            vel += cfg.dynamics.radialBias * dir
            if spiked {
                // spike kick toward current dir + small orthogonal jitter
                let jitterAng = rng.nextUniform(min: -Float.pi, max: Float.pi) * cfg.dynamics.noiseStdDir
                let rot = SIMD2<Float>(cos(jitterAng), sin(jitterAng))
                let kick = SIMD2<Float>(dir.x * rot.x - dir.y * rot.y, dir.x * rot.y + dir.y * rot.x)
                vel += 0.5 * kick
            }
            // Directional noise
            let noiseAng = rng.nextUniform(min: -Float.pi, max: Float.pi)
            let noiseVec = SIMD2<Float>(cos(noiseAng), sin(noiseAng)) * cfg.dynamics.noiseStdPos
            vel += noiseVec
            // Clamp speed
            vel = clampMagnitude(vel, cfg.dynamics.maxSpeed)

            // Integrate position
            p.vel = vel
            p.pos += vel

            // Energy decay and floor
            p.energy *= cfg.dynamics.energyAlpha
            if p.energy < cfg.dynamics.energyFloor { continue }

            // Projection
            var removed = false
            removed = FlowProjector.projectIfNeeded(&p, cfg: cfg, outputs: &state.outputs)
            if !removed { nextParticles.append(p) }
        }

        state.particles = nextParticles
        state.step += 1
    }

    /// Runs for cfg.T steps or until no particles remain; returns filled bins
    public func run(initial particles: [FlowParticle]) -> [Float] {
        var state = FlowState(step: 0, particles: particles, bins: cfg.bins)
        var t = 0
        while t < cfg.T && !state.particles.isEmpty {
            step(state: &state)
            t += 1
        }
        // Final projection at T for remaining particles
        if t >= cfg.T {
            for var p in state.particles {
                _ = FlowProjector.projectIfNeeded(&p, cfg: cfg, outputs: &state.outputs)
            }
            state.particles.removeAll(keepingCapacity: false)
        }
        return state.outputs
    }
}
