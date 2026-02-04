import Foundation
import SwiftUI
import SharedInfrastructure

public struct LearningMetricsView: View {
    @StateObject private var viewModel: LearningMetricsViewModel
    private let title: String

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

            if viewModel.records.isEmpty {
                Text("No learning metrics yet. Run energetic-cli learn to produce trainer.loop logs.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                lossCharts
                rateCharts
                paramsPanel
                histogramPanel
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.06)))
    }

    private var header: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if let lastEpoch = viewModel.records.last?.epoch {
                Text("Epoch \(lastEpoch)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
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

    private var paramsPanel: some View {
        guard let latest = viewModel.records.last else { return AnyView(EmptyView()) }
        return AnyView(
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
            }
        )
    }

    private var histogramPanel: some View {
        guard let latest = viewModel.records.last else { return AnyView(EmptyView()) }
        guard let histogram = latest.histogram else {
            return AnyView(
                Text("Histogram not available in log payload.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            )
        }

        let (yHat, target) = downsampleHistogram(yHat: histogram.yHat, target: histogram.target, maxBins: 128)
        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                Text("Histogram (output vs target)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                HistogramComparisonView(yHat: yHat, target: target)
                    .frame(height: 140)
            }
        )
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
    struct Loss: Decodable { let total: Float; let bins: Float; let spike: Float; let boundary: Float }
    struct Rates: Decodable { let spike: Float; let completion: Float }
    struct Radius: Decodable { let meanMiss: Float }
    struct Params: Decodable { let lif: Float; let radialBias: Float; let spikeKick: Float; let gainMean: Float; let gainVariance: Float }
    struct Bins: Decodable { let nonzero: Int; let mean: Float; let variance: Float; let min: Float; let max: Float }
    struct Histogram: Decodable { let yHat: [Float]; let target: [Float]? }

    let epoch: Int
    let loss: Loss
    let rates: Rates
    let radius: Radius
    let params: Params
    let bins: Bins
    let histogram: Histogram?

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
