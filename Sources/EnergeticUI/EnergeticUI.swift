import SwiftUI
import EnergeticCore
import SharedInfrastructure

public struct EnergeticUIPreview: View {
    private let snapshot: ConfigSnapshot?
    @State private var loadedSnapshot: ConfigPipelineSnapshot?
    @State private var lastRouterEvent: Date?

    public init(snapshot: ConfigSnapshot? = try? ConfigCenter.load()) {
        self.snapshot = snapshot
        if let root = snapshot?.root {
            _loadedSnapshot = State(initialValue: PipelineSnapshotExporter.load(from: root))
        } else {
            _loadedSnapshot = State(initialValue: nil)
        }
        _lastRouterEvent = State(initialValue: LoggingHub.lastEventTimestamp(for: "router.forward"))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let snapshot {
                let router = snapshot.root.router
                Text("Router Dashboard")
                    .font(.title2)
                LabeledContent("Layers") { Text("\(router.layers)") }
                LabeledContent("Nodes / layer") { Text("\(router.nodesPerLayer)") }
                LabeledContent("Top-K") { Text("\(router.topK)") }
                LabeledContent("Backend") { Text(router.backend) }

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
                        lastRouterEvent = LoggingHub.lastEventTimestamp(for: "router.forward")
                        let root = snapshot.root
                        loadedSnapshot = PipelineSnapshotExporter.load(from: root)
                    }
                    Button("Export Snapshot") {
                        if let exported: ConfigPipelineSnapshot = try? PipelineSnapshotExporter.export(snapshot: snapshot) {
                            loadedSnapshot = exported
                            lastRouterEvent = LoggingHub.lastEventTimestamp(for: "router.forward")
                        }
                    }
                }
            } else {
                Text("Config snapshot not available")
                    .foregroundColor(.secondary)
            }

            Spacer()
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
}
