import Foundation
import SwiftUI
import SharedInfrastructure

public struct LearningMetricsView: View {
    @StateObject private var viewModel: LearningMetricsViewModel
    private let title: String
    @State private var selectedIndex: Int?
    @State private var followLatest: Bool = true
    @State private var snapToGrid: Bool = true
    @State private var speedBoost: Double = 6.0
    @State private var angleBoost: Double = 2.6
    @State private var maxLabelCount: Int = 4
    @State private var labelMode: LabelMode = .key

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
            HStack(alignment: .top, spacing: 16) {
                leftColumn
                centerColumn
                rightColumn
            }
        }
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            qualityPanel
            paramsPanel
        }
        .frame(maxWidth: 260)
    }

    @ViewBuilder
    private var centerColumn: some View {
        if let record = currentRecord {
            StreamTracksView(
                traces: record.traces ?? [],
                paths: record.paths ?? [],
                radius: record.radius.R,
                snapToGrid: snapToGrid,
                speedBoost: speedBoost,
                angleBoost: angleBoost,
                maxLabelCount: maxLabelCount,
                labelMode: labelMode
            )
            .frame(minWidth: 520, maxWidth: CGFloat.infinity)
        } else {
            EmptyView()
        }
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            histogramPanel
            lossCharts
            rateCharts
        }
        .frame(maxWidth: 360)
    }

    private var lossCharts: some View {
        let total = viewModel.records.map { Double($0.loss.total) }
        let bins = viewModel.records.map { Double($0.loss.bins) }
        let negative = viewModel.records.map { Double($0.loss.negative ?? 0) }
        let spike = viewModel.records.map { Double($0.loss.spike) }
        let boundary = viewModel.records.map { Double($0.loss.boundary) }

        return VStack(alignment: .leading, spacing: 8) {
            Text("Loss")
                .font(.subheadline)
                .foregroundColor(.secondary)
            MetricLineChart(title: "Total", values: total, color: .blue, trendHint: trendHint(for: "Total", values: total))
            MetricLineChart(title: "Bins", values: bins, color: .teal, trendHint: trendHint(for: "Bins", values: bins))
            MetricLineChart(title: "Negative", values: negative, color: .pink, trendHint: trendHint(for: "Negative", values: negative))
            MetricLineChart(title: "Spike", values: spike, color: .orange, trendHint: trendHint(for: "Spike", values: spike))
            MetricLineChart(title: "Boundary", values: boundary, color: .purple, trendHint: trendHint(for: "Boundary", values: boundary))
            Text("↓ better: Total/Bins/Negative/Spike/Boundary")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var rateCharts: some View {
        let spike = viewModel.records.map { Double($0.rates.spike) }
        let completion = viewModel.records.map { Double($0.rates.completion) }
        let miss = viewModel.records.map { Double($0.radius.meanMiss) }
        let accuracy = movingAverage(values: viewModel.records.compactMap { $0.optionAccuracy }.map { Double($0) }, window: 8)

        return VStack(alignment: .leading, spacing: 8) {
            Text("Rates")
                .font(.subheadline)
                .foregroundColor(.secondary)
            MetricLineChart(title: "Spike rate", values: spike, color: .red, trendHint: trendHint(for: "SpikeRate", values: spike))
            MetricLineChart(title: "Completion", values: completion, color: .green, trendHint: trendHint(for: "Completion", values: completion))
            MetricLineChart(title: "Radial miss", values: miss, color: .gray, trendHint: trendHint(for: "RadialMiss", values: miss))
            if !accuracy.isEmpty {
                MetricLineChart(title: "Option acc (avg)", values: accuracy, color: .indigo, trendHint: trendHint(for: "Acc", values: accuracy))
            }
            Text("↑ better: Completion, Acc | ↓ better: Radial miss | ≈ target: Spike rate")
                .font(.caption2)
                .foregroundColor(.secondary)
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
                optionAccuracyRow(values: viewModel.records.compactMap { $0.optionAccuracy })
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

            Menu(labelMode.label) {
                ForEach(LabelMode.allCases, id: \.self) { mode in
                    Button(mode.label) { labelMode = mode }
                }
            }
            .font(.caption)

            HStack(spacing: 6) {
                Text("Len")
                Slider(value: $speedBoost, in: 1...12, step: 0.5)
                    .frame(width: 90)
                Text(String(format: "%.1f", speedBoost))
                    .font(.caption2.monospacedDigit())
            }

            HStack(spacing: 6) {
                Text("Angle")
                Slider(value: $angleBoost, in: 1...4, step: 0.1)
                    .frame(width: 90)
                Text(String(format: "%.1f", angleBoost))
                    .font(.caption2.monospacedDigit())
            }

            HStack(spacing: 6) {
                Text("Labels")
                Stepper(value: $maxLabelCount, in: 0...8) { EmptyView() }
                    .labelsHidden()
                Text("\(maxLabelCount)")
                    .font(.caption2.monospacedDigit())
            }

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

    private var qualityPanel: some View {
        guard let record = currentRecord else { return AnyView(EmptyView()) }
        let summary = QualitySummary.evaluate(records: viewModel.records, current: record)
        return AnyView(
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(summary.color)
                        .frame(width: 10, height: 10)
                    Text("Quality: \(summary.label)")
                        .font(.subheadline)
                }
                ForEach(summary.notes, id: \.self) { note in
                    Text(note)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
        )
    }

    private func optionAccuracyRow(values: [Float]) -> some View {
        let avg = movingAverage(values: values.map { Double($0) }, window: 8).last ?? 0
        let pct = max(0, min(1, avg))
        return HStack(spacing: 8) {
            Text("Option acc (avg)")
                .font(.caption)
                .foregroundColor(.secondary)
            ProgressView(value: Double(pct))
                .progressViewStyle(.linear)
                .frame(width: 120)
            Text(String(format: "%.2f", pct))
                .font(.caption.monospacedDigit())
        }
    }

    private func trendHint(for kind: String, values: [Double]) -> String {
        guard values.count >= 3 else { return "→" }
        let recent = Array(values.suffix(6))
        let trend = recent.last! - recent.first!
        if abs(trend) < 1e-6 { return "→ stable" }
        switch kind {
        case "Completion", "Acc":
            return trend > 0 ? "↑ better" : "↓ worse"
        case "RadialMiss", "Total", "Bins", "Negative", "Spike", "Boundary":
            return trend < 0 ? "↓ better" : "↑ worse"
        case "SpikeRate":
            return "≈ target"
        default:
            return trend > 0 ? "↑" : "↓"
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

    private func movingAverage(values: [Double], window: Int) -> [Double] {
        guard window > 1, !values.isEmpty else { return values }
        var out: [Double] = []
        out.reserveCapacity(values.count)
        var sum: Double = 0
        var buffer: [Double] = []
        buffer.reserveCapacity(window)
        for v in values {
            buffer.append(v)
            sum += v
            if buffer.count > window {
                sum -= buffer.removeFirst()
            }
            out.append(sum / Double(buffer.count))
        }
        return out
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
    let trendHint: String?

    var body: some View {
        let stats = summarize(values: values)
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            LineChart(values: values, color: color)
                .frame(height: 56)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            HStack(spacing: 8) {
                Text("min \(formatStat(stats.min))")
                Text("avg \(formatStat(stats.mean))")
                Text("max \(formatStat(stats.max))")
                Spacer()
                if let trendHint {
                    Text(trendHint)
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundColor(.secondary)
        }
    }

    private func summarize(values: [Double]) -> (min: Double, mean: Double, max: Double) {
        guard !values.isEmpty else { return (0, 0, 0) }
        let minV = values.min() ?? 0
        let maxV = values.max() ?? 0
        let meanV = values.reduce(0, +) / Double(values.count)
        return (minV, meanV, maxV)
    }

    private func formatStat(_ value: Double) -> String {
        let absV = abs(value)
        if absV >= 10_000 {
            return String(format: "%.2e", value)
        } else if absV >= 100 {
            return String(format: "%.1f", value)
        } else {
            return String(format: "%.3f", value)
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
                    let x = CGFloat(i) * barW
                    if let target, i < target.count {
                        let tVal = CGFloat(target[i]) / CGFloat(maxY)
                        let tHeight = h * tVal
                        let tRect = CGRect(x: x, y: h - tHeight, width: max(barW - 1, 1), height: tHeight)
                        ctx.fill(Path(tRect), with: .color(.blue.opacity(0.55)))
                    }

                    let yVal = CGFloat(yHat[i]) / CGFloat(maxY)
                    let yHeight = h * yVal
                    let rect = CGRect(x: x, y: h - yHeight, width: max(barW - 1, 1), height: yHeight)
                    ctx.fill(Path(rect), with: .color(.green.opacity(0.35)))
                    ctx.stroke(Path(rect), with: .color(.green.opacity(0.7)), lineWidth: 0.6)
                }
            }
        }
    }
}

struct StreamTracksView: View {
    let traces: [LearningLogPayload.Trace]
    let paths: [LearningLogPayload.Path]
    let radius: Float?
    let snapToGrid: Bool
    let speedBoost: Double
    let angleBoost: Double
    let maxLabelCount: Int
    let labelMode: LabelMode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stream dynamics (tracks)")
                .font(.subheadline)
                .foregroundColor(.secondary)

            if traces.isEmpty && paths.isEmpty {
                Text("No stream traces in payload.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    let streamCount = min(3, max(traces.count, paths.count))
                    ForEach(0..<streamCount, id: \.self) { idx in
                        StreamTrackRow(
                            title: "Stream \(idx)",
                            steps: trackSteps(for: idx),
                            color: streamColor(for: idx),
                            radius: radius,
                            snapToGrid: snapToGrid,
                            speedBoost: CGFloat(speedBoost),
                            angleBoost: CGFloat(angleBoost),
                            maxLabelCount: maxLabelCount,
                            labelMode: labelMode
                        )
                    }
                }
                .overlay(alignment: .topLeading) {
                    TrackLegendView()
                        .padding(6)
                }
            }
        }
    }

    private func trackSteps(for index: Int) -> [TrackStep] {
        if let trace = traces.first(where: { $0.id == index }) ?? traces.dropFirst(index).first {
            let steps = trace.steps.suffix(24)
            return steps.map { step in
                let theta = Double(step.theta)
                let x = step.r * Float(cos(theta))
                let y = step.r * Float(sin(theta))
                return TrackStep(
                    t: step.t,
                    x: x,
                    y: y,
                    r: step.r,
                    theta: step.theta,
                    speed: step.speed,
                    energy: step.energy,
                    bin: step.bin,
                    spiked: step.spiked
                )
            }
        }
        if let path = paths.first(where: { $0.id == index }) ?? paths.dropFirst(index).first {
            let points = path.points.suffix(24)
            return points.map { point in
                let r = sqrt(point.x * point.x + point.y * point.y)
                let theta = Float(atan2(Double(point.y), Double(point.x)))
                return TrackStep(
                    t: point.t,
                    x: point.x,
                    y: point.y,
                    r: r,
                    theta: theta,
                    speed: point.speed,
                    energy: nil,
                    bin: point.bin,
                    spiked: point.spiked
                )
            }
        }
        return []
    }

    private func streamColor(for index: Int) -> Color {
        switch index % 3 {
        case 0: return .blue
        case 1: return .orange
        default: return .green
        }
    }
}

private struct StreamTrackRow: View {
    let title: String
    let steps: [TrackStep]
    let color: Color
    let radius: Float?
    let snapToGrid: Bool
    let speedBoost: CGFloat
    let angleBoost: CGFloat
    let maxLabelCount: Int
    let labelMode: LabelMode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let last = steps.last, let radius {
                    let reached = last.r >= radius * 0.98
                    Text(reached ? "Reached boundary" : "Before boundary")
                        .font(.caption2)
                        .foregroundColor(reached ? .green : .secondary)
                }
            }
            GeometryReader { geo in
                Canvas { ctx, size in
                    guard steps.count > 1 else { return }
                    let padding: CGFloat = 10
                    let centerY = size.height / 2
                    let arcRadius = min(size.height * 0.42, 42)
                    let arcCenter = CGPoint(x: size.width - padding - arcRadius, y: centerY)
                    let availableWidth = max(20, arcCenter.x - padding)

                    let gridSpacing = max(10, size.height / 4.5)
                    drawDotGrid(ctx: &ctx, size: size, spacing: gridSpacing)
                    drawBoundaryArc(ctx: &ctx, center: arcCenter, radius: arcRadius)

                    let weights = segmentWeights()
                    let totalWeight = max(weights.reduce(0, +), 1)
                    let scale = availableWidth / totalWeight
                    let angleScale: CGFloat = angleBoost

                    var current = CGPoint(x: padding, y: centerY)
                    let keyIndices = keyStepIndices()

                    for idx in 1..<steps.count {
                        let prev = steps[idx - 1]
                        let cur = steps[idx]
                        let dxRaw = CGFloat(cur.x - prev.x)
                        let dyRaw = CGFloat(cur.y - prev.y)
                        let angle = atan2(dyRaw, dxRaw)
                        let length = max(2, CGFloat(weights[idx - 1]) * scale)
                        let dy = sin(angle) * angleScale * length
                        var next = CGPoint(x: current.x + length, y: current.y + dy)
                        next.y = min(max(padding, next.y), size.height - padding)

                        let snappedStart = snapToGrid ? snapPoint(current, spacing: gridSpacing) : current
                        let snappedEnd = snapToGrid ? snapPoint(next, spacing: gridSpacing) : next

                        var segment = Path()
                        segment.move(to: snappedStart)
                        segment.addLine(to: snappedEnd)
                        let width = min(max(1.2, length * 0.03), 4.0)
                        if cur.spiked {
                            ctx.stroke(segment, with: .color(.red.opacity(0.9)), lineWidth: width + 1.2)
                        } else {
                            ctx.stroke(segment, with: .color(color.opacity(0.8)), lineWidth: width)
                        }

                        if let radius, cur.r >= radius * 0.9 {
                            ctx.stroke(segment, with: .color(.green.opacity(0.45)), lineWidth: width + 0.6)
                        }

                        if keyIndices.contains(idx) {
                            drawStepLabel(ctx: &ctx, step: cur, at: snappedEnd)
                        }

                        current = next
                    }

                    if let last = steps.last {
                        let lastPoint = snapToGrid ? snapPoint(current, spacing: gridSpacing) : current
                        let marker = CGRect(x: lastPoint.x - 3, y: lastPoint.y - 3, width: 6, height: 6)
                        ctx.fill(Path(ellipseIn: marker), with: .color(color))

                        let theta = CGFloat(last.theta)
                        let proj = CGPoint(
                            x: arcCenter.x + cos(theta) * arcRadius,
                            y: arcCenter.y + sin(theta) * arcRadius
                        )
                        let reached = radius.map { last.r >= $0 * 0.98 } ?? false
                        let projColor: Color = reached ? .green : .cyan
                        var projection = Path()
                        projection.move(to: lastPoint)
                        projection.addLine(to: proj)
                        ctx.stroke(projection, with: .color(projColor.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                        let projMark = CGRect(x: proj.x - 2.5, y: proj.y - 2.5, width: 5, height: 5)
                        ctx.fill(Path(ellipseIn: projMark), with: .color(projColor.opacity(0.9)))
                    }
                }
            }
            .frame(height: 110)
        }
    }

    private func segmentWeights() -> [CGFloat] {
        var weights: [CGFloat] = []
        for idx in 1..<steps.count {
            let w = CGFloat(max(0.02, steps[idx].speed)) * speedBoost
            weights.append(w)
        }
        return weights
    }

    private func keyStepIndices() -> Set<Int> {
        guard steps.count > 2 else { return [0, steps.count - 1] }
        switch labelMode {
        case .off:
            return []
        case .dense:
            let count = min(maxLabelCount, steps.count)
            return Set((0..<count).map { Int((Double($0) / Double(max(count - 1, 1))) * Double(steps.count - 1)) })
        case .key:
            var indices: Set<Int> = [0, steps.count - 1]
            for (idx, step) in steps.enumerated() where step.spiked {
                indices.insert(idx)
            }
            if steps.count >= 4 {
                indices.insert(steps.count / 2)
            }
            if steps.count >= 6 {
                indices.insert(steps.count / 3)
                indices.insert(2 * steps.count / 3)
            }
            if indices.count > maxLabelCount {
                let sorted = indices.sorted()
                return Set(sorted.prefix(maxLabelCount))
            }
            return indices
        }
    }

    private func drawBoundaryArc(ctx: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        let start = Angle(radians: -Double.pi / 2.2)
        let end = Angle(radians: Double.pi / 2.2)
        var arc = Path()
        arc.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        ctx.stroke(arc, with: .color(.cyan.opacity(0.85)), lineWidth: 2)
    }

    private func drawDotGrid(ctx: inout GraphicsContext, size: CGSize, spacing: CGFloat) {
        let dotR: CGFloat = 1.2
        var y: CGFloat = spacing / 2
        while y < size.height {
            var x: CGFloat = spacing / 2
            while x < size.width {
                let rect = CGRect(x: x - dotR, y: y - dotR, width: dotR * 2, height: dotR * 2)
                ctx.fill(Path(ellipseIn: rect), with: .color(.secondary.opacity(0.18)))
                x += spacing
            }
            y += spacing
        }
    }

    private func drawStepLabel(ctx: inout GraphicsContext, step: TrackStep, at point: CGPoint) {
        var parts: [String] = []
        parts.append(String(format: "r%.2f", step.r))
        parts.append(String(format: "v%.2f", step.speed))
        if let energy = step.energy {
            parts.append(String(format: "E%.1f", energy))
        }
        if let bin = step.bin {
            parts.append("b\(bin)")
        }
        let text = parts.joined(separator: " ")
        let label = Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(.white)
        let fontSize: CGFloat = 9
        let charWidth: CGFloat = fontSize * 0.6
        let boxWidth = CGFloat(text.count) * charWidth + 6
        let boxHeight = fontSize + 4
        let box = CGRect(x: point.x + 6, y: point.y - 12, width: boxWidth, height: boxHeight)
        ctx.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(.black.opacity(0.5)))
        ctx.draw(label, at: CGPoint(x: box.midX, y: box.midY))
    }

    private func snapPoint(_ point: CGPoint, spacing: CGFloat) -> CGPoint {
        let sx = round(point.x / spacing) * spacing
        let sy = round(point.y / spacing) * spacing
        return CGPoint(x: sx, y: sy)
    }
}

private struct TrackStep {
    let t: Int
    let x: Float
    let y: Float
    let r: Float
    let theta: Float
    let speed: Float
    let energy: Float?
    let bin: Int?
    let spiked: Bool
}

private struct TrackLegendView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            legendRow(color: .cyan, label: "Boundary arc", dashed: false, width: 2)
            legendRow(color: .secondary, label: "Grid dots", dashed: false, width: 0)
            legendRow(color: .blue, label: "Segment", dashed: false, width: 2)
            legendRow(color: .red, label: "Spike", dashed: false, width: 3)
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

enum LabelMode: CaseIterable {
    case off
    case key
    case dense

    var label: String {
        switch self {
        case .off: return "Labels: Off"
        case .key: return "Labels: Key"
        case .dense: return "Labels: Dense"
        }
    }
}

private enum QualitySummary {
    static func evaluate(records: [LearningLogPayload], current: LearningLogPayload) -> (label: String, color: Color, notes: [String]) {
        let lossTrend = trend(records.map { Double($0.loss.total) })
        let missTrend = trend(records.map { Double($0.radius.meanMiss) })
        let accTrend = trend(records.compactMap { $0.optionAccuracy }.map { Double($0) })

        var score = 0
        var notes: [String] = []

        if lossTrend < 0 { score += 1; notes.append("Loss decreasing (good)") }
        else { notes.append("Loss not decreasing") }

        if missTrend < 0 { score += 1; notes.append("Radial miss decreasing (good)") }
        else { notes.append("Radial miss not improving") }

        if !records.compactMap({ $0.optionAccuracy }).isEmpty {
            if accTrend > 0 { score += 1; notes.append("Accuracy increasing (good)") }
            else { notes.append("Accuracy not improving") }
        }

        let label: String
        let color: Color
        if score >= 2 { label = "OK"; color = .green }
        else if score == 1 { label = "Warning"; color = .yellow }
        else { label = "Bad"; color = .red }

        return (label, color, notes)
    }

    private static func trend(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        let recent = Array(values.suffix(6))
        return recent.last! - recent.first!
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
