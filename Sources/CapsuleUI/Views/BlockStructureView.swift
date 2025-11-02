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

                            let samples = payloadSamples(bytes: payload, limit: 8)
                            if !samples.isEmpty {
                                Divider()
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Sample bytes:")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    ForEach(samples) { sample in
                                        HStack(spacing: 8) {
                                            Text(String(format: "[%03d]", sample.index))
                                                .font(.system(.caption2, design: .monospaced))
                                                .foregroundColor(.secondary)
                                            Text(sample.byteHex)
                                                .font(.system(.caption, design: .monospaced))
                                            Text(sample.asciiDescription)
                                                .font(.system(.caption2, design: .monospaced))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }
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

private func payloadSamples(bytes: [UInt8], limit: Int) -> [PayloadSample] {
    guard limit > 0 else { return [] }
    let count = min(limit, bytes.count)
    return (0..<count).map { index in
        PayloadSample(index: index, byte: bytes[index])
    }
}

private struct PayloadSample: Identifiable {
    let index: Int
    let byte: UInt8

    var id: Int { index }

    var byteHex: String {
        String(format: "0x%02X", byte)
    }

    var asciiDescription: String {
        if byte >= 0x20 && byte <= 0x7E {
            return "('\(Character(UnicodeScalar(byte))))"
        } else if byte == 0x0A {
            return "(LF)"
        } else if byte == 0x0D {
            return "(CR)"
        } else if byte == 0x09 {
            return "(TAB)"
        } else {
            return ""
        }
    }
}
