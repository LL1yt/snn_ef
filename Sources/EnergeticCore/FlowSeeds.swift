import Foundation

public enum FlowSeeds {
    /// Places N particles on a ring with radius seedRadius, angles θ_i = 2π·i/N.
    public static func makeSeeds(energies: [UInt16], cfg: FlowConfig, seed: UInt64 = 0) -> [FlowParticle] {
        let n = energies.count
        guard n > 0 else { return [] }
        var particles: [FlowParticle] = []
        particles.reserveCapacity(n)
        let r0 = max(0, min(cfg.seedRadius, cfg.radius * 0.999))

        for i in 0..<n {
            let pos = seedPosition(index: i, count: n, layout: cfg.seedLayout, seedRadius: r0)
            // initial velocity: small outward bias
            let dir = normalizeOrZero(pos)
            let vel = dir * 0.05
            let e = max(0, Float(energies[i]))
            let p = FlowParticle(id: i, pos: pos, vel: vel, energy: e, V: 0)
            particles.append(p)
        }
        return particles
    }

    /// Places N particles on a ring with radius seedRadius, angles θ_i = 2π·i/N.
    /// Float version for learning pipeline.
    public static func makeSeeds(energies: [Float], layout: String, radius: Float, bins: Int) -> [FlowParticle] {
        let n = energies.count
        guard n > 0 else { return [] }
        var particles: [FlowParticle] = []
        particles.reserveCapacity(n)
        let r0 = max(0, min(radius, radius * 0.999))

        for i in 0..<n {
            let pos = seedPosition(index: i, count: n, layout: layout, seedRadius: r0)
            // initial velocity: small outward bias
            let dir = normalizeOrZero(pos)
            let vel = dir * 0.05
            let e = max(0, energies[i])
            let p = FlowParticle(id: i, pos: pos, vel: vel, energy: e, V: 0)
            particles.append(p)
        }
        return particles
    }
}

@inline(__always)
private func seedPosition(index i: Int, count n: Int, layout: String, seedRadius: Float) -> SIMD2<Float> {
    let twoPi: Float = 2 * .pi
    if layout.lowercased() == "disk" {
        // Deterministic low-discrepancy disk fill (golden angle + sqrt radius).
        let golden: Float = 0.61803398875
        let angle = twoPi * fract(Float(i) * golden)
        let radius = seedRadius * sqrt((Float(i) + 0.5) / max(1, Float(n)))
        return SIMD2<Float>(radius * cos(angle), radius * sin(angle))
    }
    // Default: ring
    let theta = twoPi * Float(i) / max(1, Float(n))
    return SIMD2<Float>(seedRadius * cos(theta), seedRadius * sin(theta))
}

@inline(__always)
private func fract(_ x: Float) -> Float {
    x - floor(x)
}
@inline(__always)
public func length(_ v: SIMD2<Float>) -> Float { sqrt(max(0, v.x * v.x + v.y * v.y)) }

@inline(__always)
public func normalizeOrZero(_ v: SIMD2<Float>) -> SIMD2<Float> {
    let l = length(v)
    return l > 0 ? v / l : SIMD2<Float>(0, 0)
}

@inline(__always)
public func clampMagnitude(_ v: SIMD2<Float>, _ maxLen: Float) -> SIMD2<Float> {
    let l = length(v)
    guard l > maxLen && l > 0 else { return v }
    return v * (maxLen / l)
}
