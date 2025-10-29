import SwiftUI
import SharedInfrastructure

/// Detailed view for energies mapping stage
public struct EnergiesStageView: View {
    let stage: PipelineStage
    let config: ConfigRoot.Capsule

    public init(stage: PipelineStage, config: ConfigRoot.Capsule) {
        self.stage = stage
        self.config = config
    }

    public var body: some View {
        if case let .energies(energies) = stage.data {
            let min = energies.min() ?? 0
            let max = energies.max() ?? 0
            let sum = energies.reduce(0, +)
            let mean = Double(sum) / Double(energies.count)

            VStack(alignment: .leading, spacing: 16) {
                Text("Energies [1..\(config.base)]")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                // Statistics
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Count", value: "\(energies.count)")
                        LabeledContent("Range", value: "[1..\(config.base)]")
                        LabeledContent("Min", value: "\(min)")
                        LabeledContent("Max", value: "\(max)")
                        LabeledContent("Mean", value: String(format: "%.2f", mean))
                        LabeledContent("Sum", value: "\(sum)")
                    }
                } label: {
                    Label("Statistics", systemImage: "chart.bar")
                        .font(.caption)
                }

                // Distribution info
                GroupBox {
                    let histogram = Dictionary(grouping: energies, by: { $0 })
                        .mapValues { $0.count }
                        .sorted { $0.key < $1.key }

                    if !histogram.isEmpty {
                        Text("Most common values:")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        let topValues = histogram.sorted { $0.value > $1.value }.prefix(5)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(topValues), id: \.key) { energy, count in
                                HStack {
                                    Text("Energy \(energy):")
                                        .font(.caption)
                                    Spacer()
                                    Text("\(count) times")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                } label: {
                    Label("Distribution", systemImage: "chart.pie")
                        .font(.caption)
                }

                // Values preview
                GroupBox {
                    CompactDigitsView(digits: energies, base: config.base + 1, first: 50, last: 10)
                } label: {
                    Label("Energy Values", systemImage: "bolt.fill")
                        .font(.caption)
                }

                Text("Mapped from digits by adding 1: digit[i] + 1 → energy[i]")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
    }
}
