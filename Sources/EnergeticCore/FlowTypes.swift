import Foundation

public struct FlowConfig: Sendable, Equatable {
    public let T: Int
    public let radius: Float
    public let bins: Int
    public let seedLayout: String   // "ring" | "disk"
    public let seedRadius: Float
    public let finalWeightPower: Float
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
        public let spikeKick: Float
        public let noiseStdPos: Float
        public let noiseStdDir: Float
        public let maxSpeed: Float
        public let energyAlpha: Float
        public let energyFloor: Float
        public init(radialBias: Float, spikeKick: Float, noiseStdPos: Float, noiseStdDir: Float, maxSpeed: Float, energyAlpha: Float, energyFloor: Float) {
            self.radialBias = radialBias
            self.spikeKick = spikeKick
            self.noiseStdPos = noiseStdPos
            self.noiseStdDir = noiseStdDir
            self.maxSpeed = maxSpeed
            self.energyAlpha = energyAlpha
            self.energyFloor = energyFloor
        }
    }

    public init(T: Int, radius: Float, bins: Int, seedLayout: String, seedRadius: Float, finalWeightPower: Float, lif: LIF, dynamics: Dynamics) {
        self.T = T
        self.radius = radius
        self.bins = bins
        self.seedLayout = seedLayout
        self.seedRadius = seedRadius
        self.finalWeightPower = finalWeightPower
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
    public var outputs: [Float]   // angular histogram bins (length = bins)
    public var ids: [Int]
    public var posX: [Float]
    public var posY: [Float]
    public var velX: [Float]
    public var velY: [Float]
    public var energy: [Float]
    public var V: [Float]

    public init(step: Int = 0, particles: [FlowParticle], bins: Int) {
        self.step = step
        self.outputs = [Float](repeating: 0, count: bins)
        self.ids = []
        self.posX = []
        self.posY = []
        self.velX = []
        self.velY = []
        self.energy = []
        self.V = []
        reserveCapacity(particles.count)
        for p in particles {
            append(p)
        }
    }

    public var count: Int { ids.count }
    public var isEmpty: Bool { ids.isEmpty }

    public mutating func reserveCapacity(_ n: Int) {
        ids.reserveCapacity(n)
        posX.reserveCapacity(n)
        posY.reserveCapacity(n)
        velX.reserveCapacity(n)
        velY.reserveCapacity(n)
        energy.reserveCapacity(n)
        V.reserveCapacity(n)
    }

    public mutating func append(_ p: FlowParticle) {
        ids.append(p.id)
        posX.append(p.pos.x)
        posY.append(p.pos.y)
        velX.append(p.vel.x)
        velY.append(p.vel.y)
        energy.append(p.energy)
        V.append(p.V)
    }

    public mutating func truncate(to newCount: Int) {
        let current = count
        guard newCount < current else { return }
        let removeCount = current - newCount
        ids.removeLast(removeCount)
        posX.removeLast(removeCount)
        posY.removeLast(removeCount)
        velX.removeLast(removeCount)
        velY.removeLast(removeCount)
        energy.removeLast(removeCount)
        V.removeLast(removeCount)
    }

    public func particle(at index: Int) -> FlowParticle {
        FlowParticle(
            id: ids[index],
            pos: SIMD2<Float>(posX[index], posY[index]),
            vel: SIMD2<Float>(velX[index], velY[index]),
            energy: energy[index],
            V: V[index]
        )
    }

    public func materializeParticles() -> [FlowParticle] {
        var out: [FlowParticle] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            out.append(particle(at: i))
        }
        return out
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
            finalWeightPower: Float(f.projection.finalWeightPower),
            lif: .init(
                decay: Float(f.lif.decay),
                threshold: Float(f.lif.threshold),
                resetValue: Float(f.lif.resetValue),
                surrogate: f.lif.surrogate
            ),
            dynamics: .init(
                radialBias: Float(f.dynamics.radialBias),
                spikeKick: Float(f.dynamics.spikeKick),
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
