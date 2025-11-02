import SwiftUI
import SharedInfrastructure

/// Detailed view for printable string representation
public struct PrintableStageView: View {
    let stage: PipelineStage
    let config: ConfigRoot.Capsule
    let digits: [Int]?

    public init(stage: PipelineStage, config: ConfigRoot.Capsule, digits: [Int]?) {
        self.stage = stage
        self.config = config
        self.digits = digits
    }

    public var body: some View {
        if case let .printable(printableString) = stage.data {
            VStack(alignment: .leading, spacing: 16) {
                Text("Printable String Representation")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                // Stats
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("String Length", value: "\(printableString.count)")
                        LabeledContent("Alphabet Size", value: "\(config.alphabet.count)")
                        LabeledContent("Encoding", value: "Base-\(config.base) custom alphabet")
                    }
                } label: {
                    Label("Info", systemImage: "text.quote")
                        .font(.caption)
                }

                // Printable string display
                GroupBox {
                    ScrollView {
                        Text(printableString)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(VisualizationColorScheme.codeBackground)
                            .cornerRadius(6)
                    }
                    .frame(maxHeight: 200)
                } label: {
                    Label("Printable String", systemImage: "doc.text")
                        .font(.caption)
                }

                // Preview alphabet
                GroupBox {
                    let alphabetPreview = String(config.alphabet.prefix(20))
                    Text("Alphabet preview: \(alphabetPreview)...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } label: {
                    Label("Alphabet", systemImage: "textformat.abc")
                        .font(.caption)
                }

                if let digits, !digits.isEmpty {
                    GroupBox("Sample Characters") {
                        let pairs = printableSamples(string: printableString, digits: digits, limit: 8)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(pairs) { sample in
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
                            if printableString.count > pairs.count {
                                Text("…")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                Text("Each character maps to a digit in base-\(config.base)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
    }
}

private func printableSamples(string: String, digits: [Int], limit: Int) -> [PrintableSample] {
    guard limit > 0 else { return [] }
    var result: [PrintableSample] = []
    result.reserveCapacity(limit)

    let characters = Array(string)
    let count = min(limit, min(characters.count, digits.count))
    for index in 0..<count {
        result.append(PrintableSample(index: index, digit: digits[index], character: characters[index]))
    }
    return result
}

private struct PrintableSample: Identifiable {
    let index: Int
    let digit: Int
    let character: Character

    var id: Int { index }
}
