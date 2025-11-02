import Foundation

/// Utilities for formatting various data types for display
public enum DataFormatter {
    /// Format duration in milliseconds
    public static func formatDuration(_ duration: TimeInterval) -> String {
        let ms = duration * 1000
        if ms < 1 {
            return String(format: "%.3f ms", ms)
        } else if ms < 1000 {
            return String(format: "%.2f ms", ms)
        } else {
            return String(format: "%.2f s", duration)
        }
    }

    /// Format byte count with appropriate units
    public static func formatByteCount(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.2f KB", Double(bytes) / 1024.0)
        } else {
            return String(format: "%.2f MB", Double(bytes) / (1024.0 * 1024.0))
        }
    }

    /// Format a number with thousands separators
    public static func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    /// Format a floating point number with specified precision
    public static func formatFloat(_ value: Double, precision: Int = 2) -> String {
        String(format: "%.\(precision)f", value)
    }

    /// Truncate string to specified length with ellipsis
    public static func truncate(_ string: String, maxLength: Int) -> String {
        if string.count <= maxLength {
            return string
        } else {
            let endIndex = string.index(string.startIndex, offsetBy: maxLength - 3)
            return String(string[..<endIndex]) + "..."
        }
    }

    /// Format array preview showing first N and last M elements
    public static func formatArrayPreview<T>(
        _ array: [T],
        first: Int = 10,
        last: Int = 5,
        transform: (T) -> String = { "\($0)" }
    ) -> String {
        guard !array.isEmpty else { return "[]" }

        if array.count <= first + last {
            return "[" + array.map(transform).joined(separator: ", ") + "]"
        } else {
            let firstElements = array.prefix(first).map(transform).joined(separator: ", ")
            let lastElements = array.suffix(last).map(transform).joined(separator: ", ")
            return "[\(firstElements) ... \(lastElements)]"
        }
    }
}
