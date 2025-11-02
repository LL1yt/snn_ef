import SwiftUI

/// Header view for a pipeline stage showing type, status, and metrics
public struct StageHeaderView: View {
    let stage: PipelineStage
    let expanded: Bool
    let onToggle: () -> Void

    public init(stage: PipelineStage, expanded: Bool, onToggle: @escaping () -> Void) {
        self.stage = stage
        self.expanded = expanded
        self.onToggle = onToggle
    }

    public var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                // Icon
                Image(systemName: VisualizationColorScheme.icon(for: stage.type))
                    .foregroundColor(VisualizationColorScheme.color(for: stage.type))
                    .frame(width: 24)

                // Stage name
                Text(stageName)
                    .font(.headline)
                    .foregroundColor(.primary)

                Spacer()

                // Error indicator
                if let error = stage.error {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(VisualizationColorScheme.errorColor)
                        .help(error)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(VisualizationColorScheme.successColor)
                        .font(.caption)
                }

                // Duration
                Text(DataFormatter.formatDuration(stage.metrics.duration))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(minWidth: 60, alignment: .trailing)

                // Expand/collapse indicator
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var stageName: String {
        switch stage.type {
        case .input: return "Input Text"
        case .blockStructure: return "Block Structure"
        case .prpTransform: return "PRP Transform"
        case .capsuleBlock: return "Capsule Block"
        case .baseConversion: return "Base-B Conversion"
        case .printableString: return "Printable String"
        case .energiesMapping: return "Energies Mapping"
        case .normalization: return "Normalization"
        case .reverseProcess: return "Reverse Process"
        case .recovered: return "Recovered Text"
        }
    }
}
