import SwiftUI
import CapsuleCore
import SharedInfrastructure

/// Detailed view for base-B digits conversion
public struct DigitsStageView: View {
    let stage: PipelineStage
    let config: ConfigRoot.Capsule

    public init(stage: PipelineStage, config: ConfigRoot.Capsule) {
        self.stage = stage
        self.config = config
    }

    public var body: some View {
        if case let .digits(digits) = stage.data {
            VStack(alignment: .leading, spacing: 16) {
                Text("Base-\(config.base) Digits")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                // Stats
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Total Digits", value: "\(digits.count)")
                        LabeledContent("Base", value: "\(config.base)")
                        LabeledContent("Range", value: "[0..\(config.base - 1)]")

                        let required = ByteDigitsConverter.requiredDigitsCount(byteCount: stage.metrics.inputSize, baseB: config.base)
                        Text("Required digits for \(stage.metrics.inputSize) bytes: \(required)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } label: {
                    Label("Statistics", systemImage: "number.circle")
                        .font(.caption)
                }

                // Digits display
                GroupBox {
                    CompactDigitsView(digits: digits, base: config.base, first: 50, last: 10)
                } label: {
                    Label("Digits", systemImage: "grid.circle")
                        .font(.caption)
                }

                if let samples = digitSamples(digits: digits, alphabet: config.alphabet, limit: 8), !samples.isEmpty {
                    GroupBox("Sample Digit Mapping") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(samples) { sample in
                                HStack(spacing: 8) {
                                    Text(String(format: "[%03d]", sample.index))
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundColor(.secondary)
                                    Text("digit \(sample.digit)")
                                        .font(.system(.caption, design: .monospaced))
                                    Text("→ '\(sample.character)'")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }

                let inputBytes = stage.metrics.inputSize
                let conversionNote: String
                if digits.count == inputBytes {
                    conversionNote = "Converted from \(inputBytes) bytes; base-\(config.base) preserves one digit per byte."
                } else if digits.count > inputBytes {
                    conversionNote = "Converted from \(inputBytes) bytes to \(digits.count) base-\(config.base) digits; additional digits appear because each symbol carries less than one byte of entropy."
                } else {
                    conversionNote = "Converted from \(inputBytes) bytes to \(digits.count) base-\(config.base) digits; higher base compresses multiple bytes into single digits."
                }

                Text(conversionNote)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
    }
}

private func digitSamples(digits: [Int], alphabet: String, limit: Int) -> [DigitSample]? {
    guard limit > 0 else { return nil }
    let chars = Array(alphabet)
    guard !chars.isEmpty else { return nil }
    let count = min(limit, digits.count)
    var samples: [DigitSample] = []
    samples.reserveCapacity(count)
    for index in 0..<count {
        let digit = digits[index]
        guard digit >= 0 && digit < chars.count else { continue }
        samples.append(DigitSample(index: index, digit: digit, character: chars[digit]))
    }
    return samples
}

private struct DigitSample: Identifiable {
    let index: Int
    let digit: Int
    let character: Character

    var id: Int { index }
}
