import SwiftUI

/// Navigation controls for stepping through pipeline stages
public struct StageNavigationView: View {
    let currentIndex: Int
    let totalStages: Int
    let isPlaying: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onTogglePlay: () -> Void
    let onReset: () -> Void

    public init(
        currentIndex: Int,
        totalStages: Int,
        isPlaying: Bool,
        onPrevious: @escaping () -> Void,
        onNext: @escaping () -> Void,
        onTogglePlay: @escaping () -> Void,
        onReset: @escaping () -> Void
    ) {
        self.currentIndex = currentIndex
        self.totalStages = totalStages
        self.isPlaying = isPlaying
        self.onPrevious = onPrevious
        self.onNext = onNext
        self.onTogglePlay = onTogglePlay
        self.onReset = onReset
    }

    public var body: some View {
        GroupBox {
            VStack(spacing: 12) {
                // Progress indicator
                HStack {
                    Text("Stage")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(currentIndex + 1) / \(totalStages)")
                        .font(.caption)
                        .fontWeight(.medium)
                }

                // Progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 4)
                            .cornerRadius(2)

                        Rectangle()
                            .fill(Color.blue)
                            .frame(
                                width: geometry.size.width * CGFloat(currentIndex + 1) / CGFloat(totalStages),
                                height: 4
                            )
                            .cornerRadius(2)
                    }
                }
                .frame(height: 4)

                // Navigation controls
                HStack(spacing: 16) {
                    // Previous
                    Button(action: onPrevious) {
                        Image(systemName: "chevron.left.circle.fill")
                            .font(.title2)
                    }
                    .disabled(currentIndex == 0)
                    .help("Previous stage")

                    // Play/Pause
                    Button(action: onTogglePlay) {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title)
                    }
                    .help(isPlaying ? "Pause" : "Play")

                    // Next
                    Button(action: onNext) {
                        Image(systemName: "chevron.right.circle.fill")
                            .font(.title2)
                    }
                    .disabled(currentIndex >= totalStages - 1)
                    .help("Next stage")

                    Spacer()

                    // Reset
                    Button(action: onReset) {
                        Image(systemName: "arrow.counterclockwise.circle")
                            .font(.title3)
                    }
                    .help("Reset to first stage")
                }
            }
            .padding(8)
        } label: {
            Label("Navigation", systemImage: "arrow.left.arrow.right")
                .font(.caption)
        }
    }
}
