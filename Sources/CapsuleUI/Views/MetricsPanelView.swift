import SwiftUI

/// Panel displaying aggregate pipeline metrics
public struct MetricsPanelView: View {
    let snapshot: PipelineSnapshot

    public init(snapshot: PipelineSnapshot) {
        self.snapshot = snapshot
    }

    public var body: some View {
        let metrics = snapshot.aggregateMetrics

        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                // Overall status
                HStack {
                    if snapshot.success {
                        Label("Success", systemImage: "checkmark.circle.fill")
                            .foregroundColor(VisualizationColorScheme.successColor)
                            .fontWeight(.semibold)
                    } else {
                        Label("Failed", systemImage: "xmark.circle.fill")
                            .foregroundColor(VisualizationColorScheme.errorColor)
                            .fontWeight(.semibold)
                    }
                    Spacer()
                }

                Divider()

                // Aggregate metrics
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Total Duration", value: DataFormatter.formatDuration(metrics.totalDuration))
                    LabeledContent("Stages", value: "\(metrics.totalStages)")
                    LabeledContent("Successful", value: "\(metrics.successfulStages)")
                    if metrics.failedStages > 0 {
                        LabeledContent("Failed", value: "\(metrics.failedStages)")
                            .foregroundColor(VisualizationColorScheme.errorColor)
                    }
                    LabeledContent("Avg Stage Time", value: DataFormatter.formatDuration(metrics.averageStageDuration))
                }

                Divider()

                // Per-stage timings
                Text("Stage Timings")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(snapshot.stages) { stage in
                            HStack(spacing: 8) {
                                Image(systemName: VisualizationColorScheme.icon(for: stage.type))
                                    .foregroundColor(VisualizationColorScheme.color(for: stage.type))
                                    .frame(width: 16)
                                    .font(.caption2)

                                Text(stageName(stage.type))
                                    .font(.caption2)
                                    .lineLimit(1)

                                Spacer()

                                if stage.error != nil {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(VisualizationColorScheme.errorColor)
                                        .font(.caption2)
                                }

                                Text(DataFormatter.formatDuration(stage.metrics.duration))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)

                if let slowest = metrics.slowestStage {
                    Divider()
                    HStack {
                        Image(systemName: "tortoise.fill")
                            .foregroundColor(.orange)
                            .font(.caption2)
                        Text("Slowest: \(stageName(slowest))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(8)
        } label: {
            Label("Pipeline Metrics", systemImage: "chart.bar.fill")
                .font(.caption)
        }
    }

    private func stageName(_ type: PipelineStageType) -> String {
        switch type {
        case .input: return "Input"
        case .blockStructure: return "Block"
        case .prpTransform: return "PRP"
        case .capsuleBlock: return "Capsule"
        case .baseConversion: return "Base-B"
        case .printableString: return "Printable"
        case .energiesMapping: return "Energies"
        case .normalization: return "Normalize"
        case .reverseProcess: return "Reverse"
        case .recovered: return "Recovered"
        }
    }
}
