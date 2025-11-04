import Foundation

public struct FlowConfig: Sendable, Equatable {
    public let T: Int
    public let radius: Float
    public let bins: Int
    public let seedLayout: String   // "ring" | "disk"
    public let seedRadius: Float
    public let lif: LIF
    public let dynamics: Dynamics

    public struct LIF: Sendable, Equatable {
        public let decay: Float
        public let threshold: Float
        public let resetValue: Float
        public let surrogate: String
        public init(decay: Float, threshold: Float, resetValue: Float, surrogate: String) {
            self.decay = decay
            self.threshold = threshold
            self.resetValue = resetValue
            self.surrogate = surrogate
        }
    }

    public struct Dynamics: Sendable, Equatable {
        public let radialBias: Float
        public let noiseStdPos: Float
        public let noiseStdDir: Float
        public let maxSpeed: Float
        public let energyAlpha: Float
        public let energyFloor: Float
        public init(radialBias: Float, noiseStdPos: Float, noiseStdDir: Float, maxSpeed: Float, energyAlpha: Float, energyFloor: Float) {
            self.radialBias = radialBias
            self.noiseStdPos = noiseStdPos
            self.noiseStdDir = noiseStdDir
            self.maxSpeed = maxSpeed
            self.energyAlpha = energyAlpha
            self.energyFloor = energyFloor
        }
    }

    public init(T: Int, radius: Float, bins: Int, seedLayout: String, seedRadius: Float, lif: LIF, dynamics: Dynamics) {
        self.T = T
        self.radius = radius
        self.bins = bins
        self.seedLayout = seedLayout
        self.seedRadius = seedRadius
        self.lif = lif
        self.dynamics = dynamics
    }
}

public struct FlowParticle: Sendable, Equatable {
    public let id: Int
    public var pos: SIMD2<Float>
    public var vel: SIMD2<Float>
    public var energy: Float
    public var V: Float

    public init(id: Int, pos: SIMD2<Float>, vel: SIMD2<Float>, energy: Float, V: Float) {
        self.id = id
        self.pos = pos
        self.vel = vel
        self.energy = energy
        self.V = V
    }
}

public struct FlowState: Sendable {
    public var step: Int
    public var particles: [FlowParticle]
    public var outputs: [Float]   // angular histogram bins (length = bins)

    public init(step: Int = 0, particles: [FlowParticle], bins: Int) {
        self.step = step
        self.particles = particles
        self.outputs = [Float](repeating: 0, count: bins)
    }
}

// Simple fast RNG (xorshift32) for deterministic noise
public struct FlowRNG: Sendable {
    private var state: UInt32
    public init(seed: UInt64) { self.state = UInt32(truncatingIfNeeded: seed & 0xffff_ffff) &+ 0x9E3779B9 }
    public mutating func nextUInt32() -> UInt32 {
        var x = state
        x ^= x << 13
        x ^= x >> 17
        x ^= x << 5
        state = x
        return x
    }
    public mutating func nextFloat01() -> Float {
        let v = nextUInt32()
        return Float(v) / Float(UInt32.max)
    }
    public mutating func nextUniform(min: Float, max: Float) -> Float {
        min + (max - min) * nextFloat01()
    }
}

// MARK: - Bridging from ConfigCenter (optional)
#if canImport(SharedInfrastructure)
import SharedInfrastructure
extension FlowConfig {
    public static func from(_ r: ConfigRoot.Router) -> FlowConfig {
        let f = r.flow
        return FlowConfig(
            T: f.T,
            radius: Float(f.radius),
            bins: f.projection.bins,
            seedLayout: f.seedLayout,
            seedRadius: Float(f.seedRadius),
            lif: .init(
                decay: Float(f.lif.decay),
                threshold: Float(f.lif.threshold),
                resetValue: Float(f.lif.resetValue),
                surrogate: f.lif.surrogate
            ),
            dynamics: .init(
                radialBias: Float(f.dynamics.radialBias),
                noiseStdPos: Float(f.dynamics.noiseStdPos),
                noiseStdDir: Float(f.dynamics.noiseStdDir),
                maxSpeed: Float(f.dynamics.maxSpeed),
                energyAlpha: Float(f.dynamics.energyAlpha),
                energyFloor: Float(f.dynamics.energyFloor)
            )
        )
    }
}
#endif
