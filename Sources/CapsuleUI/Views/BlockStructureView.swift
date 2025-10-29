import SwiftUI
import CapsuleCore

/// Detailed view for the block structure stage (Header + Data + Padding)
public struct BlockStructureView: View {
    let stage: PipelineStage

    public init(stage: PipelineStage) {
        self.stage = stage
    }

    public var body: some View {
        if case let .header(header, payload, paddingSize) = stage.data {
            VStack(alignment: .leading, spacing: 16) {
                Text("Block Structure Breakdown")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                // Header section
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Length", value: "\(header.length) bytes")
                        LabeledContent("Flags", value: String(format: "0x%02X", header.flags))
                        LabeledContent("CRC32", value: String(format: "0x%08X", header.crc32))
                        LabeledContent("Header Size", value: "\(CapsuleHeader.byteCount) bytes")
                    }
                } label: {
                    Label("Header", systemImage: "doc.text")
                        .font(.caption)
                }

                // Payload section
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Payload Size", value: "\(payload.count) bytes")

                        if !payload.isEmpty {
                            Text("Payload Preview:")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            CompactHexDumpView(bytes: payload, firstRows: 4, lastRows: 2)
                        }
                    }
                } label: {
                    Label("Payload", systemImage: "doc.plaintext")
                        .font(.caption)
                }

                // Padding section
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Padding Size", value: "\(paddingSize) bytes")
                        Text("Filled with zeros")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } label: {
                    Label("Padding", systemImage: "square.dashed")
                        .font(.caption)
                }

                // Total
                Divider()
                LabeledContent("Total Block Size", value: "\(stage.metrics.outputSize) bytes")
                    .fontWeight(.medium)
            }
        }
    }
}
