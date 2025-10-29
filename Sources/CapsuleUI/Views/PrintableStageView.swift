import SwiftUI
import SharedInfrastructure

/// Detailed view for printable string representation
public struct PrintableStageView: View {
    let stage: PipelineStage
    let config: ConfigRoot.Capsule

    public init(stage: PipelineStage, config: ConfigRoot.Capsule) {
        self.stage = stage
        self.config = config
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

                Text("Each character maps to a digit in base-\(config.base)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
    }
}
