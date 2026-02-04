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

        let datasetConfig = snapshot.root.router.flow.learning.dataset
        let useDataset = datasetPath != nil || !datasetConfig.localPath.isEmpty

        var trainSamples: [LogiQASample] = []
        if useDataset {
            let trainPath = datasetPath ?? datasetConfig.localPath
            if !FileManager.default.fileExists(atPath: trainPath) {
                Diagnostics.fail(
                    "Dataset not found at \(trainPath). Run Tools/logiqa_prepare.swift or specify --dataset PATH.",
                    processID: processID
                )
            }
            do {
                trainSamples = try LogiQADatasetLoader.loadJSONL(
                    from: trainPath,
                    limit: datasetConfig.trainLimit,
                    shuffle: datasetConfig.shuffle,
                    seed: UInt64(datasetConfig.seed)
                )
                LoggingHub.emit(process: "cli.main", level: .info, message: "Loaded LogiQA train samples: \(trainSamples.count)")
            } catch {
                Diagnostics.fail("Failed to load dataset: \(error.localizedDescription)", processID: processID)
            }
        }

        // Fallback sample if dataset not provided
        let exampleText = snapshot.root.capsule.pipelineExampleText.isEmpty ? "Hello, Energetic Router!" : snapshot.root.capsule.pipelineExampleText
        let fallbackInput = exampleText
        let fallbackAnswer = exampleText

        // Checkpoints directory
        let checkpointsDir = URL(fileURLWithPath: snapshot.root.paths.checkpointsDir)
        var allMetrics: [LearningMetrics] = []

        print("Starting learning: epochs=\(epochs), bins=\(flowCfg.bins), target_spike_rate=\(learningCfg.targetSpikeRate)")

        // Training loop
        for epoch in 0..<epochs {
            let pair = makeTrainingPair(
                epoch: epoch,
                samples: trainSamples,
                fallbackInput: fallbackInput,
                fallbackAnswer: fallbackAnswer,
                capsuleConfig: snapshot.root.capsule,
                bins: flowCfg.bins,
                processID: processID
            )
            let metrics = learningLoop.runEpoch(
                epoch: epoch,
                energies: pair.energies,
                targets: pair.targets,
                wrongTargets: pair.wrongTargets,
                optionTargets: pair.optionTargets,
                correctIndex: pair.correctIndex
            )
            allMetrics.append(metrics)

            // Log progress
            LoggingHub.emit(
                process: "trainer.loop",
                level: .info,
                message: "Epoch \(epoch): L=\(String(format: "%.4f", metrics.totalLoss)) L_bins=\(String(format: "%.4f", metrics.binLoss)) L_neg=\(String(format: "%.4f", metrics.negativeLoss)) L_spike=\(String(format: "%.4f", metrics.spikeLoss)) L_boundary=\(String(format: "%.4f", metrics.boundaryLoss)) spike_rate=\(String(format: "%.3f", metrics.spikeRate)) completion=\(String(format: "%.3f", metrics.completionRate)) opt_acc=\(String(format: "%.3f", metrics.optionAccuracy ?? -1))"
            )

            print("Epoch \(epoch)/\(epochs): L=\(String(format: "%.4f", metrics.totalLoss)) bins=\(String(format: "%.4f", metrics.binLoss)) neg=\(String(format: "%.4f", metrics.negativeLoss)) spike=\(String(format: "%.4f", metrics.spikeLoss)) boundary=\(String(format: "%.4f", metrics.boundaryLoss)) opt_acc=\(String(format: "%.3f", metrics.optionAccuracy ?? -1))")

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

    private static func makeTrainingPair(
        epoch: Int,
        samples: [LogiQASample],
        fallbackInput: String,
        fallbackAnswer: String,
        capsuleConfig: ConfigRoot.Capsule,
        bins: Int,
        processID: String
    ) -> (energies: [Float], targets: [Float], wrongTargets: [[Float]], optionTargets: [[Float]], correctIndex: Int) {
        let inputText: String
        let answerText: String
        let wrongAnswers: [String]
        if samples.isEmpty {
            inputText = fallbackInput
            answerText = fallbackAnswer
            wrongAnswers = []
        } else {
            let idx = epoch % samples.count
            let sample = samples[idx]
            inputText = sample.input_text
            answerText = sample.answer_text
            wrongAnswers = sample.wrong_answers
        }

        let inputData = truncateIfNeeded(Data(inputText.utf8), maxBytes: capsuleConfig.maxInputBytes)
        let answerData = truncateIfNeeded(Data(answerText.utf8), maxBytes: capsuleConfig.maxInputBytes)

        let inputEnergies: [Float]
        do {
            let (batch, _) = try CapsuleBridge.makeEnergies(from: inputData, config: capsuleConfig)
            inputEnergies = batch.energies.map { Float($0) }
        } catch {
            Diagnostics.fail("Failed to encode input text: \(error.localizedDescription)", processID: processID)
        }

        let targetEnergies: [Float]
        do {
            let (batch, _) = try CapsuleBridge.makeEnergies(from: answerData, config: capsuleConfig)
            targetEnergies = batch.energies.map { Float($0) }
        } catch {
            Diagnostics.fail("Failed to encode answer text: \(error.localizedDescription)", processID: processID)
        }

        let targets = TargetLoader.fromCapsuleDigits(energies: targetEnergies, bins: bins)

        var wrongTargets: [[Float]] = []
        if !wrongAnswers.isEmpty {
            wrongTargets.reserveCapacity(wrongAnswers.count)
            for wrong in wrongAnswers {
                let data = truncateIfNeeded(Data(wrong.utf8), maxBytes: capsuleConfig.maxInputBytes)
                if let (batch, _) = try? CapsuleBridge.makeEnergies(from: data, config: capsuleConfig) {
                    let e = batch.energies.map { Float($0) }
                    wrongTargets.append(TargetLoader.fromCapsuleDigits(energies: e, bins: bins))
                }
            }
        }

        let optionTargets = [targets] + wrongTargets
        return (inputEnergies, targets, wrongTargets, optionTargets, 0)
    }

    private static func truncateIfNeeded(_ data: Data, maxBytes: Int) -> Data {
        guard data.count > maxBytes else { return data }
        return Data(data.prefix(maxBytes))
    }
}
