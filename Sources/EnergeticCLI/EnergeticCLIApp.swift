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
        let batch: CapsuleBridge.EnergiesBatch
        do {
            (batch, _) = try CapsuleBridge.makeEnergies(from: inputData, config: snapshot.root.capsule)
        } catch {
            Diagnostics.fail("Failed to encode example text: \(error.localizedDescription)", processID: processID)
        }
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
            samples: samples,
            seedLayout: flowCfg.seedLayout,
            seedRadius: Double(flowCfg.seedRadius),
            finalWeightPower: Double(flowCfg.finalWeightPower)
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
        let useDataset = datasetPath != nil || !datasetConfig.localPath.isEmpty || datasetConfig.autoScan

        var trainSamples: [LogiQASample] = []
        var validSamples: [LogiQASample] = []
        if useDataset {
            do {
                let trainPaths = resolveDatasetPaths(
                    explicitPath: datasetPath,
                    fallbackPath: datasetConfig.localPath,
                    autoScan: datasetConfig.autoScan,
                    fileName: "prepared_train.jsonl"
                )
                if trainPaths.isEmpty {
                    Diagnostics.fail(
                        "No dataset files found. Provide --dataset PATH, set learning.dataset.local_path, or enable learning.dataset.auto_scan with Artifacts/Datasets/*/prepared_train.jsonl present.",
                        processID: processID
                    )
                }
                trainSamples = try LogiQADatasetLoader.loadJSONL(
                    from: trainPaths,
                    limit: datasetConfig.trainLimit,
                    shuffle: datasetConfig.shuffle,
                    seed: UInt64(datasetConfig.seed)
                )
                LoggingHub.emit(
                    process: "cli.main",
                    level: .info,
                    message: "Loaded train samples: \(trainSamples.count) from \(trainPaths.count) file(s)"
                )

                let validPaths = resolveDatasetPaths(
                    explicitPath: nil,
                    fallbackPath: datasetConfig.validPath ?? "",
                    autoScan: datasetConfig.autoScan,
                    fileName: "prepared_valid.jsonl"
                )
                if !validPaths.isEmpty {
                    validSamples = try LogiQADatasetLoader.loadJSONL(
                        from: validPaths,
                        limit: datasetConfig.validLimit,
                        shuffle: false,
                        seed: UInt64(datasetConfig.seed &+ 1)
                    )
                    LoggingHub.emit(
                        process: "cli.main",
                        level: .info,
                        message: "Loaded valid samples: \(validSamples.count) from \(validPaths.count) file(s)"
                    )
                }
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
        var startEpoch = 0

        if let latest = CheckpointManager.findLatestCheckpoint(in: checkpointsDir) {
            do {
                let state = try CheckpointManager.load(from: latest)
                if state.epoch + 1 < epochs {
                    learningLoop.loadParameters(state.params.toLearnableParameters())
                    startEpoch = state.epoch + 1
                    LoggingHub.emit(process: "cli.main", level: .info, message: "Resuming from checkpoint \(latest.lastPathComponent) at epoch \(state.epoch)")
                } else {
                    LoggingHub.emit(process: "cli.main", level: .info, message: "Latest checkpoint epoch \(state.epoch) ≥ requested epochs \(epochs). Starting from 0.")
                }
            } catch {
                LoggingHub.emit(process: "cli.main", level: .warn, message: "Failed to load checkpoint \(latest.lastPathComponent): \(error.localizedDescription)")
            }
        }

        print("Starting learning: epochs=\(epochs), bins=\(flowCfg.bins), target_spike_rate=\(learningCfg.targetSpikeRate)")

        // Training loop
        let evalEvery = max(1, snapshot.root.router.flow.learning.evalEvery)
        let logSilence = snapshot.root.router.flow.learning.logSilence
        let logEvery = max(1, snapshot.root.router.flow.learning.logEvery)
        if logSilence {
            LoggingHub.setSuppressStdout(true)
        }
        var trainCache: [String: EncodedSample] = [:]
        var validCache: [String: EncodedSample] = [:]
        if !validSamples.isEmpty {
            validCache = buildCache(samples: validSamples, capsuleConfig: snapshot.root.capsule, bins: flowCfg.bins, processID: processID)
        }

        // Reuse a single eval loop to avoid recreating Metal context on each evaluation
        let evalLoop: FlowLearningLoop? = validSamples.isEmpty
            ? nil
            : FlowLearningLoop(
                flowConfig: flowCfg,
                learningConfig: learningCfg,
                seed: UInt64(snapshot.root.seed) &+ 0xE1A1_0001
            )

        // UI learning payloads (and the slow-path tracing they require) are only useful when UI is enabled.
        // When UI is disabled/headless, keep training on the fast path.
        let emitUILogs = snapshot.root.ui.enabled && !snapshot.root.ui.headlessOverride

        for epoch in startEpoch..<epochs {
            let pair = makeTrainingPair(
                index: epoch,
                samples: trainSamples,
                fallbackInput: fallbackInput,
                fallbackAnswer: fallbackAnswer,
                capsuleConfig: snapshot.root.capsule,
                bins: flowCfg.bins,
                processID: processID,
                cache: &trainCache
            )
            let metrics = learningLoop.runEpoch(
                epoch: epoch,
                energies: pair.energies,
                targets: pair.targets,
                wrongTargets: pair.wrongTargets,
                optionTargets: pair.optionTargets,
                correctIndex: pair.correctIndex,
                inputText: pair.inputText,
                answerText: pair.answerText,
                emitLog: emitUILogs
            )
            allMetrics.append(metrics)

            if epoch % logEvery == 0 {
                LoggingHub.emit(
                    process: "trainer.loop",
                    level: .info,
                    message: "Epoch \(epoch): L=\(String(format: "%.4f", metrics.totalLoss)) L_bins=\(String(format: "%.4f", metrics.binLoss)) L_neg=\(String(format: "%.4f", metrics.negativeLoss)) L_spike=\(String(format: "%.4f", metrics.spikeLoss)) L_boundary=\(String(format: "%.4f", metrics.boundaryLoss)) spike_rate=\(String(format: "%.3f", metrics.spikeRate)) completion=\(String(format: "%.3f", metrics.completionRate)) opt_acc=\(String(format: "%.3f", metrics.optionAccuracy ?? -1))"
                )
                if !logSilence {
                    print("Epoch \(epoch)/\(epochs): L=\(String(format: "%.4f", metrics.totalLoss)) bins=\(String(format: "%.4f", metrics.binLoss)) neg=\(String(format: "%.4f", metrics.negativeLoss)) spike=\(String(format: "%.4f", metrics.spikeLoss)) boundary=\(String(format: "%.4f", metrics.boundaryLoss)) opt_acc=\(String(format: "%.3f", metrics.optionAccuracy ?? -1))")
                }
            }

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

            if !validSamples.isEmpty && ((epoch + 1) % evalEvery == 0 || epoch == epochs - 1) {
                guard let evalLoop else {
                    continue
                }
                let evalMetrics = evaluateSamples(
                    epoch: epoch,
                    samples: validSamples,
                    evalLoop: evalLoop,
                    capsuleConfig: snapshot.root.capsule,
                    bins: flowCfg.bins,
                    processID: processID,
                    cache: &validCache,
                    currentParams: learningLoop.getParameters()
                )
                LoggingHub.emit(
                    process: "trainer.eval",
                    level: .info,
                    message: "Eval epoch \(epoch): L=\(String(format: "%.4f", evalMetrics.totalLoss)) bins=\(String(format: "%.4f", evalMetrics.binLoss)) neg=\(String(format: "%.4f", evalMetrics.negativeLoss)) acc=\(String(format: "%.3f", evalMetrics.optionAccuracy ?? -1))"
                )
                if !logSilence {
                    print("Eval \(epoch): L=\(String(format: "%.4f", evalMetrics.totalLoss)) bins=\(String(format: "%.4f", evalMetrics.binLoss)) neg=\(String(format: "%.4f", evalMetrics.negativeLoss)) acc=\(String(format: "%.3f", evalMetrics.optionAccuracy ?? -1))")
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

        Config (learning):
          log_every          Emit CLI progress logs every N epochs
          log_every_ui       Emit UI payloads every N epochs

        Environment:
          SNN_CONFIG_PATH    Path to config YAML (default: Configs/baseline.yaml)

        Examples:
          energetic-cli
          energetic-cli run
          energetic-cli learn --epochs 100 --save-every 20
        """)
    }

    private struct EncodedSample {
        let energies: [Float]
        let targets: [Float]
        let wrongTargets: [[Float]]
        let optionTargets: [[Float]]
        let correctIndex: Int
        let inputText: String
        let answerText: String
    }

    private static func buildCache(
        samples: [LogiQASample],
        capsuleConfig: ConfigRoot.Capsule,
        bins: Int,
        processID: String
    ) -> [String: EncodedSample] {
        guard !samples.isEmpty else { return [:] }
        var cache: [String: EncodedSample] = [:]
        cache.reserveCapacity(samples.count)
        for (idx, sample) in samples.enumerated() {
            _ = makeTrainingPair(
                index: idx,
                samples: [sample],
                fallbackInput: sample.input_text,
                fallbackAnswer: sample.answer_text,
                capsuleConfig: capsuleConfig,
                bins: bins,
                processID: processID,
                cache: &cache
            )
        }
        return cache
    }

    private static func makeTrainingPair(
        index: Int,
        samples: [LogiQASample],
        fallbackInput: String,
        fallbackAnswer: String,
        capsuleConfig: ConfigRoot.Capsule,
        bins: Int,
        processID: String,
        cache: inout [String: EncodedSample]
    ) -> (energies: [Float], targets: [Float], wrongTargets: [[Float]], optionTargets: [[Float]], correctIndex: Int, inputText: String, answerText: String) {
        let inputText: String
        let answerText: String
        let wrongAnswers: [String]
        let sampleID: String
        if samples.isEmpty {
            inputText = fallbackInput
            answerText = fallbackAnswer
            wrongAnswers = []
            sampleID = "fallback"
        } else {
            let idx = index % samples.count
            let sample = samples[idx]
            inputText = sample.input_text
            answerText = sample.answer_text
            wrongAnswers = sample.wrong_answers
            sampleID = sample.id
        }

        if let cached = cache[sampleID] {
            return (cached.energies, cached.targets, cached.wrongTargets, cached.optionTargets, cached.correctIndex, cached.inputText, cached.answerText)
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
        let encoded = EncodedSample(
            energies: inputEnergies,
            targets: targets,
            wrongTargets: wrongTargets,
            optionTargets: optionTargets,
            correctIndex: 0,
            inputText: inputText,
            answerText: answerText
        )
        cache[sampleID] = encoded
        return (inputEnergies, targets, wrongTargets, optionTargets, 0, inputText, answerText)
    }

    private static func evaluateSamples(
        epoch: Int,
        samples: [LogiQASample],
        evalLoop: FlowLearningLoop,
        capsuleConfig: ConfigRoot.Capsule,
        bins: Int,
        processID: String,
        cache: inout [String: EncodedSample],
        currentParams: LearnableParameters
    ) -> LearningMetrics {
        evalLoop.loadParameters(currentParams)

        var totalLoss: Float = 0
        var binLoss: Float = 0
        var negLoss: Float = 0
        var accSum: Float = 0
        var accCount: Float = 0

        for (i, sample) in samples.enumerated() {
            let pair: (energies: [Float], targets: [Float], wrongTargets: [[Float]], optionTargets: [[Float]], correctIndex: Int, inputText: String, answerText: String)
            if let cached = cache[sample.id] {
                pair = (cached.energies, cached.targets, cached.wrongTargets, cached.optionTargets, cached.correctIndex, cached.inputText, cached.answerText)
            } else {
                pair = makeTrainingPair(
                    index: i,
                    samples: [sample],
                    fallbackInput: sample.input_text,
                    fallbackAnswer: sample.answer_text,
                    capsuleConfig: capsuleConfig,
                    bins: bins,
                    processID: processID,
                    cache: &cache
                )
            }
            let metrics = evalLoop.runEpoch(
                epoch: epoch,
                energies: pair.energies,
                targets: pair.targets,
                wrongTargets: pair.wrongTargets,
                optionTargets: pair.optionTargets,
                correctIndex: pair.correctIndex,
                inputText: pair.inputText,
                answerText: pair.answerText,
                applyUpdates: false,
                emitLog: false
            )
            totalLoss += metrics.totalLoss
            binLoss += metrics.binLoss
            negLoss += metrics.negativeLoss
            if let acc = metrics.optionAccuracy {
                accSum += acc
                accCount += 1
            }
        }

        let count = max(1, samples.count)
        return LearningMetrics(
            epoch: epoch,
            totalLoss: totalLoss / Float(count),
            binLoss: binLoss / Float(count),
            negativeLoss: negLoss / Float(count),
            spikeLoss: 0,
            boundaryLoss: 0,
            spikeRate: 0,
            completionRate: 0,
            meanRadialMiss: 0,
            nonzeroBins: 0,
            yHatStats: .init(mean: 0, variance: 0, min: 0, max: 0),
            paramDeltas: .init(gainMean: 0, gainVariance: 0, lifThreshold: 0, radialBias: 0, spikeKick: 0),
            optionAccuracy: accCount > 0 ? accSum / accCount : nil
        )
    }

    private static func truncateIfNeeded(_ data: Data, maxBytes: Int) -> Data {
        guard data.count > maxBytes else { return data }
        return Data(data.prefix(maxBytes))
    }

    private static func resolveDatasetPaths(
        explicitPath: String?,
        fallbackPath: String,
        autoScan: Bool,
        fileName: String
    ) -> [String] {
        if let explicitPath, !explicitPath.isEmpty {
            return [explicitPath]
        }
        if !fallbackPath.isEmpty {
            return [fallbackPath]
        }
        guard autoScan else { return [] }
        return discoverPreparedDatasets(root: "Artifacts/Datasets", fileName: fileName)
    }

    private static func discoverPreparedDatasets(root: String, fileName: String) -> [String] {
        let rootURL = URL(fileURLWithPath: root)
        let fm = FileManager.default
        guard fm.fileExists(atPath: rootURL.path) else { return [] }
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var paths: [String] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == fileName {
                paths.append(url.path)
            }
        }
        return paths.sorted()
    }
}
