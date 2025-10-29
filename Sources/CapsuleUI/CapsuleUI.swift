import SwiftUI
import CapsuleCore
import SharedInfrastructure

public struct CapsuleUIPreview: View {
    private let snapshot: ConfigSnapshot?
    @State private var exportStatus: String = ""
    @State private var loadedSnapshot: ConfigPipelineSnapshot?

    public init(snapshot: ConfigSnapshot? = try? ConfigCenter.load()) {
        self.snapshot = snapshot
        if let root = snapshot?.root {
            _loadedSnapshot = State(initialValue: PipelineSnapshotExporter.load(from: root))
        } else {
            _loadedSnapshot = State(initialValue: nil)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let snapshot {
                let capsule = snapshot.root.capsule
                Text("Capsule Dashboard")
                    .font(.title2)
                LabeledContent("Base") { Text("\(capsule.base)") }
                LabeledContent("Block size") { Text("\(capsule.blockSize)") }
                LabeledContent("Pipeline example") {
                    Text(capsule.pipelineExampleText.isEmpty ? "n/a" : capsule.pipelineExampleText)
                }

                if let info = loadedSnapshot {
                    Text("Snapshot generated: \(format(date: info.generatedAt))")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    Text("Snapshot not exported yet")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Button("Export Snapshot") {
                        export(snapshot)
                    }
                    Button("Reload Snapshot") {
                        reload(config: snapshot.root)
                    }
                }

                if !exportStatus.isEmpty {
                    Text(exportStatus)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Config snapshot not available")
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding()
    }

    private func export(_ snapshot: ConfigSnapshot) {
        do {
            let exported = try PipelineSnapshotExporter.export(snapshot: snapshot)
            loadedSnapshot = exported
            exportStatus = "Snapshot exported at \(format(date: exported.generatedAt))"
        } catch {
            exportStatus = "Snapshot export failed: \(error.localizedDescription)"
        }
    }

    private func reload(config: ConfigRoot) {
        loadedSnapshot = PipelineSnapshotExporter.load(from: config)
        if let snapshot = loadedSnapshot {
            exportStatus = "Loaded snapshot generated at \(format(date: snapshot.generatedAt))"
        } else {
            exportStatus = "Snapshot file not found"
        }
    }

    private func format(date: Date) -> String {
        CapsuleUIPreview.dateFormatter.string(from: date)
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
