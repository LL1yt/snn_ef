import SwiftUI
import Foundation
import EnergeticCore
import SharedInfrastructure

public struct EnergeticUIPreview: View {
    private let snapshot: ConfigSnapshot?
    private let routerConfig: RouterConfig
    private let samplePackets: [EnergyPacket]

    @State private var loadedSnapshot: ConfigPipelineSnapshot?
    @State private var lastRouterEvent: Date?

    public init(snapshot: ConfigSnapshot? = try? ConfigCenter.load()) {
        self.snapshot = snapshot
        if let root = snapshot?.root, let config = try? RouterFactory.createFrom(root.router) {
            self.routerConfig = config
        } else {
            self.routerConfig = RouterFactory.createTestConfig()
        }
        self.samplePackets = EnergeticUIPreview.makeSamplePackets(config: routerConfig)

        if let root = snapshot?.root {
            _loadedSnapshot = State(initialValue: PipelineSnapshotExporter.load(from: root))
        } else {
            _loadedSnapshot = State(initialValue: nil)
        }
        _lastRouterEvent = State(initialValue: LoggingHub.lastEventTimestamp(for: "router.step"))
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            if let snapshot {
                let router = snapshot.root.router
                Text("Router Dashboard")
                    .font(.title2)
                LabeledContent("Layers") { Text("\(router.layers)") }
                LabeledContent("Nodes / layer") { Text("\(router.nodesPerLayer)") }
                LabeledContent("SNN Params") { Text("\(router.snn.parameterCount)") }
                LabeledContent("Surrogate") { Text(router.snn.surrogate) }
                LabeledContent("Δx range") { Text("[\(router.snn.deltaXRange.min), \(router.snn.deltaXRange.max)]") }
                LabeledContent("Δy range") { Text("[\(router.snn.deltaYRange.min), \(router.snn.deltaYRange.max)]") }
                LabeledContent("Alpha") { Text(String(format: "%.3f", router.alpha)) }
                LabeledContent("Energy floor") { Text(String(format: "%.2e", router.energyFloor)) }

                if let lastRouterEvent {
                    Text("Last router event: \(format(date: lastRouterEvent))")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    Text("No router events recorded yet")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                if let info = loadedSnapshot {
                    Text("Snapshot profile: \(info.profile) at \(format(date: info.generatedAt))")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Button("Refresh Metrics") {
                        lastRouterEvent = LoggingHub.lastEventTimestamp(for: "router.step")
                        let root = snapshot.root
                        loadedSnapshot = PipelineSnapshotExporter.load(from: root)
                    }
                    Button("Export Snapshot") {
                        if let exported: ConfigPipelineSnapshot = try? PipelineSnapshotExporter.export(snapshot: snapshot) {
                            loadedSnapshot = exported
                            lastRouterEvent = LoggingHub.lastEventTimestamp(for: "router.step")
                        }
                    }
                }
            } else {
                Text("Config snapshot not available")
                    .foregroundColor(.secondary)
            }

                Divider()

                EnergeticVisualizationView(
                    config: routerConfig,
                    initialPackets: samplePackets,
                    maxSteps: 256,
                    title: "Simulation Preview"
                )
            }
        }
        .padding()
    }

    private func format(date: Date) -> String {
        EnergeticUIPreview.dateFormatter.string(from: date)
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func makeSamplePackets(config: RouterConfig) -> [EnergyPacket] {
        let nodes = max(config.nodesPerLayer, 1)
        let maxIndex = max(nodes - 1, 0)
        let quarterY = min(nodes / 4, maxIndex)
        let midY = min(nodes / 2, maxIndex)
        let threeQuarterY = min((3 * nodes) / 4, maxIndex)
        return [
            EnergyPacket(streamID: 1, x: 0, y: quarterY, energy: 128.0, time: 0),
            EnergyPacket(streamID: 2, x: 0, y: midY, energy: 96.0, time: 0),
            EnergyPacket(streamID: 3, x: 0, y: threeQuarterY, energy: 64.0, time: 0)
        ]
    }
}
