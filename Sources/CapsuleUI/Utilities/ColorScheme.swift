import SwiftUI

/// Visual theme and color scheme for pipeline visualization
public enum VisualizationColorScheme {
    /// Get color for a specific stage type
    public static func color(for stageType: PipelineStageType) -> Color {
        switch stageType {
        case .input:
            return .blue
        case .blockStructure:
            return .cyan
        case .prpTransform:
            return .purple
        case .capsuleBlock:
            return .indigo
        case .baseConversion:
            return .green
        case .printableString:
            return .mint
        case .energiesMapping:
            return .orange
        case .normalization:
            return .yellow
        case .reverseProcess:
            return .pink
        case .recovered:
            return .green
        }
    }

    /// Get SF Symbol icon name for a stage type
    public static func icon(for stageType: PipelineStageType) -> String {
        switch stageType {
        case .input:
            return "text.cursor"
        case .blockStructure:
            return "square.grid.3x3"
        case .prpTransform:
            return "lock.rotation"
        case .capsuleBlock:
            return "cube.fill"
        case .baseConversion:
            return "number.circle"
        case .printableString:
            return "text.quote"
        case .energiesMapping:
            return "bolt.fill"
        case .normalization:
            return "slider.horizontal.3"
        case .reverseProcess:
            return "arrow.uturn.backward"
        case .recovered:
            return "checkmark.circle.fill"
        }
    }

    /// Get semantic color for success/error states
    public static var successColor: Color { .green }
    public static var errorColor: Color { .red }
    public static var warningColor: Color { .orange }
    public static var neutralColor: Color { .secondary }

    /// Background colors for different contexts
    public static var highlightBackground: Color { Color.blue.opacity(0.1) }
    public static var errorBackground: Color { Color.red.opacity(0.1) }
    public static var successBackground: Color { Color.green.opacity(0.1) }
    public static var codeBackground: Color { Color.gray.opacity(0.1) }
}
