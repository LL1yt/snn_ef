import SwiftUI
import EnergeticCore
import EnergeticUI
import SharedInfrastructure
import CapsuleCore

@main
struct EnergeticVisualizationDemoApp: App {
    private let snapshot: ConfigSnapshot?
    private let routerConfig: RouterConfig
    private let initialPackets: [EnergyPacket]
    private let loadError: Error?

    init() {
        var resolvedSnapshot: ConfigSnapshot?
        var resolvedConfig: RouterConfig = EnergeticVisualizationDemoApp.makeStubConfig()
        var resolvedPackets: [EnergyPacket] = EnergeticVisualizationDemoApp.makeInitialPackets(config: resolvedConfig)
        var resolvedError: Error?

        do {
            let env = ProcessInfo.processInfo.environment
            let configURL = env["SNN_CONFIG_PATH"].map { URL(fileURLWithPath: $0) }

            let loadedSnapshot = try ConfigCenter.load(url: configURL)
            try LoggingHub.configure(from: loadedSnapshot)
            ProcessRegistry.configure(from: loadedSnapshot)

            resolvedSnapshot = loadedSnapshot
            // Flow backend: UI preview uses a stub RouterConfig; visual routing is disabled
            resolvedConfig = EnergeticVisualizationDemoApp.makeStubConfig()
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
                if let cfgSnap = snapshot {
                    // Build Flow live demo inputs from config + capsule example
                    let cfg = FlowConfig.from(cfgSnap.root.router)
                    let exampleText = cfgSnap.root.capsule.pipelineExampleText.isEmpty ? "Hello, Energetic Router!" : cfgSnap.root.capsule.pipelineExampleText
                    let inputData = Data(exampleText.utf8)
                    let (batch, _) = try! CapsuleBridge.makeEnergies(from: inputData, config: cfgSnap.root.capsule)
                    let energies = batch.energies.map { UInt16($0) }

                    VStack(spacing: 16) {
                        FlowLiveView(cfg: cfg, energies: energies, seed: UInt64(cfgSnap.root.seed))
                            .frame(minWidth: 900, minHeight: 640)
                        if let flow = PipelineSnapshotExporter.load(from: cfgSnap.root)?.flow {
                            FlowRingHistogramView(flow: flow)
                                .frame(height: 280)
                                .padding(.horizontal)
                        }
                    }
                } else {
                    FailureView(error: loadError)
                }
            } else {
                FailureView(error: loadError)
            }
        }
    }

    private static func makeInitialPackets(config: RouterConfig) -> [EnergyPacket] {
        // Legacy grid packets kept only for UI preview structure; not simulated
        return [
            EnergyPacket(streamID: 1, x: 0, y: 0, energy: 128.0, time: 0),
            EnergyPacket(streamID: 2, x: 0, y: 0, energy: 96.0, time: 0),
            EnergyPacket(streamID: 3, x: 0, y: 0, energy: 64.0, time: 0)
        ]
    }

    private static func makeStubConfig() -> RouterConfig {
        let snn = SNNConfig(
            parameterCount: 128,
            decay: 0.9,
            threshold: 0.5,
            resetValue: 0.0,
            deltaXRange: 1...1,
            deltaYRange: 0...0,
            surrogate: "fast_sigmoid",
            dt: 1
        )
        return RouterConfig(
            layers: 1,
            nodesPerLayer: 1,
            snn: snn,
            alpha: 1.0,
            energyFloor: 0.0,
            energyBase: 256
        )
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
