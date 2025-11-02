import SwiftUI

/// Detailed view for recovered text stage with CRC verification
public struct RecoveredStageView: View {
    let stage: PipelineStage
    let originalText: String

    public init(stage: PipelineStage, originalText: String) {
        self.stage = stage
        self.originalText = originalText
    }

    public var body: some View {
        if case let .text(recovered) = stage.data {
            let crcMatch = recovered == originalText
            let isSuccess = stage.isSuccessful && crcMatch

            VStack(alignment: .leading, spacing: 16) {
                // Status header
                HStack {
                    Text("Recovered Text")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    Spacer()

                    if isSuccess {
                        Label("Success", systemImage: "checkmark.circle.fill")
                            .foregroundColor(VisualizationColorScheme.successColor)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    } else {
                        Label("Failed", systemImage: "xmark.circle.fill")
                            .foregroundColor(VisualizationColorScheme.errorColor)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                }

                // Verification status
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("CRC Verification:")
                                .fontWeight(.medium)
                            Spacer()
                            if crcMatch {
                                Text("PASS")
                                    .foregroundColor(VisualizationColorScheme.successColor)
                                    .fontWeight(.bold)
                            } else {
                                Text("FAIL")
                                    .foregroundColor(VisualizationColorScheme.errorColor)
                                    .fontWeight(.bold)
                            }
                        }

                        LabeledContent("Original Length", value: "\(originalText.count) chars")
                        LabeledContent("Recovered Length", value: "\(recovered.count) chars")
                        LabeledContent("Match", value: crcMatch ? "Exact" : "Mismatch")
                    }
                } label: {
                    Label("Verification", systemImage: crcMatch ? "checkmark.shield" : "xmark.shield")
                        .font(.caption)
                }

                // Recovered text
                GroupBox {
                    ScrollView {
                        Text(recovered)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(
                                isSuccess
                                    ? VisualizationColorScheme.successBackground
                                    : VisualizationColorScheme.errorBackground
                            )
                            .cornerRadius(6)
                    }
                    .frame(maxHeight: 200)
                } label: {
                    Label("Recovered Text", systemImage: "doc.text")
                        .font(.caption)
                }

                // Comparison if mismatch
                if !crcMatch {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Original:")
                                .font(.caption)
                                .fontWeight(.semibold)
                            Text(DataFormatter.truncate(originalText, maxLength: 100))
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Divider()

                            Text("Recovered:")
                                .font(.caption)
                                .fontWeight(.semibold)
                            Text(DataFormatter.truncate(recovered, maxLength: 100))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } label: {
                        Label("Comparison", systemImage: "arrow.left.arrow.right")
                            .font(.caption)
                    }
                }

                // Error info
                if let error = stage.error {
                    GroupBox {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(VisualizationColorScheme.errorColor)
                    } label: {
                        Label("Error", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundColor(VisualizationColorScheme.errorColor)
                    }
                }

                Text("Roundtrip complete: Input → Capsule → Energies → Capsule → Output")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
    }
}
