import SwiftUI

/// Detailed view for normalized values stage
public struct NormalizedStageView: View {
    let stage: PipelineStage
    let config: ConfigRoot.Capsule

    public init(stage: PipelineStage, config: ConfigRoot.Capsule) {
        self.stage = stage
        self.config = config
    }

    public var body: some View {
        if case let .normalized(values) = stage.data {
            let min = values.min() ?? 0
            let max = values.max() ?? 0
            let mean = values.reduce(0, +) / Double(values.count)

            VStack(alignment: .leading, spacing: 16) {
                Text("Normalized Values [0..1]")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                // Statistics
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Count", value: "\(values.count)")
                        LabeledContent("Method", value: config.normalization)
                        LabeledContent("Min", value: String(format: "%.6f", min))
                        LabeledContent("Max", value: String(format: "%.6f", max))
                        LabeledContent("Mean", value: String(format: "%.6f", mean))
                    }
                } label: {
                    Label("Statistics", systemImage: "slider.horizontal.3")
                        .font(.caption)
                }

                // Formula
                if config.normalization == "e_over_bplus1" {
                    GroupBox {
                        Text("Formula: x[i] = E[i] / (B + 1)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("where B = \(config.base), so x[i] = E[i] / \(config.base + 1)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } label: {
                        Label("Normalization", systemImage: "function")
                            .font(.caption)
                    }
                }

                // Values preview
                GroupBox {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 8) {
                            let displayValues = Array(values.prefix(30)) + Array(values.suffix(10))
                            ForEach(Array(displayValues.enumerated()), id: \.offset) { idx, val in
                                VStack(spacing: 2) {
                                    Text("[\(idx)]")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundColor(.secondary)
                                    Text(String(format: "%.4f", val))
                                        .font(.system(.caption, design: .monospaced))
                                }
                                .padding(4)
                                .background(VisualizationColorScheme.codeBackground)
                                .cornerRadius(4)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                } label: {
                    Label("Values (first 30 + last 10)", systemImage: "list.number")
                        .font(.caption)
                }

                Text("Ready for SNN/Router input")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
    }
}
