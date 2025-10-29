import SwiftUI

/// Detailed view for reverse process stage
public struct ReverseStageView: View {
    let stage: PipelineStage

    public init(stage: PipelineStage) {
        self.stage = stage
    }

    public var body: some View {
        if case let .bytes(bytes) = stage.data {
            VStack(alignment: .leading, spacing: 16) {
                Text("Reverse Transformation Process")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                // Process flow
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "bolt.fill")
                                .foregroundColor(.orange)
                            Text("Energies → Digits")
                        }
                        .font(.caption)

                        HStack {
                            Image(systemName: "number.circle")
                                .foregroundColor(.green)
                            Text("Digits → Bytes")
                        }
                        .font(.caption)

                        HStack {
                            Image(systemName: "lock.rotation")
                                .foregroundColor(.purple)
                            Text("Inverse PRP Applied")
                        }
                        .font(.caption)

                        HStack {
                            Image(systemName: "cube.fill")
                                .foregroundColor(.indigo)
                            Text("Capsule Block Recovered")
                        }
                        .font(.caption)
                    }
                } label: {
                    Label("Process Flow", systemImage: "arrow.uturn.backward")
                        .font(.caption)
                }

                // Recovered bytes
                GroupBox {
                    CompactHexDumpView(bytes: bytes, firstRows: 6, lastRows: 4)
                } label: {
                    Label("Recovered Bytes", systemImage: "doc.text")
                        .font(.caption)
                }

                // Stats
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Recovered Bytes", value: "\(bytes.count)")
                        LabeledContent("Duration", value: DataFormatter.formatDuration(stage.metrics.duration))
                    }
                } label: {
                    Label("Metrics", systemImage: "chart.line.uptrend.xyaxis")
                        .font(.caption)
                }

                Text("Next: Extract header and verify CRC")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
    }
}
