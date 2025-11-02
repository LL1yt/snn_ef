import SwiftUI

/// Displays an array of digits in a grid layout with indices
public struct DigitsTableView: View {
    let digits: [Int]
    let base: Int
    let columns: Int
    let highlightIndices: Set<Int>?
    let showIndices: Bool

    public init(
        digits: [Int],
        base: Int,
        columns: Int = 10,
        highlightIndices: Set<Int>? = nil,
        showIndices: Bool = true
    ) {
        self.digits = digits
        self.base = base
        self.columns = columns
        self.highlightIndices = highlightIndices
        self.showIndices = showIndices
    }

    public var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns),
            spacing: 8
        ) {
            ForEach(Array(digits.enumerated()), id: \.offset) { index, digit in
                digitCell(index: index, digit: digit)
            }
        }
        .padding(8)
        .background(VisualizationColorScheme.codeBackground)
        .cornerRadius(6)
    }

    @ViewBuilder
    private func digitCell(index: Int, digit: Int) -> some View {
        let isHighlighted = highlightIndices?.contains(index) ?? false

        VStack(spacing: 2) {
            if showIndices {
                Text("[\(index)]")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Text("\(digit)")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(isHighlighted ? .blue : .primary)
                .fontWeight(isHighlighted ? .bold : .regular)
        }
        .padding(4)
        .frame(maxWidth: .infinity)
        .background(isHighlighted ? VisualizationColorScheme.highlightBackground : Color.clear)
        .cornerRadius(4)
    }
}

/// Compact version showing first N and last M digits
public struct CompactDigitsView: View {
    let digits: [Int]
    let base: Int
    let first: Int
    let last: Int

    public init(digits: [Int], base: Int, first: Int = 50, last: Int = 10) {
        self.digits = digits
        self.base = base
        self.first = first
        self.last = last
    }

    public var body: some View {
        if digits.count <= first + last {
            DigitsTableView(digits: digits, base: base)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                // First N
                VStack(alignment: .leading, spacing: 4) {
                    Text("First \(first) digits:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    DigitsTableView(digits: Array(digits.prefix(first)), base: base)
                }

                Text("...")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()

                // Last M
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last \(last) digits:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    DigitsTableView(digits: Array(digits.suffix(last)), base: base)
                }

                Text("Total: \(digits.count) digits (base-\(base))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}
