import SwiftUI
import SharedInfrastructure

public struct FlowRingHistogramView: View {
    public let flow: ConfigPipelineSnapshot.FlowSnapshot

    public init(flow: ConfigPipelineSnapshot.FlowSnapshot) {
        self.flow = flow
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Flow ring and boundary histogram")
                .font(.headline)
            GeometryReader { geo in
                Canvas { ctx, size in
                    let w = size.width
                    let h = size.height
                    let cx = w / 2
                    let cy = h / 2
                    let minDim = min(w, h)
                    // Scale model radius to 40% of view min dimension
                    let rModel = flow.radius
                    let rView = max(1, minDim * 0.4)
                    let scale = rModel > 0 ? rView / CGFloat(rModel) : 1

                    // Draw base circle
                    let circleRect = CGRect(x: cx - rView, y: cy - rView, width: rView * 2, height: rView * 2)
                    ctx.stroke(Path(ellipseIn: circleRect), with: .color(.secondary), lineWidth: 1)

                    // Histogram bars
                    let bins = flow.bins
                    let maxBin = max(bins.max() ?? 0.0, 1e-9)
                    let barMax = minDim * 0.18
                    for (i, v) in bins.enumerated() {
                        let frac = CGFloat(v / maxBin)
                        let barLen = barMax * frac
                        let angle = (2.0 * Double.pi) * (Double(i) + 0.5) / Double(max(bins.count, 1))
                        let dx = CGFloat(cos(angle))
                        let dy = CGFloat(sin(angle))
                        let start = CGPoint(x: cx + dx * rView, y: cy + dy * rView)
                        let end = CGPoint(x: start.x + dx * barLen, y: start.y + dy * barLen)
                        var p = Path()
                        p.move(to: start)
                        p.addLine(to: end)
                        ctx.stroke(p, with: .color(.blue.opacity(0.7)), lineWidth: 2)
                    }

                    // Ring seeds
                    for seed in flow.ringSeeds {
                        let x = CGFloat(seed.x) * scale
                        let y = CGFloat(seed.y) * scale
                        let pt = CGPoint(x: cx + x, y: cy + y)
                        let r: CGFloat = 3
                        let rect = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
                        ctx.fill(Path(ellipseIn: rect), with: .color(.orange))
                    }
                }
            }
            .aspectRatio(2, contentMode: .fit)
        }
    }
}
