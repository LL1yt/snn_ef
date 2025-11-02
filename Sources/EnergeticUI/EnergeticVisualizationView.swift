import SwiftUI
import EnergeticCore

public struct EnergeticVisualizationView: View {
    @StateObject private var viewModel: EnergeticVisualizationViewModel
    private let title: String

    public init(
        config: RouterConfig,
        initialPackets: [EnergyPacket],
        maxSteps: Int = 256,
        title: String = "Energetic Router Visualization"
    ) {
        _viewModel = StateObject(
            wrappedValue: EnergeticVisualizationViewModel(
                config: config,
                initialPackets: initialPackets,
                maxSteps: maxSteps
            )
        )
        self.title = title
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection

                if let error = viewModel.errorDescription {
                    Text(error)
                        .font(.callout)
                        .foregroundColor(.red)
                } else if let frame = viewModel.currentFrame {
                    controlsSection
                    metricsSection(frame: frame)
                    layerEnergySection(frame: frame)
                    packetsSection(frame: frame)
                    outputSection(frame: frame)
                    historySection
                } else {
                    Text("Awaiting simulation data…")
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)

            let config = viewModel.routerConfig
            Grid(alignment: .leading) {
                GridRow {
                    Text("Layers").foregroundColor(.secondary)
                    Text("\(config.layers)")
                }
                GridRow {
                    Text("Nodes / layer").foregroundColor(.secondary)
                    Text("\(config.nodesPerLayer)")
                }
                GridRow {
                    Text("SNN params").foregroundColor(.secondary)
                    Text("\(config.snn.parameterCount)")
                }
                GridRow {
                    Text("Surrogate").foregroundColor(.secondary)
                    Text(config.snn.surrogate)
                }
                GridRow {
                    Text("α decay").foregroundColor(.secondary)
                    Text(String(format: "%.3f", config.alpha))
                }
                GridRow {
                    Text("Energy floor").foregroundColor(.secondary)
                    Text(String(format: "%.2e", config.energyFloor))
                }
            }
            .font(.callout)
        }
    }

    private var controlsSection: some View {
        HStack(spacing: 12) {
            Button("Step") {
                viewModel.step()
            }
            .disabled(viewModel.hasFinished)

            Button("Step ×5") {
                viewModel.stepMultiple(count: 5)
            }
            .disabled(viewModel.hasFinished)

            Button("Run to end") {
                viewModel.runToEnd()
            }
            .disabled(viewModel.hasFinished)

            Button("Reset") {
                viewModel.reset()
            }
        }
    }

    private func metricsSection(frame: EnergyFlowFrame) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Step \(frame.step)")
                .font(.headline)

            HStack(spacing: 16) {
                metricCard(
                    title: "Active packets",
                    value: "\(frame.activePackets.count)"
                )
                metricCard(
                    title: "Completed streams",
                    value: "\(frame.completedStreams.count)"
                )
                metricCard(
                    title: "Dead streams",
                    value: "\(frame.deadStreams.count)"
                )
                metricCard(
                    title: "Total active energy",
                    value: String(format: "%.2f", frame.totalActiveEnergy)
                )
            }

            if let summary = frame.membraneSummary {
                HStack(spacing: 16) {
                    metricCard(
                        title: "Membrane min",
                        value: String(format: "%.3f", summary.min)
                    )
                    metricCard(
                        title: "Membrane avg",
                        value: String(format: "%.3f", summary.average)
                    )
                    metricCard(
                        title: "Membrane max",
                        value: String(format: "%.3f", summary.max)
                    )
                }
            }
        }
    }

    private func metricCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.body.monospacedDigit())
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.12))
        )
    }

    private func layerEnergySection(frame: EnergyFlowFrame) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Energy per layer")
                .font(.headline)

            let maxEnergy = max(frame.maxLayerEnergy, 1)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(frame.perLayer) { layer in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Layer \(layer.layer)")
                                .font(.subheadline)
                            Spacer()
                            Text("\(layer.packetCount) packets")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        ProgressView(
                            value: Double(layer.totalEnergy),
                            total: Double(maxEnergy)
                        )
                        .progressViewStyle(.linear)
                        HStack {
                            Text("Total: \(String(format: "%.2f", layer.totalEnergy))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("Avg: \(String(format: "%.2f", layer.averageEnergy))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.secondary.opacity(0.08))
                    )
                }
            }
        }
    }

    private func packetsSection(frame: EnergyFlowFrame) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Active packets")
                .font(.headline)

            if frame.activePackets.isEmpty {
                Text("No active packets")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(frame.activePackets) { packet in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Stream \(packet.streamID)")
                                    .font(.subheadline)
                                Spacer()
                                Text("Energy \(String(format: "%.2f", packet.energy))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            HStack(spacing: 12) {
                                Text("Layer \(packet.x)")
                                Text("Node \(packet.y)")
                                Text("Time \(packet.time)")
                                Text("Membrane \(String(format: "%.3f", packet.membrane))")
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 0.5)
                        )
                    }
                }
            }
        }
    }

    private func outputSection(frame: EnergyFlowFrame) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Outputs")
                .font(.headline)

            if frame.outputEnergies.isEmpty {
                Text("No output energy yet")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(frame.outputEnergies.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                        HStack {
                            Text("Stream \(entry.key)")
                            Spacer()
                            Text(String(format: "%.2f", entry.value))
                                .font(.body.monospacedDigit())
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if !frame.completedStreams.isEmpty || !frame.deadStreams.isEmpty {
                HStack(spacing: 12) {
                    if !frame.completedStreams.isEmpty {
                        Text("Completed: \(frame.completedStreams.sorted().map(String.init).joined(separator: ", "))")
                            .font(.caption)
                    }
                    if !frame.deadStreams.isEmpty {
                        Text("Dead: \(frame.deadStreams.sorted().map(String.init).joined(separator: ", "))")
                            .font(.caption)
                    }
                }
                .foregroundColor(.secondary)
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("History")
                .font(.headline)
            if viewModel.frameHistory.isEmpty {
                Text("No steps recorded yet")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                let lastFrames = viewModel.frameHistory.suffix(10)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(lastFrames), id: \.id) { frame in
                        HStack {
                            Text("Step \(frame.step)")
                                .font(.caption)
                            Spacer()
                            Text("Active \(frame.activePackets.count)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Energy \(String(format: "%.2f", frame.totalActiveEnergy))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }
}
