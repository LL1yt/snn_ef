import SwiftUI
import CapsuleCore

/// Detailed view for the final capsule block
public struct CapsuleBlockView: View {
    let stage: PipelineStage

    public init(stage: PipelineStage) {
        self.stage = stage
    }

    public var body: some View {
        if case let .block(capsuleBlock) = stage.data {
            VStack(alignment: .leading, spacing: 16) {
                Text("Final Capsule Block")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                // Block info
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Block Size", value: "\(capsuleBlock.blockSize) bytes")
                        LabeledContent("Total Bytes", value: "\(capsuleBlock.bytes.count)")
                    }
                } label: {
                    Label("Info", systemImage: "info.circle")
                        .font(.caption)
                }

                // Hex dump
                GroupBox {
                    CompactHexDumpView(bytes: capsuleBlock.bytes, firstRows: 6, lastRows: 4)
                } label: {
                    Label("Hex Dump", systemImage: "cube.fill")
                        .font(.caption)
                }

                Text("This block is ready for base-B conversion")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
    }
}
