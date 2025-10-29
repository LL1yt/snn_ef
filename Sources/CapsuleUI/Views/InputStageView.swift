import SwiftUI

/// Detailed view for the input text stage
public struct InputStageView: View {
    let stage: PipelineStage

    public init(stage: PipelineStage) {
        self.stage = stage
    }

    public var body: some View {
        if case let .text(input) = stage.data {
            VStack(alignment: .leading, spacing: 12) {
                Text("Original Input Text")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                // Input text display
                ScrollView {
                    Text(input)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(VisualizationColorScheme.codeBackground)
                        .cornerRadius(6)
                }
                .frame(maxHeight: 200)

                // Metrics
                GroupBox("Metrics") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Length (characters)", value: "\(input.count)")
                        LabeledContent("Length (bytes)", value: "\(stage.metrics.inputSize)")
                        LabeledContent("Encoding", value: "UTF-8")
                    }
                }
            }
        }
    }
}
