import EnergeticCore
import Foundation
import SharedInfrastructure
import CapsuleCore

@main
struct EnergeticCLI {
    static func main() {
        let args = CommandLine.arguments

        // Check for subcommand
        if args.count > 1 {
            let command = args[1]
            switch command {
            case "learn":
                runLearn(args: Array(args.dropFirst(2)))
                return
            case "run":
                // Default run command (existing behavior)
                break
            case "--help", "-h", "help":
                printHelp()
                return
            default:
                print("Unknown command: \(command)")
                print("Use 'energetic-cli help' for usage information.")
                return
            }
        }

        // Default: run flow simulation
        runDefaultSimulation()
    }

    static func runDefaultSimulation() {
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

    static func runLearn(args: [String]) {
        let processID = (try? ProcessRegistry.resolve("cli.main")) ?? "cli.main"
        let env = ProcessInfo.processInfo.environment
        let configURL = env["SNN_CONFIG_PATH"].map { URL(fileURLWithPath: $0) }

        // Load config
        let snapshot: ConfigSnapshot
        do {
            snapshot = try ConfigCenter.load(url: configURL)
            ProcessRegistry.configure(from: snapshot)
            try LoggingHub.configure(from: snapshot)
        } catch {
            Diagnostics.fail("Failed to load config: \(error.localizedDescription)", processID: processID)
        }

        // Check if learning is enabled
        guard snapshot.root.router.flow.learning.enabled else {
            print("Learning is disabled in config. Set router.flow.learning.enabled to true.")
            return
        }

        LoggingHub.emit(process: "cli.main", level: .info, message: "Starting learning pipeline")

        // Parse arguments
        var epochs = snapshot.root.router.flow.learning.epochs
        var saveEvery = 10
        var datasetPath: String?

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--epochs":
                if i + 1 < args.count, let value = Int(args[i + 1]) {
                    epochs = value
                    i += 1
                }
            case "--save-every":
                if i + 1 < args.count, let value = Int(args[i + 1]) {
                    saveEvery = value
                    i += 1
                }
            case "--dataset":
                if i + 1 < args.count {
                    datasetPath = args[i + 1]
                    i += 1
                }
            default:
                print("Unknown argument: \(arg)")
            }
            i += 1
        }

        // Create learning configuration
        let flowCfg = FlowConfig.from(snapshot.root.router)
        let learningCfg = LearningConfig.from(snapshot.root.router.flow, radius: Float(snapshot.root.router.flow.radius))

        // Create learning loop
        let learningLoop = FlowLearningLoop(
            flowConfig: flowCfg,
            learningConfig: learningCfg,
            seed: UInt64(snapshot.root.seed)
        )

        // Get input energies from capsule
        let exampleText = snapshot.root.capsule.pipelineExampleText.isEmpty ? "Hello, Energetic Router!" : snapshot.root.capsule.pipelineExampleText
        let inputData = Data(exampleText.utf8)
        let (batch, _) = try! CapsuleBridge.makeEnergies(from: inputData, config: snapshot.root.capsule)
        let energies = batch.energies.map { Float($0) }

        // Load or create targets
        let targets: [Float]
        let targetConfig = snapshot.root.router.flow.learning.targets
        do {
            if targetConfig.type == "capsule-digits" {
                targets = TargetLoader.fromCapsuleDigits(energies: energies, bins: flowCfg.bins)
                LoggingHub.emit(process: "cli.main", level: .info, message: "Using capsule-digits targets")
            } else if let path = targetConfig.path {
                if path.hasSuffix(".json") {
                    targets = try TargetLoader.fromJSONFile(path: path, bins: flowCfg.bins)
                } else {
                    targets = try TargetLoader.fromCSVFile(path: path, bins: flowCfg.bins)
                }
                LoggingHub.emit(process: "cli.main", level: .info, message: "Loaded targets from \(path)")
            } else {
                Diagnostics.fail("Target type 'file' requires a path", processID: processID)
            }
        } catch {
            Diagnostics.fail("Failed to load targets: \(error.localizedDescription)", processID: processID)
        }

        // Checkpoints directory
        let checkpointsDir = URL(fileURLWithPath: snapshot.root.paths.checkpointsDir)
        var allMetrics: [LearningMetrics] = []

        print("Starting learning: epochs=\(epochs), bins=\(flowCfg.bins), target_spike_rate=\(learningCfg.targetSpikeRate)")

        // Training loop
        for epoch in 0..<epochs {
            let metrics = learningLoop.runEpoch(epoch: epoch, energies: energies, targets: targets)
            allMetrics.append(metrics)

            // Log progress
            LoggingHub.emit(
                process: "trainer.loop",
                level: .info,
                message: "Epoch \(epoch): L=\(String(format: "%.4f", metrics.totalLoss)) L_bins=\(String(format: "%.4f", metrics.binLoss)) L_spike=\(String(format: "%.4f", metrics.spikeLoss)) L_boundary=\(String(format: "%.4f", metrics.boundaryLoss)) spike_rate=\(String(format: "%.3f", metrics.spikeRate)) completion=\(String(format: "%.3f", metrics.completionRate))"
            )

            print("Epoch \(epoch)/\(epochs): L=\(String(format: "%.4f", metrics.totalLoss)) bins=\(String(format: "%.4f", metrics.binLoss)) spike=\(String(format: "%.4f", metrics.spikeLoss)) boundary=\(String(format: "%.4f", metrics.boundaryLoss))")

            // Save checkpoint periodically
            if (epoch + 1) % saveEvery == 0 || epoch == epochs - 1 {
                let params = learningLoop.getParameters()
                let state = RouterLearningState(
                    epoch: epoch,
                    params: .init(from: params),
                    metrics: metrics
                )
                do {
                    try CheckpointManager.save(state: state, to: checkpointsDir)
                    LoggingHub.emit(process: "cli.main", level: .debug, message: "Saved checkpoint at epoch \(epoch)")
                } catch {
                    LoggingHub.emit(process: "cli.main", level: .warn, message: "Failed to save checkpoint: \(error.localizedDescription)")
                }
            }
        }

        // Save summary
        do {
            try CheckpointManager.saveSummary(metrics: allMetrics, to: checkpointsDir)
            print("Learning complete. Summary saved to \(checkpointsDir.path)/learning_summary.json")
        } catch {
            LoggingHub.emit(process: "cli.main", level: .warn, message: "Failed to save summary: \(error.localizedDescription)")
        }

        print("Final parameters:")
        let finalParams = learningLoop.getParameters()
        print("  LIF threshold: \(String(format: "%.4f", finalParams.lifThreshold))")
        print("  Radial bias: \(String(format: "%.4f", finalParams.radialBias))")
        print("  Spike kick: \(String(format: "%.4f", finalParams.spikeKick))")
        print("  Gain mean: \(String(format: "%.4f", finalParams.gains.reduce(0, +) / Float(finalParams.gains.count)))")
    }

    static func printHelp() {
        print("""
        energetic-cli - Flow router simulation and learning

        Usage:
          energetic-cli [command] [options]

        Commands:
          run       Run flow simulation (default)
          learn     Run learning pipeline
          help      Show this help message

        Learn Options:
          --epochs N         Number of training epochs (default: from config)
          --save-every K     Save checkpoint every K epochs (default: 10)
          --dataset PATH     Path to dataset file (optional)

        Environment:
          SNN_CONFIG_PATH    Path to config YAML (default: Configs/baseline.yaml)

        Examples:
          energetic-cli
          energetic-cli run
          energetic-cli learn --epochs 100 --save-every 20
        """)
    }
}
