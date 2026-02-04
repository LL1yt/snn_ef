import Foundation
import SwiftUI
import SharedInfrastructure

public struct LearningMetricsView: View {
    @StateObject private var viewModel: LearningMetricsViewModel
    private let title: String
    @State private var selectedIndex: Int?
    @State private var followLatest: Bool = true
    @State private var snapToGrid: Bool = true

    public init(logFileURL: URL?, title: String = "Learning metrics", pollInterval: TimeInterval = 0.5, maxRecords: Int = 200) {
        _viewModel = StateObject(wrappedValue: LearningMetricsViewModel(
            logFileURL: logFileURL,
            pollInterval: pollInterval,
            maxRecords: maxRecords
        ))
        self.title = title
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            contentView
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.06)))
        .onChange(of: viewModel.records.count) { _, _ in
            if followLatest, let last = viewModel.records.indices.last {
                selectedIndex = last
            }
        }
    }

    private var header: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            scrubberControls
        }
    }

    @ViewBuilder
    private var contentView: some View {
        if viewModel.records.isEmpty {
            Text("No learning metrics yet. Run energetic-cli learn to produce trainer.loop logs.")
                .font(.footnote)
                .foregroundColor(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    trajectoryColumn
                    histogramColumn
                }
                HStack(alignment: .top, spacing: 16) {
                    metricsColumn
                    paramsColumn
                    dynamicsColumn
                }
            }
        }
    }

    private var metricsColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            lossCharts
            rateCharts
        }
        .frame(maxWidth: 300)
    }

    private var paramsColumn: some View {
        paramsPanel
            .frame(maxWidth: 260)
    }

    @ViewBuilder
    private var histogramColumn: some View {
        histogramPanel
            .frame(maxWidth: 320)
    }

    @ViewBuilder
    private var dynamicsColumn: some View {
        if let record = currentRecord {
            DynamicsTracesView(traces: record.traces ?? [])
        }
    }

    private var trajectoryColumn: some View {
        if let record = currentRecord {
            return AnyView(
                TrajectoryTracesView(
                    paths: record.paths ?? [],
                    radius: record.radius.R,
                    snapToGrid: snapToGrid
                )
                .frame(minWidth: 520, maxWidth: .infinity)
            )
        }
        return AnyView(EmptyView())
    }

    private var lossCharts: some View {
        let total = viewModel.records.map { Double($0.loss.total) }
        let bins = viewModel.records.map { Double($0.loss.bins) }
        let spike = viewModel.records.map { Double($0.loss.spike) }
        let boundary = viewModel.records.map { Double($0.loss.boundary) }

        return VStack(alignment: .leading, spacing: 8) {
            Text("Loss")
                .font(.subheadline)
                .foregroundColor(.secondary)
            HStack(spacing: 12) {
                MetricLineChart(title: "Total", values: total, color: .blue)
                MetricLineChart(title: "Bins", values: bins, color: .teal)
                MetricLineChart(title: "Spike", values: spike, color: .orange)
                MetricLineChart(title: "Boundary", values: boundary, color: .purple)
            }
        }
    }

    private var rateCharts: some View {
        let spike = viewModel.records.map { Double($0.rates.spike) }
        let completion = viewModel.records.map { Double($0.rates.completion) }
        let miss = viewModel.records.map { Double($0.radius.meanMiss) }

        return VStack(alignment: .leading, spacing: 8) {
            Text("Rates")
                .font(.subheadline)
                .foregroundColor(.secondary)
            HStack(spacing: 12) {
                MetricLineChart(title: "Spike", values: spike, color: .red)
                MetricLineChart(title: "Completion", values: completion, color: .green)
                MetricLineChart(title: "Radial miss", values: miss, color: .gray)
            }
        }
    }

    @ViewBuilder
    private var paramsPanel: some View {
        if let latest = currentRecord {
            VStack(alignment: .leading, spacing: 6) {
                Text("Parameters")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                HStack(spacing: 16) {
                    metricCard(title: "LIF", value: String(format: "%.3f", latest.params.lif))
                    metricCard(title: "Radial", value: String(format: "%.3f", latest.params.radialBias))
                    metricCard(title: "Spike", value: String(format: "%.3f", latest.params.spikeKick))
                    metricCard(title: "Gain mean", value: String(format: "%.3f", latest.params.gainMean))
                    metricCard(title: "Gain var", value: String(format: "%.3f", latest.params.gainVariance))
                }
                if let acc = latest.optionAccuracy {
                    optionAccuracyRow(value: acc)
                }
            }
        }
    }

    @ViewBuilder
    private var histogramPanel: some View {
        if let latest = currentRecord, let histogram = latest.histogram {
            let (yHat, target) = downsampleHistogram(yHat: histogram.yHat, target: histogram.target, maxBins: 128)
            VStack(alignment: .leading, spacing: 8) {
                Text("Histogram (output vs target)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                HistogramComparisonView(yHat: yHat, target: target)
                    .frame(height: 180)
            }
        } else {
            Text("Histogram not available in log payload.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private var currentRecord: LearningLogPayload? {
        guard !viewModel.records.isEmpty else { return nil }
        if let selectedIndex, viewModel.records.indices.contains(selectedIndex) {
            return viewModel.records[selectedIndex]
        }
        return viewModel.records.last
    }

    private var scrubberControls: some View {
        let count = viewModel.records.count
        return HStack(spacing: 8) {
            Button("Prev") {
                guard count > 0 else { return }
                followLatest = false
                let idx = (selectedIndex ?? count - 1) - 1
                selectedIndex = max(0, idx)
            }
            .disabled(count == 0)
            Button("Next") {
                guard count > 0 else { return }
                followLatest = false
                let idx = (selectedIndex ?? count - 1) + 1
                selectedIndex = min(count - 1, idx)
            }
            .disabled(count == 0)

            if count > 1 {
                Slider(value: Binding(
                    get: { Double(selectedIndex ?? count - 1) },
                    set: { newValue in
                        followLatest = false
                        selectedIndex = Int(newValue.rounded())
                    }
                ), in: 0...Double(count - 1), step: 1)
                .frame(width: 140)
            }

            Toggle("Live", isOn: $followLatest)
                .toggleStyle(.switch)
                .onChange(of: followLatest) { _, newValue in
                    if newValue, let last = viewModel.records.indices.last {
                        selectedIndex = last
                    }
                }
                .disabled(count == 0)

            Toggle("Snap", isOn: $snapToGrid)
                .toggleStyle(.switch)
                .disabled(count == 0)

            if let record = currentRecord {
                Text("Epoch \(record.epoch)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .font(.caption)
    }

    private func metricCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.body.monospacedDigit())
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
    }

    private func optionAccuracyRow(value: Float) -> some View {
        let pct = max(0, min(1, value))
        return HStack(spacing: 8) {
            Text("Option acc")
                .font(.caption)
                .foregroundColor(.secondary)
            ProgressView(value: Double(pct))
                .progressViewStyle(.linear)
                .frame(width: 120)
            Text(String(format: "%.2f", pct))
                .font(.caption.monospacedDigit())
        }
    }

    private func downsampleHistogram(yHat: [Float], target: [Float]?, maxBins: Int) -> ([Float], [Float]?) {
        guard yHat.count > maxBins else { return (yHat, target) }
        let factor = max(1, yHat.count / maxBins)
        var yOut: [Float] = []
        var tOut: [Float]? = target != nil ? [] : nil
        for i in stride(from: 0, to: yHat.count, by: factor) {
            let slice = yHat[i..<min(i + factor, yHat.count)]
            let avg = slice.reduce(0, +) / Float(slice.count)
            yOut.append(avg)
            if let target {
                let tslice = target[i..<min(i + factor, target.count)]
                let tavg = tslice.reduce(0, +) / Float(tslice.count)
                tOut?.append(tavg)
            }
        }
        return (yOut, tOut)
    }
}

@MainActor
final class LearningMetricsViewModel: ObservableObject {
    @Published var records: [LearningLogPayload] = []
    @Published var errorMessage: String?

    private let logFileURL: URL?
    private let maxRecords: Int
    private var timer: Timer?
    private var lastOffset: UInt64 = 0
    private var pending: String = ""

    init(logFileURL: URL?, pollInterval: TimeInterval, maxRecords: Int) {
        self.logFileURL = logFileURL
        self.maxRecords = maxRecords
        if logFileURL == nil {
            self.errorMessage = "No log file configured (logging destination is stdout only)."
        }
        startTimer(interval: pollInterval)
    }

    deinit {
        timer?.invalidate()
    }

    private func startTimer(interval: TimeInterval) {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.pollLogFile()
        }
    }

    private func pollLogFile() {
        guard let url = logFileURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            if errorMessage == nil {
                errorMessage = "Log file not found at \(url.path)."
            }
            return
        }

        do {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let fileSize = attrs[.size] as? UInt64,
               fileSize < lastOffset {
                lastOffset = 0
                pending = ""
                records.removeAll()
            }
            let handle = try FileHandle(forReadingFrom: url)
            try handle.seek(toOffset: lastOffset)
            let data = handle.readDataToEndOfFile()
            lastOffset += UInt64(data.count)
            try? handle.close()

            if data.isEmpty { return }
            guard let chunk = String(data: data, encoding: .utf8) else { return }
            parseChunk(chunk)
        } catch {
            errorMessage = "Failed to read log file: \(error.localizedDescription)"
        }
    }

    private func parseChunk(_ chunk: String) {
        var combined = pending + chunk
        if !combined.hasSuffix("\n") {
            if let lastNewline = combined.lastIndex(of: "\n") {
                pending = String(combined[combined.index(after: lastNewline)...])
                combined = String(combined[..<combined.index(after: lastNewline)])
            } else {
                pending = combined
                return
            }
        } else {
            pending = ""
        }

        let lines = combined.split(separator: "\n")
        for line in lines {
            if let payload = LearningLogPayload.parse(from: line) {
                records.append(payload)
                if records.count > maxRecords {
                    records.removeFirst(records.count - maxRecords)
                }
            }
        }
    }
}

struct LearningLogPayload: Decodable {
    struct Loss: Decodable { let total: Float; let bins: Float; let negative: Float?; let spike: Float; let boundary: Float }
    struct Rates: Decodable { let spike: Float; let completion: Float }
    struct Radius: Decodable { let meanMiss: Float; let R: Float? }
    struct Params: Decodable { let lif: Float; let radialBias: Float; let spikeKick: Float; let gainMean: Float; let gainVariance: Float }
    struct Bins: Decodable { let nonzero: Int; let mean: Float; let variance: Float; let min: Float; let max: Float }
    struct Histogram: Decodable { let yHat: [Float]; let target: [Float]? }
    struct TraceStep: Decodable {
        let t: Int
        let r: Float
        let theta: Float
        let energy: Float
        let V: Float
        let spiked: Bool
        let bin: Int?
        let speed: Float
        let radialSpeed: Float
    }
    struct Trace: Decodable { let id: Int; let steps: [TraceStep] }
    struct PathPoint: Decodable {
        let t: Int
        let x: Float
        let y: Float
        let spiked: Bool
        let bin: Int?
        let speed: Float
        let radialSpeed: Float
    }
    struct Path: Decodable { let id: Int; let points: [PathPoint] }

    let epoch: Int
    let loss: Loss
    let rates: Rates
    let radius: Radius
    let optionAccuracy: Float?
    let params: Params
    let bins: Bins
    let histogram: Histogram?
    let traces: [Trace]?
    let paths: [Path]?

    private static let prefix = "learning.metrics "

    static func parse(from line: Substring) -> LearningLogPayload? {
        let parts = line.split(separator: "]", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 4 else { return nil }
        let processPart = parts[2]
        let process = processPart.hasPrefix("[") ? processPart.dropFirst() : processPart
        guard process == "trainer.loop" else { return nil }

        let messagePart = parts[3].trimmingCharacters(in: .whitespaces)
        guard messagePart.hasPrefix(prefix) else { return nil }
        let jsonStart = messagePart.index(messagePart.startIndex, offsetBy: prefix.count)
        let jsonString = String(messagePart[jsonStart...])

        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LearningLogPayload.self, from: data)
    }
}

struct MetricLineChart: View {
    let title: String
    let values: [Double]
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            LineChart(values: values, color: color)
                .frame(height: 60)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        }
    }
}

struct LineChart: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                guard values.count > 1 else { return }
                let minV = values.min() ?? 0
                let maxV = values.max() ?? 1
                let range = max(maxV - minV, 1e-9)
                let stepX = size.width / CGFloat(values.count - 1)

                var path = Path()
                for (i, v) in values.enumerated() {
                    let x = CGFloat(i) * stepX
                    let y = size.height - (CGFloat((v - minV) / range) * size.height)
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                ctx.stroke(path, with: .color(color), lineWidth: 2)
            }
        }
    }
}

struct HistogramComparisonView: View {
    let yHat: [Float]
    let target: [Float]?

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let w = size.width
                let h = size.height
                let count = max(yHat.count, 1)
                let barW = w / CGFloat(count)
                let maxY = max(yHat.max() ?? 0, target?.max() ?? 0, 1e-9)

                for i in 0..<count {
                    let yVal = CGFloat(yHat[i]) / CGFloat(maxY)
                    let yHeight = h * yVal
                    let x = CGFloat(i) * barW
                    let rect = CGRect(x: x, y: h - yHeight, width: max(barW - 1, 1), height: yHeight)
                    ctx.fill(Path(rect), with: .color(.blue.opacity(0.6)))

                    if let target, i < target.count {
                        let tVal = CGFloat(target[i]) / CGFloat(maxY)
                        let tHeight = h * tVal
                        let tRect = CGRect(x: x, y: h - tHeight, width: max(barW - 1, 1), height: tHeight)
                        ctx.stroke(Path(tRect), with: .color(.green.opacity(0.8)), lineWidth: 1)
                    }
                }
            }
        }
    }
}

struct DynamicsTracesView: View {
    let traces: [LearningLogPayload.Trace]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dynamics (3 streams)")
                .font(.subheadline)
                .foregroundColor(.secondary)

            if traces.isEmpty {
                Text("No dynamics traces in payload.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(traces, id: \.id) { trace in
                            TraceColumnView(trace: trace)
                        }
                    }
                }
            }
        }
    }
}

struct TrajectoryTracesView: View {
    let paths: [LearningLogPayload.Path]
    let radius: Float?
    let snapToGrid: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trajectories (physics view)")
                .font(.subheadline)
                .foregroundColor(.secondary)

            if paths.isEmpty {
                Text("No trajectory paths in payload.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                GeometryReader { geo in
                    Canvas { ctx, size in
                        let w = size.width
                        let h = size.height
                        let cx = w / 2
                        let cy = h / 2
                        let baseR = CGFloat(radius ?? maxRadius(from: paths))
                        let rView = max(1, min(w, h) * 0.42)
                        let scale = baseR > 0 ? rView / baseR : 1

                        let gridSpacing = max(10, rView / 6)
                        drawDotGrid(ctx: &ctx, size: size, center: CGPoint(x: cx, y: cy), rView: rView, spacing: gridSpacing)
                        drawBoundaryArc(ctx: &ctx, center: CGPoint(x: cx, y: cy), rView: rView)

                        let palette: [Color] = [.blue, .orange, .green]
                        for (idx, path) in paths.enumerated() {
                            let color = palette[idx % palette.count]
                            drawTrajectory(
                                ctx: &ctx,
                                path: path,
                                center: CGPoint(x: cx, y: cy),
                                scale: scale,
                                color: color,
                                baseR: baseR,
                                rView: rView,
                                snapToGrid: snapToGrid,
                                gridSpacing: gridSpacing
                            )
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        TrajectoryLegendView()
                            .padding(8)
                    }
                }
                .frame(height: 320)
            }
        }
    }

    private func maxRadius(from paths: [LearningLogPayload.Path]) -> Float {
        var maxR: Float = 1
        for p in paths {
            for point in p.points {
                let r = sqrt(point.x * point.x + point.y * point.y)
                if r > maxR { maxR = r }
            }
        }
        return maxR
    }

    private func drawBoundaryArc(ctx: inout GraphicsContext, center: CGPoint, rView: CGFloat) {
        let start = Angle(radians: -Double.pi / 3)
        let end = Angle(radians: Double.pi / 3)
        var path = Path()
        path.addArc(center: center, radius: rView, startAngle: start, endAngle: end, clockwise: false)
        ctx.stroke(path, with: .color(.cyan.opacity(0.8)), lineWidth: 2)
    }

    private func drawDotGrid(ctx: inout GraphicsContext, size: CGSize, center: CGPoint, rView: CGFloat, spacing: CGFloat) {
        let dotR: CGFloat = 1.5
        let minX = center.x - rView
        let maxX = center.x + rView
        let minY = center.y - rView
        let maxY = center.y + rView
        var y = minY
        while y <= maxY {
            var x = minX
            while x <= maxX {
                let dx = x - center.x
                let dy = y - center.y
                if (dx * dx + dy * dy) <= (rView * rView) {
                    let rect = CGRect(x: x - dotR, y: y - dotR, width: dotR * 2, height: dotR * 2)
                    ctx.fill(Path(ellipseIn: rect), with: .color(.secondary.opacity(0.2)))
                }
                x += spacing
            }
            y += spacing
        }
    }

    private func drawTrajectory(
        ctx: inout GraphicsContext,
        path: LearningLogPayload.Path,
        center: CGPoint,
        scale: CGFloat,
        color: Color,
        baseR: CGFloat,
        rView: CGFloat,
        snapToGrid: Bool,
        gridSpacing: CGFloat
    ) {
        let points = path.points
        guard points.count > 1 else { return }
        var prev = points[0]
        for idx in 1..<points.count {
            let cur = points[idx]
            let p0 = CGPoint(x: center.x + CGFloat(prev.x) * scale, y: center.y + CGFloat(prev.y) * scale)
            let p1 = CGPoint(x: center.x + CGFloat(cur.x) * scale, y: center.y + CGFloat(cur.y) * scale)
            let s0 = snapToGrid ? snapPoint(p0, center: center, spacing: gridSpacing) : p0
            let s1 = snapToGrid ? snapPoint(p1, center: center, spacing: gridSpacing) : p1
            let speed = CGFloat(cur.speed)
            let width = min(max(1.0, speed * 2.0), 4.0)

            var segment = Path()
            segment.move(to: s0)
            segment.addLine(to: s1)

            if cur.spiked {
                ctx.stroke(segment, with: .color(.red.opacity(0.9)), lineWidth: width + 1.5)
            } else {
                ctx.stroke(segment, with: .color(color.opacity(0.8)), lineWidth: width)
            }
            prev = cur
        }

        if let last = points.last {
            let lastPtRaw = CGPoint(x: center.x + CGFloat(last.x) * scale, y: center.y + CGFloat(last.y) * scale)
            let lastPt = snapToGrid ? snapPoint(lastPtRaw, center: center, spacing: gridSpacing) : lastPtRaw
            let marker = CGRect(x: lastPt.x - 4, y: lastPt.y - 4, width: 8, height: 8)
            ctx.fill(Path(ellipseIn: marker), with: .color(color))

            let r = sqrt(last.x * last.x + last.y * last.y)
            if r < Float(baseR) {
                let dir = SIMD2<Float>(last.x, last.y)
                let len = sqrt(dir.x * dir.x + dir.y * dir.y)
                if len > 0 {
                    let nx = CGFloat(dir.x / len)
                    let ny = CGFloat(dir.y / len)
                    let boundary = CGPoint(x: center.x + nx * rView, y: center.y + ny * rView)
                    let snapBoundary = snapToGrid ? snapPoint(boundary, center: center, spacing: gridSpacing) : boundary
                    var proj = Path()
                    proj.move(to: lastPt)
                    proj.addLine(to: snapBoundary)
                    ctx.stroke(proj, with: .color(.gray.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
            }

            if points.count >= 2 {
                let pPrev = points[points.count - 2]
                let p0Raw = CGPoint(x: center.x + CGFloat(pPrev.x) * scale, y: center.y + CGFloat(pPrev.y) * scale)
                let p0 = snapToGrid ? snapPoint(p0Raw, center: center, spacing: gridSpacing) : p0Raw
                drawArrow(ctx: &ctx, from: p0, to: lastPt, color: color)
            }
        }
    }

    private func snapPoint(_ point: CGPoint, center: CGPoint, spacing: CGFloat) -> CGPoint {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let sx = round(dx / spacing) * spacing
        let sy = round(dy / spacing) * spacing
        return CGPoint(x: center.x + sx, y: center.y + sy)
    }

    private func drawArrow(ctx: inout GraphicsContext, from: CGPoint, to: CGPoint, color: Color) {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let len = max(1, sqrt(dx * dx + dy * dy))
        let ux = dx / len
        let uy = dy / len
        let tip = CGPoint(x: to.x, y: to.y)
        let left = CGPoint(x: to.x - ux * 10 - uy * 4, y: to.y - uy * 10 + ux * 4)
        let right = CGPoint(x: to.x - ux * 10 + uy * 4, y: to.y - uy * 10 - ux * 4)
        var path = Path()
        path.move(to: tip)
        path.addLine(to: left)
        path.move(to: tip)
        path.addLine(to: right)
        ctx.stroke(path, with: .color(color.opacity(0.8)), lineWidth: 1)
    }
}

private struct TrajectoryLegendView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            legendRow(color: .cyan, label: "Boundary arc", dashed: false, width: 2)
            legendRow(color: .secondary, label: "Grid dots", dashed: false, width: 0)
            legendRow(color: .blue, label: "Trajectory", dashed: false, width: 2)
            legendRow(color: .red, label: "Spike jump", dashed: false, width: 3)
            legendRow(color: .gray, label: "Projection", dashed: true, width: 1)
        }
        .font(.caption2)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.04)))
    }

    private func legendRow(color: Color, label: String, dashed: Bool, width: CGFloat) -> some View {
        HStack(spacing: 6) {
            Rectangle()
                .stroke(style: StrokeStyle(lineWidth: width == 0 ? 1 : width, dash: dashed ? [4, 3] : []))
                .foregroundColor(color)
                .frame(width: 18, height: 6)
            Text(label)
        }
    }
}

private struct TraceColumnView: View {
    let trace: LearningLogPayload.Trace

    var body: some View {
        let steps = trace.steps.suffix(16)
        let rVals = steps.map { Double($0.r) }
        let tVals = steps.map { Double($0.theta) }
        let eVals = steps.map { Double($0.energy) }
        let vVals = steps.map { Double($0.V) }
        let speedVals = steps.map { Double($0.speed) }
        let radialVals = steps.map { Double($0.radialSpeed) }

        return VStack(alignment: .leading, spacing: 6) {
            Text("Stream \(trace.id)")
                .font(.subheadline)
            HStack(spacing: 8) {
                MiniMetricChart(title: "r(t)", values: rVals, color: .blue)
                MiniMetricChart(title: "θ(t)", values: tVals, color: .teal)
            }
            HStack(spacing: 8) {
                MiniMetricChart(title: "E(t)", values: eVals, color: .orange)
                MiniMetricChart(title: "V(t)", values: vVals, color: .purple)
            }
            HStack(spacing: 8) {
                MiniMetricChart(title: "speed", values: speedVals, color: .gray)
                MiniMetricChart(title: "radial", values: radialVals, color: .green)
            }
            TraceStepsTable(steps: Array(steps.suffix(10)))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        .frame(width: 220)
    }
}

private struct MiniMetricChart: View {
    let title: String
    let values: [Double]
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            LineChart(values: values, color: color)
                .frame(height: 36)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct TraceStepsTable: View {
    let steps: [LearningLogPayload.TraceStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Steps")
                .font(.caption2)
                .foregroundColor(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 2) {
                GridRow {
                    Text("t").foregroundColor(.secondary)
                    Text("r").foregroundColor(.secondary)
                    Text("θ").foregroundColor(.secondary)
                    Text("E").foregroundColor(.secondary)
                    Text("V").foregroundColor(.secondary)
                    Text("S").foregroundColor(.secondary)
                    Text("bin").foregroundColor(.secondary)
                }
                ForEach(steps, id: \.t) { step in
                    GridRow {
                        Text("\(step.t)")
                        Text(String(format: "%.2f", step.r))
                        Text(String(format: "%.2f", step.theta))
                        Text(String(format: "%.1f", step.energy))
                        Text(String(format: "%.2f", step.V))
                        Text(step.spiked ? "Y" : "-")
                        Text(step.bin.map(String.init) ?? "-")
                    }
                }
            }
            .font(.caption2.monospacedDigit())
        }
    }
}

public enum LearningLogSource {
    public static func resolveLogFileURL(from snapshot: ConfigSnapshot, fileManager: FileManager = .default) -> URL? {
        guard let destination = snapshot.root.logging.destinations.first(where: { $0.type == .file }),
              let path = destination.path, !path.isEmpty else {
            return nil
        }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        let base = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        return base.appendingPathComponent(path)
    }
}
