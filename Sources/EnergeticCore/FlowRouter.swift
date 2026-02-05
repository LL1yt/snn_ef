import Foundation

public struct FlowStepEvent: Sendable {
    public let id: Int
    public let pos: SIMD2<Float>
    public let vel: SIMD2<Float>
    public let energy: Float
    public let V: Float
    public let spiked: Bool
    public let projectedBin: Int?
}

/// Core stepper for flow-based SNN dynamics on R^2 with circular projection
public final class FlowRouter {
    public private(set) var cfg: FlowConfig
    private let baseSeed: UInt32
    private let metal: FlowMetalContext

    public init(cfg: FlowConfig, seed: UInt64) {
        self.cfg = cfg
        self.baseSeed = UInt32(truncatingIfNeeded: seed)
        guard let metal = FlowMetalContext() else {
            let detail = FlowMetalContext.lastInitError ?? "unknown"
            preconditionFailure("Metal device/library unavailable. Ensure Shaders are bundled (Package.swift resources) and default.metallib is present. Details: \(detail)")
        }
        self.metal = metal
    }

    public func updateConfig(_ cfg: FlowConfig) {
        self.cfg = cfg
    }

    /// Executes one simulation step in-place; removes projected/dead particles
    public func step(state: inout FlowState, gains: [Float]? = nil) {
        _ = metal.step(state: &state, cfg: cfg, baseSeed: baseSeed, gains: gains, emitEvents: false)
    }

    /// Executes one simulation step and returns per-particle events for visualization.
    /// Updates state in-place, similar to step(state:).
    public func stepWithEvents(state: inout FlowState, gains: [Float]? = nil) -> [FlowStepEvent] {
        return metal.step(state: &state, cfg: cfg, baseSeed: baseSeed, gains: gains, emitEvents: true)
    }

    /// Runs for cfg.T steps on GPU without per-step readback; returns filled bins
    public func run(initial particles: [FlowParticle], gains: [Float]? = nil) -> [Float] {
        return metal.simulate(initial: particles, cfg: cfg, baseSeed: baseSeed, gains: gains)
    }
}
