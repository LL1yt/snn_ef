import SwiftUI
import EnergeticCore
import EnergeticUI
import SharedInfrastructure

@main
struct EnergeticVisualizationDemoApp: App {
    private let snapshot: ConfigSnapshot?
    private let routerConfig: RouterConfig
    private let initialPackets: [EnergyPacket]
    private let loadError: Error?

    init() {
        var resolvedSnapshot: ConfigSnapshot?
        var resolvedConfig: RouterConfig = RouterFactory.createTestConfig()
        var resolvedPackets: [EnergyPacket] = EnergeticVisualizationDemoApp.makeInitialPackets(config: resolvedConfig)
        var resolvedError: Error?

        do {
            let env = ProcessInfo.processInfo.environment
            let configURL = env["SNN_CONFIG_PATH"].map { URL(fileURLWithPath: $0) }

            let loadedSnapshot = try ConfigCenter.load(url: configURL)
            try LoggingHub.configure(from: loadedSnapshot)
            ProcessRegistry.configure(from: loadedSnapshot)

            resolvedSnapshot = loadedSnapshot
            // Flow backend: demo uses internal test config until Flow UI is wired
            resolvedConfig = RouterFactory.createTestConfig()
            resolvedPackets = EnergeticVisualizationDemoApp.makeInitialPackets(config: resolvedConfig)
            resolvedError = nil

            LoggingHub.emit(
                process: "ui.pipeline.app",
                level: .info,
                message: "EnergeticVisualization demo launched with config: \(loadedSnapshot.sourceURL.path)"
            )
        } catch {
            resolvedSnapshot = nil
            resolvedError = error
            print("Failed to load config: \(error)")
        }

        snapshot = resolvedSnapshot
        routerConfig = resolvedConfig
        initialPackets = resolvedPackets
        loadError = resolvedError
    }

    var body: some Scene {
        WindowGroup {
            if loadError == nil || snapshot != nil {
                EnergeticVisualizationView(
                    config: routerConfig,
                    initialPackets: initialPackets,
                    maxSteps: 256,
                    title: "Energetic Router Simulation"
                )
                .frame(minWidth: 900, minHeight: 640)
            } else {
                FailureView(error: loadError)
            }
        }
    }

    private static func makeInitialPackets(config: RouterConfig) -> [EnergyPacket] {
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

private struct FailureView: View {
    let error: Error?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(.red)
            Text("Failed to load configuration")
                .font(.headline)
            if let error {
                Text(error.localizedDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text("Set SNN_CONFIG_PATH or run from repo root so Configs/baseline.yaml is discoverable.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 480, minHeight: 240)
    }
}
