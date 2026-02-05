import Foundation

public struct HistogramMetricValues: Sendable {
    public let l1: Float
    public let l2: Float
    public let cosine: Float?

    public init(l1: Float, l2: Float, cosine: Float?) {
        self.l1 = l1
        self.l2 = l2
        self.cosine = cosine
    }
}

/// Histogram distance/similarity metrics for normalized, non-negative histograms.
public enum HistogramMetrics {
    public static func compute(_ a: [Float], _ b: [Float]) -> HistogramMetricValues {
        precondition(a.count == b.count, "histogram size mismatch")
        precondition(!a.isEmpty, "histogram must be non-empty")

        let tolerance: Float = 1e-3
        var sumAbs: Float = 0
        var sumSq: Float = 0
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        var sumA: Float = 0
        var sumB: Float = 0

        for i in 0..<a.count {
            let va = a[i]
            let vb = b[i]
            precondition(va.isFinite && vb.isFinite, "histogram values must be finite")
            precondition(va >= 0 && vb >= 0, "histogram values must be >= 0")
            precondition(va <= 1 + tolerance && vb <= 1 + tolerance, "histogram values must be <= 1 after normalization")

            let diff = va - vb
            sumAbs += abs(diff)
            sumSq += diff * diff
            dot += va * vb
            normA += va * va
            normB += vb * vb
            sumA += va
            sumB += vb
        }

        if sumA > 0 {
            precondition(abs(sumA - 1) <= tolerance, "histogram A must be normalized (sum ≈ 1)")
        }
        if sumB > 0 {
            precondition(abs(sumB - 1) <= tolerance, "histogram B must be normalized (sum ≈ 1)")
        }

        let l2 = sqrt(sumSq)
        let cosine: Float?
        if normA > 0, normB > 0 {
            let denom = sqrt(normA) * sqrt(normB)
            let value = dot / denom
            precondition(value.isFinite, "cosine similarity must be finite")
            precondition(value >= -1 - tolerance && value <= 1 + tolerance, "cosine similarity out of range")
            cosine = value
        } else {
            cosine = nil
        }

        return HistogramMetricValues(l1: sumAbs, l2: l2, cosine: cosine)
    }
}
