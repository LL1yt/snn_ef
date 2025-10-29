import SwiftUI
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

                Text("Converted from \(stage.metrics.inputSize) bytes using positional notation")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
    }
}
