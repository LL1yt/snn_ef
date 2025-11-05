import Foundation
import SwiftUI
import EnergeticCore
import SharedInfrastructure

@MainActor
public final class FlowLiveViewModel: ObservableObject {
    @Published public private(set) var stepIndex: Int = 0
    @Published public private(set) var outputs: [Float]
    @Published public private(set) var particles: [FlowParticle]
    @Published public private(set) var completions: [(id: Int, bin: Int, pos: SIMD2<Float>)] = []
    @Published public private(set) var lastEvents: [FlowStepEvent] = []
    @Published public private(set) var isFinished: Bool = false
    @Published public private(set) var stepHistory: [StepRecord] = []

    public struct Segment: Sendable { public let from: SIMD2<Float>; public let to: SIMD2<Float>; public let spiked: Bool }
    @Published public private(set) var segments: [Int: [Segment]] = [:]  // by tracked id

    public let cfg: FlowConfig
    private let router: FlowRouter
    private var state: FlowState
    private let trackIDs: Set<Int>
    private var lastPos: [Int: SIMD2<Float>] = [:]

    public init(cfg: FlowConfig, energies: [UInt16], seed: UInt64, sampleCount: Int = 2) {
        self.cfg = cfg
        self.router = FlowRouter(cfg: cfg, seed: seed)
        let seeds = FlowSeeds.makeSeeds(energies: energies, cfg: cfg, seed: seed)
        self.state = FlowState(step: 0, particles: seeds, bins: cfg.bins)
        self.outputs = state.outputs
        self.particles = state.particles
        self.trackIDs = Set(seeds.prefix(sampleCount).map { $0.id })
        for p in seeds where trackIDs.contains(p.id) { lastPos[p.id] = p.pos }
    }

    public func reset(energies: [UInt16], seed: UInt64) {
        let seeds = FlowSeeds.makeSeeds(energies: energies, cfg: cfg, seed: seed)
        self.state = FlowState(step: 0, particles: seeds, bins: cfg.bins)
        self.outputs = state.outputs
        self.particles = state.particles
        self.stepIndex = 0
        self.completions.removeAll()
        self.lastEvents.removeAll()
        self.stepHistory.removeAll()
        self.segments.removeAll()
        self.lastPos.removeAll()
        for p in seeds where trackIDs.contains(p.id) { lastPos[p.id] = p.pos }
        self.isFinished = false
    }

    public func step() {
        guard !state.particles.isEmpty, stepIndex < cfg.T else {
            isFinished = true
            finalizeProjection()
            return
        }
        let events = router.stepWithEvents(state: &state)
        lastEvents = events.filter { trackIDs.contains($0.id) }
        // Trails for tracked ids
        for e in lastEvents {
            if let prev = lastPos[e.id] {
                let seg = Segment(from: prev, to: e.pos, spiked: e.spiked)
                segments[e.id, default: []].append(seg)
            }
            lastPos[e.id] = e.pos
        }
        // Capture completions (projected this step)
        for e in events {
            if let bin = e.projectedBin {
                completions.append((id: e.id, bin: bin, pos: e.pos))
            }
        }
        // Persist step history for table
        stepHistory.append(StepRecord(step: state.step, events: lastEvents))
        outputs = state.outputs
        particles = state.particles
        stepIndex = state.step
        if particles.isEmpty { isFinished = true; finalizeProjection() }
    }

    public func stepMultiple(_ n: Int) { for _ in 0..<n { step() ; if isFinished { break } } }

    public func runToEnd() { while !isFinished { step() } }

    private func finalizeProjection() {
        if stepIndex >= cfg.T {
            // Project remaining for completeness
            var tmp = state
            if !tmp.particles.isEmpty {
                for var p in tmp.particles {
                    let r = length(p.pos)
                    if r >= cfg.radius {
                        let theta = atan2(p.pos.y, p.pos.x)
                        let b = FlowProjector.binIndex(theta: theta, bins: cfg.bins)
                        outputs[b] += max(0, p.energy)
                        completions.append((id: p.id, bin: b, pos: p.pos))
                    }
                }
                particles.removeAll()
            }
        }
    }
    public struct StepRecord: Identifiable, Sendable { public let id = UUID(); public let step: Int; public let events: [FlowStepEvent] }
}

public struct FlowLiveView: View {
    @StateObject private var vm: FlowLiveViewModel

    public init(cfg: FlowConfig, energies: [UInt16], seed: UInt64) {
        _vm = StateObject(wrappedValue: FlowLiveViewModel(cfg: cfg, energies: energies, seed: seed))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controls
            ringCanvas
            histogram
            samplesTable
            historyTable
        }
        .padding()
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Text("Step: \(vm.stepIndex) / \(vm.cfg.T)")
            Spacer()
            Button("Step") { vm.step() }.disabled(vm.isFinished)
            Button("×5") { vm.stepMultiple(5) }.disabled(vm.isFinished)
            Button("Run") { vm.runToEnd() }.disabled(vm.isFinished)
        }
    }

    private var ringCanvas: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let w = size.width, h = size.height
                let cx = w/2, cy = h/2
                let minDim = min(w, h)
                let rModel = Double(vm.cfg.radius)
                let rView = max(1.0, Double(minDim) * 0.4)
                let scale = rModel > 0 ? rView / rModel : 1.0

                // Base circle
                let circle = CGRect(x: cx - rView, y: cy - rView, width: rView*2, height: rView*2)
                ctx.stroke(Path(ellipseIn: circle), with: .color(.secondary), lineWidth: 1)

                // Completions markers
                for c in vm.completions {
                    let x = Double(c.pos.x) * scale
                    let y = Double(c.pos.y) * scale
                    let pt = CGPoint(x: cx + x, y: cy + y)
                    let r: CGFloat = 4
                    ctx.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r*2, height: r*2)), with: .color(.green))
                }

                // Trails (segments): red when spiked at this step
                for (_, segs) in vm.segments {
                    for s in segs {
                        let p0 = CGPoint(x: cx + Double(s.from.x) * scale, y: cy + Double(s.from.y) * scale)
                        let p1 = CGPoint(x: cx + Double(s.to.x) * scale, y: cy + Double(s.to.y) * scale)
                        var path = Path(); path.move(to: p0); path.addLine(to: p1)
                        let color: Color = s.spiked ? .red : .gray.opacity(0.5)
                        ctx.stroke(path, with: .color(color), lineWidth: s.spiked ? 2 : 1)
                    }
                }

                // Particles
                for e in vm.particles {
                    let x = Double(e.pos.x) * scale
                    let y = Double(e.pos.y) * scale
                    let pt = CGPoint(x: cx + x, y: cy + y)
                    let r: CGFloat = 3
                    ctx.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r*2, height: r*2)), with: .color(.orange))
                }

                // Tracked recent events (spikes glow)
                for ev in vm.lastEvents where ev.spiked {
                    let x = Double(ev.pos.x) * scale
                    let y = Double(ev.pos.y) * scale
                    let pt = CGPoint(x: cx + x, y: cy + y)
                    let rr: CGFloat = 6
                    ctx.stroke(Path(ellipseIn: CGRect(x: pt.x - rr, y: pt.y - rr, width: rr*2, height: rr*2)), with: .color(.red.opacity(0.7)), lineWidth: 2)
                }
            }
        }
        .frame(height: 300)
    }

    private var histogram: some View {
        let bins = vm.outputs.map { Double($0) }
        let maxBin = max(bins.max() ?? 0.0, 1e-9)
        return GeometryReader { geo in
            Canvas { ctx, size in
                let w = size.width, h = size.height
                let barW = w / CGFloat(max(bins.count, 1))
                for (i, v) in bins.enumerated() {
                    let frac = CGFloat(v / maxBin)
                    let bh = h * frac
                    let rect = CGRect(x: CGFloat(i) * barW, y: h - bh, width: max(barW - 1, 1), height: bh)
                    ctx.fill(Path(rect), with: .color(.blue.opacity(0.7)))
                }
            }
        }
        .frame(height: 120)
    }

    private var samplesTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tracked streams (recent step)").font(.headline)
            if vm.lastEvents.isEmpty {
                Text("No tracked events yet").font(.caption).foregroundColor(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("id").foregroundColor(.secondary)
                        Text("r").foregroundColor(.secondary)
                        Text("θ(rad)").foregroundColor(.secondary)
                        Text("E").foregroundColor(.secondary)
                        Text("V").foregroundColor(.secondary)
                        Text("Spike").foregroundColor(.secondary)
                        Text("Bin").foregroundColor(.secondary)
                    }
                    ForEach(vm.lastEvents, id: \.id) { e in
                        let r = length(e.pos)
                        let theta = atan2(e.pos.y, e.pos.x)
                        GridRow {
                            Text("\\(e.id)")
                            Text(String(format: "%.2f", r))
                            Text(String(format: "%.2f", theta))
                            Text(String(format: "%.1f", e.energy))
                            Text(String(format: "%.2f", e.V))
                            Text(e.spiked ? "YES" : "-")
                            Text(e.projectedBin.map(String.init) ?? "-")
                        }
                    }
                }
                .font(.caption.monospaced())
            }
        }
    }

    private var historyTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tracked history (all steps)").font(.headline)
            if vm.stepHistory.isEmpty {
                Text("No history yet").font(.caption).foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(vm.stepHistory.suffix(200)) { rec in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Step \\(rec.step)").font(.caption).foregroundColor(.secondary)
                                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                                    GridRow {
                                        Text("id").foregroundColor(.secondary)
                                        Text("r").foregroundColor(.secondary)
                                        Text("θ").foregroundColor(.secondary)
                                        Text("E").foregroundColor(.secondary)
                                        Text("V").foregroundColor(.secondary)
                                        Text("Spike").foregroundColor(.secondary)
                                        Text("Bin").foregroundColor(.secondary)
                                    }
                                    ForEach(rec.events, id: \.id) { e in
                                        let r = length(e.pos)
                                        let theta = atan2(e.pos.y, e.pos.x)
                                        GridRow {
                                            Text("\\(e.id)")
                                            Text(String(format: "%.2f", r))
                                            Text(String(format: "%.2f", theta))
                                            Text(String(format: "%.1f", e.energy))
                                            Text(String(format: "%.2f", e.V))
                                            Text(e.spiked ? "YES" : "-")
                                            Text(e.projectedBin.map(String.init) ?? "-")
                                        }
                                    }
                                }
                                .font(.caption.monospaced())
                                .padding(.bottom, 4)
                            }
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
    }
}
