import Foundation

/// Utilities for formatting byte arrays as hexadecimal dumps
public enum HexFormatter {
    /// Format bytes as a hex dump with address, hex values, and ASCII representation
    /// Format: ADDRESS | HEX BYTES | ASCII
    /// Example: 00000000 | 48 65 6C 6C 6F 20 57 6F | Hello Wo
    public static func format(bytes: [UInt8], bytesPerRow: Int = 16) -> String {
        guard !bytes.isEmpty else { return "" }

        var result = ""
        let chunks = bytes.chunked(into: bytesPerRow)

        for (rowIndex, chunk) in chunks.enumerated() {
            let address = String(format: "%08X", rowIndex * bytesPerRow)
            let hexPart = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            let paddedHex = hexPart.padding(toLength: bytesPerRow * 3 - 1, withPad: " ", startingAt: 0)
            let asciiPart = chunk.map { byte in
                (32...126).contains(byte) ? String(Character(UnicodeScalar(byte))) : "."
            }.joined()

            result += "\(address) | \(paddedHex) | \(asciiPart)\n"
        }

        return result
    }

    /// Format a single byte as hex
    public static func hexByte(_ byte: UInt8) -> String {
        String(format: "%02X", byte)
    }

    /// Format an array of bytes as compact hex string
    public static func hexString(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }

    /// Format bytes with highlighting for specific ranges
    public static func formatWithHighlight(
        bytes: [UInt8],
        highlightRange: Range<Int>?,
        bytesPerRow: Int = 16
    ) -> [(address: String, hex: String, ascii: String, isHighlighted: Bool)] {
        guard !bytes.isEmpty else { return [] }

        var rows: [(String, String, String, Bool)] = []
        let chunks = bytes.chunked(into: bytesPerRow)

        for (rowIndex, chunk) in chunks.enumerated() {
            let startOffset = rowIndex * bytesPerRow
            let address = String(format: "%08X", startOffset)
            let hexPart = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            let paddedHex = hexPart.padding(toLength: bytesPerRow * 3 - 1, withPad: " ", startingAt: 0)
            let asciiPart = chunk.map { byte in
                (32...126).contains(byte) ? String(Character(UnicodeScalar(byte))) : "."
            }.joined()

            let isHighlighted: Bool
            if let range = highlightRange {
                let rowRange = startOffset..<(startOffset + chunk.count)
                isHighlighted = rowRange.overlaps(range)
            } else {
                isHighlighted = false
            }

            rows.append((address, paddedHex, asciiPart, isHighlighted))
        }

        return rows
    }
}

// Helper extension for chunking arrays
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
