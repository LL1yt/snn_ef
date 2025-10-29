import SwiftUI

/// Detailed view for the PRP transformation stage
public struct PRPStageView: View {
    let stage: PipelineStage
    let beforeBytes: [UInt8]

    public init(stage: PipelineStage, beforeBytes: [UInt8]) {
        self.stage = stage
        self.beforeBytes = beforeBytes
    }

    public var body: some View {
        if case let .bytes(afterBytes) = stage.data {
            VStack(alignment: .leading, spacing: 16) {
                // PRP info
                if let prpType = stage.metrics.metadata["prp_type"],
                   let rounds = stage.metrics.metadata["rounds"] {
                    HStack {
                        Text("PRP Type:")
                            .fontWeight(.semibold)
                        Text(prpType.capitalized)
                        Spacer()
                        Text("Rounds:")
                            .fontWeight(.semibold)
                        Text(rounds)
                    }
                    .font(.subheadline)
                }

                // Before PRP
                GroupBox {
                    CompactHexDumpView(bytes: beforeBytes, firstRows: 4, lastRows: 2)
                } label: {
                    Label("Before PRP", systemImage: "lock.open")
                        .font(.caption)
                }

                // Arrow indicator
                HStack {
                    Spacer()
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundColor(.purple)
                    Spacer()
                }

                // After PRP
                GroupBox {
                    CompactHexDumpView(bytes: afterBytes, firstRows: 4, lastRows: 2)
                } label: {
                    Label("After PRP", systemImage: "lock.fill")
                        .font(.caption)
                }

                // Stats
                Text("Transformation ensures pseudorandom permutation with deterministic reversibility")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
    }
}
