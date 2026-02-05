import Foundation

public enum HistogramRetrievalMetric: String, Sendable {
    case l1
    case l2
    case cosine
}

public struct HistogramCorpusEntry: Decodable, Sendable {
    public let text: String
    public let histogram: [Float]

    public init(text: String, histogram: [Float]) {
        self.text = text
        self.histogram = histogram
    }
}

public struct HistogramRetrievalResult: Sendable {
    public let text: String
    public let score: Float
    public let metric: HistogramRetrievalMetric

    public init(text: String, score: Float, metric: HistogramRetrievalMetric) {
        self.text = text
        self.score = score
        self.metric = metric
    }
}

public enum HistogramRetrievalError: LocalizedError {
    case emptyCorpus
    case invalidEntryCount(expected: Int, actual: Int)
    case invalidEntryValue
    case failedToDecodeLine(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyCorpus:
            return "Histogram corpus is empty"
        case let .invalidEntryCount(expected, actual):
            return "Histogram entry size mismatch: expected \(expected), got \(actual)"
        case .invalidEntryValue:
            return "Histogram entry contains invalid values"
        case let .failedToDecodeLine(line):
            return "Failed to decode corpus line \(line)"
        }
    }
}

public final class HistogramRetriever {
    private let entries: [HistogramCorpusEntry]
    private let normalized: [[Float]]
    private let metric: HistogramRetrievalMetric
    private let topK: Int
    private let bins: Int

    public init(entries: [HistogramCorpusEntry], metric: HistogramRetrievalMetric, topK: Int, bins: Int) throws {
        precondition(bins > 0, "bins must be > 0")
        precondition(topK > 0, "topK must be > 0")
        guard !entries.isEmpty else { throw HistogramRetrievalError.emptyCorpus }
        self.metric = metric
        self.topK = topK
        self.bins = bins

        var normalizedEntries: [[Float]] = []
        normalizedEntries.reserveCapacity(entries.count)
        for entry in entries {
            guard entry.histogram.count == bins else {
                throw HistogramRetrievalError.invalidEntryCount(expected: bins, actual: entry.histogram.count)
            }
            for value in entry.histogram {
                guard value.isFinite, value >= 0 else {
                    throw HistogramRetrievalError.invalidEntryValue
                }
            }
            normalizedEntries.append(Self.normalize(entry.histogram))
        }
        self.entries = entries
        self.normalized = normalizedEntries
    }

    public static func loadCorpus(from path: String, bins: Int) throws -> [HistogramCorpusEntry] {
        let url = URL(fileURLWithPath: path)
        let content = try String(contentsOf: url, encoding: .utf8)
        var entries: [HistogramCorpusEntry] = []
        var lineIndex = 0
        for line in content.split(whereSeparator: \.isNewline) {
            lineIndex += 1
            let data = Data(line.utf8)
            guard let entry = try? JSONDecoder().decode(HistogramCorpusEntry.self, from: data) else {
                throw HistogramRetrievalError.failedToDecodeLine(lineIndex)
            }
            guard entry.histogram.count == bins else {
                throw HistogramRetrievalError.invalidEntryCount(expected: bins, actual: entry.histogram.count)
            }
            entries.append(entry)
        }
        return entries
    }

    public func retrieve(normalized histogram: [Float]) -> [HistogramRetrievalResult] {
        precondition(histogram.count == bins, "histogram size mismatch")
        for value in histogram {
            precondition(value.isFinite, "histogram values must be finite")
            precondition(value >= 0, "histogram values must be >= 0")
        }

        var scored: [(index: Int, score: Float)] = []
        scored.reserveCapacity(entries.count)
        for (idx, candidate) in normalized.enumerated() {
            let metrics = HistogramMetrics.compute(histogram, candidate)
            let score: Float
            switch metric {
            case .l1:
                score = metrics.l1
            case .l2:
                score = metrics.l2
            case .cosine:
                score = metrics.cosine ?? -1
            }
            scored.append((idx, score))
        }

        let sorted: [(index: Int, score: Float)]
        switch metric {
        case .l1, .l2:
            sorted = scored.sorted { $0.score < $1.score }
        case .cosine:
            sorted = scored.sorted { $0.score > $1.score }
        }

        let count = min(topK, sorted.count)
        var results: [HistogramRetrievalResult] = []
        results.reserveCapacity(count)
        for i in 0..<count {
            let item = sorted[i]
            let entry = entries[item.index]
            results.append(.init(text: entry.text, score: item.score, metric: metric))
        }
        return results
    }

    private static func normalize(_ values: [Float]) -> [Float] {
        let sum = values.reduce(0, +)
        guard sum > 0 else { return values }
        return values.map { $0 / sum }
    }
}
