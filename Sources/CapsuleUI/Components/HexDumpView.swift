import SwiftUI

/// Displays a hex dump of byte data with address, hex values, and ASCII representation
public struct HexDumpView: View {
    let bytes: [UInt8]
    let bytesPerRow: Int
    let highlightRange: Range<Int>?
    let maxRows: Int?

    public init(
        bytes: [UInt8],
        bytesPerRow: Int = 16,
        highlightRange: Range<Int>? = nil,
        maxRows: Int? = nil
    ) {
        self.bytes = bytes
        self.bytesPerRow = bytesPerRow
        self.highlightRange = highlightRange
        self.maxRows = maxRows
    }

    public var body: some View {
        let rows = HexFormatter.formatWithHighlight(
            bytes: bytes,
            highlightRange: highlightRange,
            bytesPerRow: bytesPerRow
        )

        let displayRows = maxRows.map { Array(rows.prefix($0)) } ?? rows
        let isTruncated = maxRows != nil && rows.count > maxRows!

        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(displayRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    // Address
                    Text(row.address)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)

                    Text("|")
                        .foregroundColor(.secondary)

                    // Hex bytes
                    Text(row.hex)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(row.isHighlighted ? .blue : .primary)

                    Text("|")
                        .foregroundColor(.secondary)

                    // ASCII
                    Text(row.ascii)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 1)
                .background(row.isHighlighted ? VisualizationColorScheme.highlightBackground : Color.clear)
            }

            if isTruncated {
                Text("... (\(rows.count - displayRows.count) more rows)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
        .padding(8)
        .background(VisualizationColorScheme.codeBackground)
        .cornerRadius(6)
    }
}

/// Compact hex dump showing only first and last N rows
public struct CompactHexDumpView: View {
    let bytes: [UInt8]
    let firstRows: Int
    let lastRows: Int

    public init(bytes: [UInt8], firstRows: Int = 8, lastRows: Int = 4) {
        self.bytes = bytes
        self.firstRows = firstRows
        self.lastRows = lastRows
    }

    public var body: some View {
        let bytesPerRow = 16
        let totalRows = (bytes.count + bytesPerRow - 1) / bytesPerRow

        if totalRows <= firstRows + lastRows {
            HexDumpView(bytes: bytes, maxRows: totalRows)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                // First rows
                VStack(alignment: .leading, spacing: 0) {
                    Text("First \(firstRows * bytesPerRow) bytes:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HexDumpView(bytes: Array(bytes.prefix(firstRows * bytesPerRow)))
                }

                Text("...")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()

                // Last rows
                VStack(alignment: .leading, spacing: 0) {
                    Text("Last \(lastRows * bytesPerRow) bytes:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HexDumpView(bytes: Array(bytes.suffix(lastRows * bytesPerRow)))
                }

                Text("Total: \(bytes.count) bytes (\(totalRows) rows)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}
