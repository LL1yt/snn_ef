import EnergeticCore
import Foundation
import SharedInfrastructure
import CapsuleCore

@main
struct EnergeticCLI {
    static func main() {
        let processID = (try? ProcessRegistry.resolve("cli.main")) ?? "cli.main"
        let env = ProcessInfo.processInfo.environment
        let configURL = env["SNN_CONFIG_PATH"].map { URL(fileURLWithPath: $0) }

        let snapshot: ConfigSnapshot
        do {
            snapshot = try ConfigCenter.load(url: configURL)
            ProcessRegistry.configure(from: snapshot)
            try LoggingHub.configure(from: snapshot)
        } catch {
            Diagnostics.fail("Failed to load config: \(error.localizedDescription)", processID: processID)
        }

        let routerConfig = snapshot.root.router
        LoggingHub.emit(
            process: "cli.main",
            level: .info,
            message: "Router config loaded from \(snapshot.sourceURL.path) · backend=\(routerConfig.backend), T=\(routerConfig.flow.T), bins=\(routerConfig.flow.projection.bins), surrogate=\(routerConfig.flow.lif.surrogate)"
        )

        // Flow run: take capsule example text -> energies -> flow bins
        let flowCfg = FlowConfig.from(snapshot.root.router)
        let exampleText = snapshot.root.capsule.pipelineExampleText.isEmpty ? "Hello, Energetic Router!" : snapshot.root.capsule.pipelineExampleText
        let inputData = Data(exampleText.utf8)
        let (batch, _) = try! CapsuleBridge.makeEnergies(from: inputData, config: snapshot.root.capsule)
        let energiesU16 = batch.energies.map { UInt16($0) }
        let bins = FlowBridgeSNN.simulate(energies: energiesU16, cfg: flowCfg, seed: UInt64(snapshot.root.seed))

        // Prepare flow snapshot: ring seeds + selected particle samples
        let seedsParticles = FlowSeeds.makeSeeds(energies: energiesU16, cfg: flowCfg, seed: UInt64(snapshot.root.seed))
        let ringSeeds: [ConfigPipelineSnapshot.FlowSnapshot.RingSeed] = seedsParticles.map { p in
            let angle = atan2(Double(p.pos.y), Double(p.pos.x))
            return .init(id: p.id, angle: angle, x: Double(p.pos.x), y: Double(p.pos.y), energy: Double(p.energy))
        }
        let sampleCount = min(8, seedsParticles.count)
        let samples: [ConfigPipelineSnapshot.FlowSnapshot.ParticleSample] = Array(seedsParticles.prefix(sampleCount)).map { p in
            .init(id: p.id, x: Double(p.pos.x), y: Double(p.pos.y), vx: Double(p.vel.x), vy: Double(p.vel.y), energy: Double(p.energy), V: Double(p.V))
        }
        let flowSnapshot = ConfigPipelineSnapshot.FlowSnapshot(
            bins: bins.map { Double($0) },
            radius: Double(flowCfg.radius),
            stepCount: flowCfg.T,
            ringSeeds: ringSeeds,
            samples: samples
        )

        // Log summary
        let total = bins.reduce(0, +)
        let nonZero = bins.enumerated().filter { $0.element > 0 }
        LoggingHub.emit(process: "router.output", level: .info, message: "flow bins: total=\(String(format: "%.2f", total)) nonzero=\(nonZero.count)/\(bins.count)")

        // Export snapshot with flow data (headless parity for UI)
        if let exported: ConfigPipelineSnapshot = try? PipelineSnapshotExporter.export(snapshot: snapshot, flow: flowSnapshot) {
            LoggingHub.emit(process: "cli.main", level: .debug, message: "Pipeline snapshot exported at \(exported.generatedAt)")
        }

        // Print concise report and legacy-friendly line for tests
        print("Router backend: \(routerConfig.backend)")
        print("Flow backend ✓ · bins=\(bins.count) total=\(String(format: "%.2f", total)) nonzero=\(nonZero.count)")

        let hint = CLIRenderer.hint(for: snapshot.root)
        print(hint)
    }
}
