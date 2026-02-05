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
            case "precompute-dataset":
                runPrecomputeDataset(args: Array(args.dropFirst(2)))
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
        let inputHistogram = HistogramBuilder.fromEnergies(batch.energies, bins: flowCfg.bins)
        precondition(inputHistogram.count == flowCfg.bins, "inputHistogram must match bins")
        let outputHistogram = bins
        let normalizedInput = normalizeBins(inputHistogram)
        let normalizedOutput = normalizeBins(outputHistogram)
        let histogramMetrics: ConfigPipelineSnapshot.FlowSnapshot.HistogramMetrics?
        if normalizedInput.count == normalizedOutput.count, !normalizedInput.isEmpty {
            let values = HistogramMetrics.compute(normalizedInput, normalizedOutput)
            histogramMetrics = .init(l1: Double(values.l1), l2: Double(values.l2), cosine: values.cosine.map(Double.init))
        } else {
            histogramMetrics = nil
        }

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
            inputHistogram: inputHistogram.map { Double($0) },
            outputHistogram: outputHistogram.map { Double($0) },
            histogramMetrics: histogramMetrics,
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

        let histogramConfig = snapshot.root.histogramLanguage
        let retriever: HistogramRetriever?
        if histogramConfig.enabled && histogramConfig.retrieval.enabled {
            let metricName = histogramConfig.metrics.first?.lowercased() ?? "l1"
            let metric = HistogramRetrievalMetric(rawValue: metricName) ?? .l1
            do {
                let corpus = try HistogramRetriever.loadCorpus(from: histogramConfig.retrieval.corpusPath, bins: flowCfg.bins)
                retriever = try HistogramRetriever(entries: corpus, metric: metric, topK: histogramConfig.retrieval.topK, bins: flowCfg.bins)
                LoggingHub.emit(process: "cli.main", level: .info, message: "Histogram retrieval enabled: metric=\(metric.rawValue) top_k=\(histogramConfig.retrieval.topK)")
            } catch {
                Diagnostics.fail("Failed to load retrieval corpus: \(error.localizedDescription)", processID: processID)
            }
        } else {
            retriever = nil
        }

        // Create learning loop
        let learningLoop = FlowLearningLoop(
            flowConfig: flowCfg,
            learningConfig: learningCfg,
            seed: UInt64(snapshot.root.seed),
            retriever: retriever
        )

        let datasetConfig = snapshot.root.router.flow.learning.dataset
        let cacheMode = datasetConfig.cacheMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let useDataset = datasetPath != nil || !datasetConfig.localPath.isEmpty || datasetConfig.autoScan

        var trainSamples: [LogiQASample] = []
        var validSamples: [LogiQASample] = []
        var precomputedTrain: [PrecomputedDataset.Sample] = []
        var precomputedValid: [PrecomputedDataset.Sample] = []
        if useDataset {
            do {
                if cacheMode == "precomputed" {
                    let trainPaths = resolveDatasetPaths(
                        explicitPath: datasetPath,
                        fallbackPath: datasetConfig.localPath,
                        autoScan: datasetConfig.autoScan,
                        fileName: "precomputed_train.jsonl"
                    )
                    if trainPaths.isEmpty {
                        Diagnostics.fail(
                            "No precomputed dataset files found. Provide --dataset PATH, set learning.dataset.local_path, or enable learning.dataset.auto_scan with Artifacts/Datasets/*/precomputed_train.jsonl present.",
                            processID: processID
                        )
                    }
                    precomputedTrain = try PrecomputedDataset.loadJSONL(
                        paths: trainPaths,
                        config: snapshot.root.capsule,
                        bins: flowCfg.bins
                    )
                    if datasetConfig.shuffle, precomputedTrain.count > 1 {
                        shuffleInPlace(&precomputedTrain, seed: UInt64(datasetConfig.seed))
                    }
                    if datasetConfig.trainLimit > 0 && precomputedTrain.count > datasetConfig.trainLimit {
                        precomputedTrain = Array(precomputedTrain.prefix(datasetConfig.trainLimit))
                    }
                    LoggingHub.emit(
                        process: "cli.main",
                        level: .info,
                        message: "Loaded precomputed train samples: \(precomputedTrain.count) from \(trainPaths.count) file(s)"
                    )

                    let validPaths = resolveDatasetPaths(
                        explicitPath: nil,
                        fallbackPath: datasetConfig.validPath ?? "",
                        autoScan: datasetConfig.autoScan,
                        fileName: "precomputed_valid.jsonl"
                    )
                    if !validPaths.isEmpty {
                        precomputedValid = try PrecomputedDataset.loadJSONL(
                            paths: validPaths,
                            config: snapshot.root.capsule,
                            bins: flowCfg.bins
                        )
                        if datasetConfig.validLimit > 0 && precomputedValid.count > datasetConfig.validLimit {
                            precomputedValid = Array(precomputedValid.prefix(datasetConfig.validLimit))
                        }
                        LoggingHub.emit(
                            process: "cli.main",
                            level: .info,
                            message: "Loaded precomputed valid samples: \(precomputedValid.count) from \(validPaths.count) file(s)"
                        )
                    }
                } else {
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
        if cacheMode != "precomputed", !validSamples.isEmpty {
            validCache = buildCache(samples: validSamples, capsuleConfig: snapshot.root.capsule, bins: flowCfg.bins, processID: processID)
        }

        // Reuse a single eval loop to avoid recreating Metal context on each evaluation
        let evalLoop: FlowLearningLoop? = (cacheMode == "precomputed" ? precomputedValid.isEmpty : validSamples.isEmpty)
            ? nil
            : FlowLearningLoop(
                flowConfig: flowCfg,
                learningConfig: learningCfg,
                seed: UInt64(snapshot.root.seed) &+ 0xE1A1_0001,
                retriever: retriever
            )

        // UI learning payloads (and the slow-path tracing they require) are only useful when UI is enabled.
        // When UI is disabled/headless, keep training on the fast path.
        let emitUILogs = snapshot.root.ui.enabled && !snapshot.root.ui.headlessOverride

        for epoch in startEpoch..<epochs {
            let metrics: LearningMetrics
            if cacheMode == "precomputed" {
                guard !precomputedTrain.isEmpty else {
                    Diagnostics.fail("Precomputed dataset is empty. Run energetic-cli precompute-dataset to generate it.", processID: processID)
                }
                let sample = precomputedTrain[epoch % precomputedTrain.count]
                metrics = learningLoop.runEpoch(
                    epoch: epoch,
                    energies: sample.energies,
                    targets: sample.targets,
                    wrongTargets: sample.wrongTargets,
                    optionTargets: sample.optionTargets,
                    correctIndex: sample.correctIndex,
                    inputText: nil,
                    answerText: nil,
                    emitLog: emitUILogs,
                    targetsNormOverride: sample.targetsNorm,
                    wrongTargetsNormOverride: sample.wrongTargetsNorm
                )
            } else {
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
                metrics = learningLoop.runEpoch(
                    epoch: epoch,
                    energies: pair.energies,
                    targets: pair.targets,
                    wrongTargets: pair.wrongTargets,
                    optionTargets: pair.optionTargets,
                    correctIndex: pair.correctIndex,
                    inputText: pair.inputText,
                    answerText: pair.answerText,
                    emitLog: emitUILogs,
                    targetsNormOverride: pair.targetsNorm,
                    wrongTargetsNormOverride: pair.wrongTargetsNorm
                )
            }
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

            if (cacheMode == "precomputed" ? !precomputedValid.isEmpty : !validSamples.isEmpty)
                && ((epoch + 1) % evalEvery == 0 || epoch == epochs - 1) {
                guard let evalLoop else {
                    continue
                }
                let evalMetrics: LearningMetrics
                if cacheMode == "precomputed" {
                    evalMetrics = evaluatePrecomputedSamples(
                        epoch: epoch,
                        samples: precomputedValid,
                        evalLoop: evalLoop,
                        currentParams: learningLoop.getParameters()
                    )
                } else {
                    evalMetrics = evaluateSamples(
                        epoch: epoch,
                        samples: validSamples,
                        evalLoop: evalLoop,
                        capsuleConfig: snapshot.root.capsule,
                        bins: flowCfg.bins,
                        processID: processID,
                        cache: &validCache,
                        currentParams: learningLoop.getParameters()
                    )
                }
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
          precompute-dataset  Precompute dataset into base64 JSONL for fast training
          help      Show this help message

        Learn Options:
          --epochs N         Number of training epochs (default: from config)
          --save-every K     Save checkpoint every K epochs (default: 10)
          --dataset PATH     Path to dataset file (optional)
        Precompute Options:
          --input PATH       Prepared dataset file or directory
          --output DIR       Output directory for precomputed files
          --all              Scan Datasets for *_train.jsonl / *_valid.jsonl and precompute all
          --update-retrieval Append missing target histograms to histogram_language.retrieval.corpus_path
          --jobs N           Parallel workers (default: active CPU cores)
          --resume           Continue existing precomputed file (skip already written ids)

        Config (learning):
          log_every          Emit CLI progress logs every N epochs
          log_every_ui       Emit UI payloads every N epochs

        Environment:
          SNN_CONFIG_PATH    Path to config YAML (default: Configs/baseline.yaml)

        Examples:
          energetic-cli
          energetic-cli run
          energetic-cli learn --epochs 100 --save-every 20
          energetic-cli precompute-dataset --input Artifacts/Datasets/LogiQA/prepared --output Artifacts/Datasets/LogiQA/precomputed
        """)
    }

    private struct EncodedSample {
        let energies: [Float]
        let targets: [Float]
        let targetsNorm: [Float]
        let wrongTargets: [[Float]]
        let wrongTargetsNorm: [[Float]]
        let optionTargets: [[Float]]
        let correctIndex: Int
        let inputText: String
        let answerText: String
    }

    private static func normalizeBins(_ bins: [Float]) -> [Float] {
        let sum = bins.reduce(0, +)
        guard sum > 0 else { return bins }
        return bins.map { $0 / sum }
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
    ) -> (energies: [Float], targets: [Float], targetsNorm: [Float], wrongTargets: [[Float]], wrongTargetsNorm: [[Float]], optionTargets: [[Float]], correctIndex: Int, inputText: String, answerText: String) {
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
            return (
                cached.energies,
                cached.targets,
                cached.targetsNorm,
                cached.wrongTargets,
                cached.wrongTargetsNorm,
                cached.optionTargets,
                cached.correctIndex,
                cached.inputText,
                cached.answerText
            )
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
        let targetsNorm = normalizeBins(targets)

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
        let wrongTargetsNorm = wrongTargets.map { normalizeBins($0) }

        let optionTargets = [targets] + wrongTargets
        let encoded = EncodedSample(
            energies: inputEnergies,
            targets: targets,
            targetsNorm: targetsNorm,
            wrongTargets: wrongTargets,
            wrongTargetsNorm: wrongTargetsNorm,
            optionTargets: optionTargets,
            correctIndex: 0,
            inputText: inputText,
            answerText: answerText
        )
        cache[sampleID] = encoded
        return (inputEnergies, targets, targetsNorm, wrongTargets, wrongTargetsNorm, optionTargets, 0, inputText, answerText)
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
            let pair: (energies: [Float], targets: [Float], targetsNorm: [Float], wrongTargets: [[Float]], wrongTargetsNorm: [[Float]], optionTargets: [[Float]], correctIndex: Int, inputText: String, answerText: String)
            if let cached = cache[sample.id] {
                pair = (
                    cached.energies,
                    cached.targets,
                    cached.targetsNorm,
                    cached.wrongTargets,
                    cached.wrongTargetsNorm,
                    cached.optionTargets,
                    cached.correctIndex,
                    cached.inputText,
                    cached.answerText
                )
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
                emitLog: false,
                targetsNormOverride: pair.targetsNorm,
                wrongTargetsNormOverride: pair.wrongTargetsNorm
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

    private static func evaluatePrecomputedSamples(
        epoch: Int,
        samples: [PrecomputedDataset.Sample],
        evalLoop: FlowLearningLoop,
        currentParams: LearnableParameters
    ) -> LearningMetrics {
        evalLoop.loadParameters(currentParams)

        var totalLoss: Float = 0
        var binLoss: Float = 0
        var negLoss: Float = 0
        var accSum: Float = 0
        var accCount: Float = 0

        for sample in samples {
            let metrics = evalLoop.runEpoch(
                epoch: epoch,
                energies: sample.energies,
                targets: sample.targets,
                wrongTargets: sample.wrongTargets,
                optionTargets: sample.optionTargets,
                correctIndex: sample.correctIndex,
                inputText: nil,
                answerText: nil,
                applyUpdates: false,
                emitLog: false,
                targetsNormOverride: sample.targetsNorm,
                wrongTargetsNormOverride: sample.wrongTargetsNorm
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

    private struct PrecomputeOptions {
        var inputPath: String = ""
        var outputDir: String = ""
        var trainLimit: Int?
        var validLimit: Int?
        var shuffle: Bool?
        var seed: UInt64?
        var validPath: String = ""
        var all: Bool = false
        var updateRetrieval: Bool = false
        var jobs: Int?
        var resume: Bool = false
    }

    private static func parsePrecomputeArgs(_ args: [String]) -> PrecomputeOptions {
        var opts = PrecomputeOptions()
        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--input":
                if i + 1 < args.count { opts.inputPath = args[i + 1]; i += 1 }
            case "--output":
                if i + 1 < args.count { opts.outputDir = args[i + 1]; i += 1 }
            case "--train-limit":
                if i + 1 < args.count { opts.trainLimit = Int(args[i + 1]); i += 1 }
            case "--valid-limit":
                if i + 1 < args.count { opts.validLimit = Int(args[i + 1]); i += 1 }
            case "--no-shuffle":
                opts.shuffle = false
            case "--seed":
                if i + 1 < args.count { opts.seed = UInt64(args[i + 1]); i += 1 }
            case "--valid":
                if i + 1 < args.count { opts.validPath = args[i + 1]; i += 1 }
            case "--all":
                opts.all = true
            case "--update-retrieval":
                opts.updateRetrieval = true
            case "--jobs":
                if i + 1 < args.count { opts.jobs = Int(args[i + 1]); i += 1 }
            case "--resume":
                opts.resume = true
            default:
                break
            }
            i += 1
        }
        return opts
    }

    static func runPrecomputeDataset(args: [String]) {
        let processID = (try? ProcessRegistry.resolve("cli.main")) ?? "cli.main"
        let env = ProcessInfo.processInfo.environment
        let configURL = env["SNN_CONFIG_PATH"].map { URL(fileURLWithPath: $0) }

        let opts = parsePrecomputeArgs(args)

        // Load config
        let snapshot: ConfigSnapshot
        do {
            snapshot = try ConfigCenter.load(url: configURL)
            ProcessRegistry.configure(from: snapshot)
            try LoggingHub.configure(from: snapshot)
        } catch {
            Diagnostics.fail("Failed to load config: \(error.localizedDescription)", processID: processID)
        }

        let datasetConfig = snapshot.root.router.flow.learning.dataset
        let inputPath = opts.inputPath.isEmpty ? datasetConfig.localPath : opts.inputPath

        let trainLimit = opts.trainLimit ?? datasetConfig.trainLimit
        let validLimit = opts.validLimit ?? datasetConfig.validLimit
        let shuffle = opts.shuffle ?? datasetConfig.shuffle
        let seed = opts.seed ?? UInt64(datasetConfig.seed)
        let jobs = max(1, opts.jobs ?? ProcessInfo.processInfo.activeProcessorCount)

        let flowCfg = FlowConfig.from(snapshot.root.router)
        let metadata = PrecomputedDataset.makeMetadata(config: snapshot.root.capsule, bins: flowCfg.bins)
        let encoder = JSONEncoder()

        let histogramConfig = snapshot.root.histogramLanguage
        let retrievalUpdater: RetrievalCorpusUpdater?
        if opts.updateRetrieval {
            guard histogramConfig.enabled else {
                Diagnostics.fail("histogram_language.enabled must be true when using --update-retrieval", processID: processID)
            }
            guard histogramConfig.retrieval.enabled else {
                Diagnostics.fail("histogram_language.retrieval.enabled must be true when using --update-retrieval", processID: processID)
            }
            let path = histogramConfig.retrieval.corpusPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else {
                Diagnostics.fail("histogram_language.retrieval.corpus_path is required when using --update-retrieval", processID: processID)
            }
            do {
                retrievalUpdater = try RetrievalCorpusUpdater(path: path, bins: flowCfg.bins, processID: processID)
            } catch {
                Diagnostics.fail("Failed to open retrieval corpus: \(error.localizedDescription)", processID: processID)
            }
        } else {
            retrievalUpdater = nil
        }
        defer {
            retrievalUpdater?.close()
        }

        if opts.all {
            let rootPath = inputPath.isEmpty ? "Artifacts/Datasets" : inputPath
            let rootURL = URL(fileURLWithPath: rootPath)
            let groups = discoverPreparedDatasetGroups(root: rootURL)
            if groups.isEmpty {
                Diagnostics.fail("No *_train.jsonl found under \(rootPath).", processID: processID)
            }
            for (idx, group) in groups.enumerated() {
                do {
                    let trainSamples = try LogiQADatasetLoader.loadJSONL(
                        from: [group.trainPath],
                        limit: trainLimit,
                        shuffle: shuffle,
                        seed: seed &+ UInt64(idx)
                    )
                    let validSamples: [LogiQASample]
                    if let validPath = group.validPath {
                        validSamples = try LogiQADatasetLoader.loadJSONL(
                            from: [validPath],
                            limit: validLimit,
                            shuffle: false,
                            seed: (seed &+ 1) &+ UInt64(idx)
                        )
                    } else {
                        validSamples = []
                    }

            let outputDir = outputDirForAll(group: group)
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            let trainOut = outputDir.appendingPathComponent("precomputed_train.jsonl")
            let validOut = outputDir.appendingPathComponent("precomputed_valid.jsonl")

                    try writePrecomputedFile(
                        metadata: metadata,
                        samples: trainSamples,
                        outputURL: trainOut,
                        capsuleConfig: snapshot.root.capsule,
                        bins: flowCfg.bins,
                        processID: processID,
                        encoder: encoder,
                        retrievalUpdater: retrievalUpdater,
                        jobs: jobs,
                        resume: opts.resume
                    )
                    if !validSamples.isEmpty {
                        try writePrecomputedFile(
                            metadata: metadata,
                            samples: validSamples,
                            outputURL: validOut,
                            capsuleConfig: snapshot.root.capsule,
                            bins: flowCfg.bins,
                            processID: processID,
                            encoder: encoder,
                            retrievalUpdater: retrievalUpdater,
                            jobs: jobs,
                            resume: opts.resume
                        )
                    }

                    print("Precomputed train: \(trainSamples.count) -> \(trainOut.path)")
                    if !validSamples.isEmpty {
                        print("Precomputed valid: \(validSamples.count) -> \(validOut.path)")
                    }
                } catch {
                    Diagnostics.fail("Failed to precompute dataset at \(group.trainPath): \(error.localizedDescription)", processID: processID)
                }
            }
            if let updater = retrievalUpdater {
                print("Retrieval corpus updated: +\(updater.appended) entries -> \(updater.corpusPath)")
            }
            return
        }

        guard !inputPath.isEmpty else {
            Diagnostics.fail("Provide --input PATH or set learning.dataset.local_path to prepared dataset location.", processID: processID)
        }

        let outputDir = opts.outputDir.isEmpty ? "Artifacts/Datasets/Precomputed" : opts.outputDir
        let outputURL = URL(fileURLWithPath: outputDir)

        let inputURL = URL(fileURLWithPath: inputPath)
        let isDir = (try? inputURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

        let trainPaths: [String]
        let validPaths: [String]
        if isDir {
            let trainURL = inputURL.appendingPathComponent("prepared_train.jsonl")
            let validURL = inputURL.appendingPathComponent("prepared_valid.jsonl")
            trainPaths = FileManager.default.fileExists(atPath: trainURL.path) ? [trainURL.path] : []
            validPaths = FileManager.default.fileExists(atPath: validURL.path) ? [validURL.path] : []
        } else {
            trainPaths = [inputURL.path]
            let validFallback = opts.validPath.isEmpty ? (datasetConfig.validPath ?? "") : opts.validPath
            validPaths = validFallback.isEmpty ? [] : [validFallback]
        }

        if trainPaths.isEmpty {
            Diagnostics.fail("No prepared_train.jsonl found at input path \(inputPath).", processID: processID)
        }

        do {
            let trainSamples = try LogiQADatasetLoader.loadJSONL(
                from: trainPaths,
                limit: trainLimit,
                shuffle: shuffle,
                seed: seed
            )
            let validSamples: [LogiQASample]
            if !validPaths.isEmpty {
                validSamples = try LogiQADatasetLoader.loadJSONL(
                    from: validPaths,
                    limit: validLimit,
                    shuffle: false,
                    seed: seed &+ 1
                )
            } else {
                validSamples = []
            }

            let trainOut = outputURL.appendingPathComponent("precomputed_train.jsonl")
            let validOut = outputURL.appendingPathComponent("precomputed_valid.jsonl")

            try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

            try writePrecomputedFile(
                metadata: metadata,
                samples: trainSamples,
                outputURL: trainOut,
                capsuleConfig: snapshot.root.capsule,
                bins: flowCfg.bins,
                processID: processID,
                encoder: encoder,
                retrievalUpdater: retrievalUpdater,
                jobs: jobs,
                resume: opts.resume
            )

            if !validSamples.isEmpty {
                try writePrecomputedFile(
                    metadata: metadata,
                    samples: validSamples,
                    outputURL: validOut,
                    capsuleConfig: snapshot.root.capsule,
                    bins: flowCfg.bins,
                    processID: processID,
                    encoder: encoder,
                    retrievalUpdater: retrievalUpdater,
                    jobs: jobs,
                    resume: opts.resume
                )
            }

            print("Precomputed train: \(trainSamples.count) -> \(trainOut.path)")
            if !validSamples.isEmpty {
                print("Precomputed valid: \(validSamples.count) -> \(validOut.path)")
            }
            if let updater = retrievalUpdater {
                print("Retrieval corpus updated: +\(updater.appended) entries -> \(updater.corpusPath)")
            }
        } catch {
            Diagnostics.fail("Failed to precompute dataset: \(error.localizedDescription)", processID: processID)
        }
    }

    private static func writePrecomputedFile(
        metadata: PrecomputedDataset.Metadata,
        samples: [LogiQASample],
        outputURL: URL,
        capsuleConfig: ConfigRoot.Capsule,
        bins: Int,
        processID: String,
        encoder: JSONEncoder,
        retrievalUpdater: RetrievalCorpusUpdater?,
        jobs: Int,
        resume: Bool
    ) throws {
        let fm = FileManager.default
        var existingIDs = Set<String>()
        var shouldWriteMetadata = true
        if resume, fm.fileExists(atPath: outputURL.path) {
            let existing = try loadPrecomputedIndex(
                from: outputURL,
                capsuleConfig: capsuleConfig,
                bins: bins
            )
            existingIDs = existing.ids
            shouldWriteMetadata = existing.hasMetadata == false
            if shouldWriteMetadata {
                Diagnostics.fail("Precomputed file at \(outputURL.path) is missing metadata header", processID: processID)
            }
        } else {
            if fm.fileExists(atPath: outputURL.path) {
                try fm.removeItem(at: outputURL)
            }
            fm.createFile(atPath: outputURL.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }
        if resume {
            try handle.seekToEnd()
        }

        if shouldWriteMetadata {
            let metaData = try encoder.encode(metadata)
            handle.write(metaData)
            handle.write(Data([0x0A]))
        }

        let workerCount = max(1, jobs)
        let baseBatch = max(32, min(512, samples.count / workerCount))
        let batchSize = max(32, baseBatch)
        let queue = DispatchQueue(label: "energetic.precompute.worker", attributes: .concurrent)

        let filteredSamples: [LogiQASample]
        if existingIDs.isEmpty {
            filteredSamples = samples
        } else {
            filteredSamples = samples.filter { !existingIDs.contains($0.id) }
        }

        for batchStart in stride(from: 0, to: filteredSamples.count, by: batchSize) {
            let batchEnd = min(filteredSamples.count, batchStart + batchSize)
            let batchCount = batchEnd - batchStart
            var results = Array<PrecomputedWorkItem?>(repeating: nil, count: batchCount)
            let group = DispatchGroup()
            let resultLock = NSLock()

            for localIndex in 0..<batchCount {
                group.enter()
                queue.async {
                    let sampleIndex = batchStart + localIndex
                    let sample = filteredSamples[sampleIndex]
                    var localCache: [String: EncodedSample] = [:]
                    let pair = makeTrainingPair(
                        index: sampleIndex,
                        samples: [sample],
                        fallbackInput: sample.input_text,
                        fallbackAnswer: sample.answer_text,
                        capsuleConfig: capsuleConfig,
                        bins: bins,
                        processID: processID,
                        cache: &localCache
                    )
                    let record = PrecomputedDataset.makeRecord(
                        id: sample.id,
                        split: sample.split,
                        energies: pair.energies,
                        targets: pair.targets,
                        targetsNorm: pair.targetsNorm,
                        wrongTargets: pair.wrongTargets,
                        wrongTargetsNorm: pair.wrongTargetsNorm
                    )
                    let item = PrecomputedWorkItem(record: record, answerText: pair.answerText, targets: pair.targets)
                    resultLock.lock()
                    results[localIndex] = item
                    resultLock.unlock()
                    group.leave()
                }
            }

            group.wait()
            for item in results {
                guard let item else {
                    Diagnostics.fail("Precompute worker failed to build record", processID: processID)
                }
                retrievalUpdater?.appendIfMissing(text: item.answerText, histogram: item.targets)
                let data = try encoder.encode(item.record)
                handle.write(data)
                handle.write(Data([0x0A]))
            }
        }
    }

    private struct PrecomputedWorkItem {
        let record: PrecomputedDataset.Record
        let answerText: String
        let targets: [Float]
    }

    private struct PrecomputedIndex {
        let ids: Set<String>
        let hasMetadata: Bool
    }

    private static func loadPrecomputedIndex(
        from url: URL,
        capsuleConfig: ConfigRoot.Capsule,
        bins: Int
    ) throws -> PrecomputedIndex {
        let decoder = JSONDecoder()
        var ids = Set<String>()
        var hasMetadata = false
        try forEachJSONLLine(url: url) { line in
            if let meta = try? decoder.decode(PrecomputedDataset.Metadata.self, from: line),
               meta.type == "metadata" {
                if !hasMetadata {
                    try PrecomputedDataset.validateMetadata(meta, config: capsuleConfig, bins: bins)
                    hasMetadata = true
                }
                return
            }
            let record = try decoder.decode(PrecomputedDataset.Record.self, from: line)
            ids.insert(record.id)
        }
        return PrecomputedIndex(ids: ids, hasMetadata: hasMetadata)
    }

    private static func forEachJSONLLine(url: URL, _ body: (Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var buffer = Data()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineSlice = buffer[..<nl]
                buffer.removeSubrange(..<buffer.index(after: nl))
                var line = Data(lineSlice)
                if line.last == 0x0D { line.removeLast() }
                if line.isEmpty { continue }
                try body(line)
            }
        }

        if !buffer.isEmpty {
            var line = buffer
            if line.last == 0x0D { line.removeLast() }
            if !line.isEmpty {
                try body(line)
            }
        }
    }

    private final class RetrievalCorpusUpdater {
        private let bins: Int
        private let processID: String
        private let encoder: JSONEncoder
        private var seen: Set<String>
        private let handle: FileHandle
        private let url: URL
        private(set) var appended: Int = 0

        var corpusPath: String {
            url.path
        }

        init(path: String, bins: Int, processID: String) throws {
            self.bins = bins
            self.processID = processID
            self.encoder = JSONEncoder()
            self.url = URL(fileURLWithPath: path)

            let fm = FileManager.default
            let dir = url.deletingLastPathComponent()
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
            }

            if fm.fileExists(atPath: url.path) {
                let existing = try HistogramRetriever.loadCorpus(from: url.path, bins: bins)
                self.seen = Set(existing.map { $0.text })
            } else {
                self.seen = []
                fm.createFile(atPath: url.path, contents: nil)
            }

            self.handle = try FileHandle(forWritingTo: url)
            try self.handle.seekToEnd()
        }

        func appendIfMissing(text: String, histogram: [Float]) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard histogram.count == bins else {
                Diagnostics.fail("Retrieval histogram size mismatch for '\(trimmed)'", processID: processID)
            }
            for value in histogram {
                guard value.isFinite, value >= 0 else {
                    Diagnostics.fail("Retrieval histogram contains invalid values for '\(trimmed)'", processID: processID)
                }
            }
            guard seen.insert(trimmed).inserted else { return }
            let entry = HistogramCorpusEntry(text: trimmed, histogram: histogram)
            do {
                let data = try encoder.encode(entry)
                handle.write(data)
                handle.write(Data([0x0A]))
                appended += 1
            } catch {
                Diagnostics.fail("Failed to append retrieval entry: \(error.localizedDescription)", processID: processID)
            }
        }

        func close() {
            try? handle.close()
        }
    }

    private struct DatasetGroup {
        let trainPath: String
        let validPath: String?
        let outputDir: URL
        let stem: String
    }

    private static func discoverPreparedDatasetGroups(root: URL) -> [DatasetGroup] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var trainFiles: [String: String] = [:]
        var validFiles: [String: String] = [:]

        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name.hasPrefix("precomputed_") { continue }
            if name.hasSuffix("_train.jsonl") {
                let key = datasetKey(for: url)
                trainFiles[key] = url.path
            } else if name.hasSuffix("_valid.jsonl") {
                let key = datasetKey(for: url)
                validFiles[key] = url.path
            }
        }

        var groups: [DatasetGroup] = []
        for (key, trainPath) in trainFiles {
            let validPath = validFiles[key]
            let output = outputNames(forKey: key)
            let outDir = URL(fileURLWithPath: output.outputDir)
            groups.append(
                DatasetGroup(
                    trainPath: trainPath,
                    validPath: validPath,
                    outputDir: outDir,
                    stem: output.stem
                )
            )
        }
        return groups.sorted { $0.trainPath < $1.trainPath }
    }

    private static func datasetKey(for url: URL) -> String {
        let dir = url.deletingLastPathComponent().path
        let name = url.lastPathComponent
        let stem: String
        if name.hasSuffix("_train.jsonl") {
            stem = String(name.dropLast("_train.jsonl".count))
        } else if name.hasSuffix("_valid.jsonl") {
            stem = String(name.dropLast("_valid.jsonl".count))
        } else {
            stem = name
        }
        return "\(dir)|\(stem)"
    }

    private static func outputNames(forKey key: String) -> (outputDir: String, stem: String) {
        let parts = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let dir = parts.first.map(String.init) ?? ""
        let stem = parts.count > 1 ? String(parts[1]) : "dataset"
        return (dir, stem)
    }

    private static func outputDirForAll(group: DatasetGroup) -> URL {
        let base = group.outputDir
        if group.stem == "prepared" {
            return base.appendingPathComponent("precomputed", isDirectory: true)
        }
        return base.appendingPathComponent("precomputed", isDirectory: true).appendingPathComponent(group.stem, isDirectory: true)
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

    private struct LCG {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1
            return state
        }
        mutating func nextInt(upperBound: Int) -> Int {
            return Int(next() % UInt64(upperBound))
        }
    }

    private static func shuffleInPlace<T>(_ array: inout [T], seed: UInt64) {
        var rng = LCG(seed: seed)
        if array.count < 2 { return }
        for i in stride(from: array.count - 1, through: 1, by: -1) {
            let j = rng.nextInt(upperBound: i + 1)
            if i != j { array.swapAt(i, j) }
        }
    }
}
