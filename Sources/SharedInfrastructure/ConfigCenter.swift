import Foundation
import Yams

public struct ConfigSnapshot {
    public let root: ConfigRoot
    public let sourceURL: URL
}

public enum ConfigCenter {
    public static func load(url: URL? = nil, fileManager: FileManager = .default) throws -> ConfigSnapshot {
        let resolvedURL = try resolveURL(explicitURL: url, fileManager: fileManager)
        let data = try Data(contentsOf: resolvedURL)
        guard let yamlString = String(data: data, encoding: .utf8) else {
            throw ConfigError.invalidEncoding(resolvedURL)
        }

        let decoder = YAMLDecoder()
        let root = try decoder.decode(ConfigRoot.self, from: yamlString)
        try Validation.validate(root: root)

        return ConfigSnapshot(root: root, sourceURL: resolvedURL)
    }

    private static func resolveURL(explicitURL: URL?, fileManager: FileManager) throws -> URL {
        if let explicitURL {
            return explicitURL
        }

        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let defaultURL = cwd
            .appendingPathComponent("Configs", isDirectory: true)
            .appendingPathComponent("baseline.yaml", isDirectory: false)

        guard fileManager.fileExists(atPath: defaultURL.path) else {
            throw ConfigError.fileNotFound(defaultURL)
        }

        return defaultURL
    }
}

// MARK: - Validation

enum Validation {
    static func validate(root: ConfigRoot) throws {
        try ensureAlphabetLength(capsule: root.capsule)
        try ensureEnergyBaseMatches(capsule: root.capsule, router: root.router)
        try ensureFlowRouterParameters(router: root.router)
        try ensureLearningParameters(router: root.router)
        try ensureBlockSize(capsule: root.capsule)
        try ensureLoggingDestinations(logging: root.logging)
        try ensureProcessRegistry(root.processRegistry)
        try ensureOverridesWithinRegistry(logging: root.logging, registry: root.processRegistry)
        try ensureHistogramLanguage(root.histogramLanguage)
    }

    private static func ensureAlphabetLength(capsule: ConfigRoot.Capsule) throws {
        if capsule.alphabet.count != capsule.base {
            throw ConfigError.invalidAlphabetLength(expected: capsule.base, actual: capsule.alphabet.count)
        }
    }

    private static func ensureEnergyBaseMatches(capsule: ConfigRoot.Capsule, router: ConfigRoot.Router) throws {
        if capsule.base != router.energyConstraints.energyBase {
            throw ConfigError.energyBaseMismatch(capsule.base, router.energyConstraints.energyBase)
        }
    }

    private static func ensureFlowRouterParameters(router: ConfigRoot.Router) throws {
        guard router.backend == "flow" else {
            throw ConfigError.invalidRouterBackend(router.backend)
        }
        let flow = router.flow
        if flow.T < 1 {
            throw ConfigError.invalidFlowParameter("T must be ≥ 1 (got \(flow.T))")
        }
        if let computeBackend = flow.computeBackend?.lowercased(), computeBackend != "metal" {
            throw ConfigError.invalidFlowParameter("flow.compute_backend must be 'metal' (got \(computeBackend))")
        }
        if flow.radius <= 0 {
            throw ConfigError.invalidFlowParameter("radius must be > 0 (got \(flow.radius))")
        }
        if flow.seedRadius < 0 || flow.seedRadius >= flow.radius {
            throw ConfigError.invalidFlowParameter("seed_radius must be in [0, radius)")
        }
        // LIF
        if flow.lif.decay <= 0 || flow.lif.decay >= 1 {
            throw ConfigError.invalidFlowParameter("lif.decay must be in (0, 1)")
        }
        if flow.lif.threshold <= 0 || flow.lif.threshold > 1 {
            throw ConfigError.invalidFlowParameter("lif.threshold must be in (0, 1]")
        }
        // Dynamics
        if flow.dynamics.spikeKick < 0 {
            throw ConfigError.invalidFlowParameter("dynamics.spike_kick must be ≥ 0")
        }
        if flow.dynamics.gainSpikeKickScale < 0 {
            throw ConfigError.invalidFlowParameter("dynamics.gain_spike_kick_scale must be ≥ 0")
        }
        if flow.dynamics.maxSpeed <= 0 {
            throw ConfigError.invalidFlowParameter("dynamics.max_speed must be > 0")
        }
        if flow.dynamics.energyAlpha <= 0 || flow.dynamics.energyAlpha > 1 {
            throw ConfigError.invalidFlowParameter("dynamics.energy_alpha must be in (0, 1]")
        }
        if flow.dynamics.energyFloor < 0 {
            throw ConfigError.invalidEnergyFloor(flow.dynamics.energyFloor)
        }
        if flow.dynamics.energySpikeGain < 0 {
            throw ConfigError.invalidFlowParameter("dynamics.energy_spike_gain must be ≥ 0")
        }
        if flow.dynamics.energyGainBias < 0 {
            throw ConfigError.invalidFlowParameter("dynamics.energy_gain_bias must be ≥ 0")
        }
        if flow.dynamics.energyCap < 0 {
            throw ConfigError.invalidFlowParameter("dynamics.energy_cap must be ≥ 0 (0 = no cap)")
        }
        // Projection
        if flow.projection.shape.lowercased() != "circle" {
            throw ConfigError.invalidFlowParameter("projection.shape must be 'circle' in this profile")
        }
        if flow.projection.bins != router.energyConstraints.energyBase {
            throw ConfigError.invalidFlowParameter("projection.bins must equal energy_constraints.energy_base")
        }
        if flow.projection.finalWeightPower <= 0 {
            throw ConfigError.invalidFlowParameter("projection.final_weight_power must be > 0")
        }
    }

    private static func ensureLearningParameters(router: ConfigRoot.Router) throws {
        let learning = router.flow.learning
        if learning.epochs < 0 {
            throw ConfigError.invalidLearningParameter("epochs must be ≥ 0 (got \(learning.epochs))")
        }
        if learning.stepsPerEpoch < 1 {
            throw ConfigError.invalidLearningParameter("steps_per_epoch must be ≥ 1 (got \(learning.stepsPerEpoch))")
        }
        if learning.targetSpikeRate < 0 || learning.targetSpikeRate > 1 {
            throw ConfigError.invalidLearningParameter("target_spike_rate must be in [0, 1] (got \(learning.targetSpikeRate))")
        }
        if learning.evalEvery < 1 {
            throw ConfigError.invalidLearningParameter("eval_every must be ≥ 1 (got \(learning.evalEvery))")
        }
        if learning.logEvery < 1 {
            throw ConfigError.invalidLearningParameter("log_every must be ≥ 1 (got \(learning.logEvery))")
        }
        if learning.logEveryUI < 1 {
            throw ConfigError.invalidLearningParameter("log_every_ui must be ≥ 1 (got \(learning.logEveryUI))")
        }
        if learning.dataset.localPath.isEmpty && !learning.dataset.autoScan {
            throw ConfigError.invalidLearningParameter("dataset.local_path must be non-empty unless dataset.auto_scan is true")
        }
        if learning.dataset.trainLimit < 0 || learning.dataset.validLimit < 0 {
            throw ConfigError.invalidLearningParameter("dataset limits must be ≥ 0")
        }
        if learning.negative.weight < 0 {
            throw ConfigError.invalidLearningParameter("negative.weight must be ≥ 0")
        }
        if learning.negative.margin < 0 {
            throw ConfigError.invalidLearningParameter("negative.margin must be ≥ 0")
        }
        // Learning rates
        if learning.lr.gain < 0 {
            throw ConfigError.invalidLearningParameter("lr.gain must be ≥ 0 (got \(learning.lr.gain))")
        }
        if learning.lr.lif < 0 {
            throw ConfigError.invalidLearningParameter("lr.lif must be ≥ 0 (got \(learning.lr.lif))")
        }
        if learning.lr.dynamics < 0 {
            throw ConfigError.invalidLearningParameter("lr.dynamics must be ≥ 0 (got \(learning.lr.dynamics))")
        }
        // Loss weights
        if learning.weights.spike < 0 {
            throw ConfigError.invalidLearningParameter("weights.spike must be ≥ 0 (got \(learning.weights.spike))")
        }
        if learning.weights.boundary < 0 {
            throw ConfigError.invalidLearningParameter("weights.boundary must be ≥ 0 (got \(learning.weights.boundary))")
        }
        if learning.gainErrorPower < 0 {
            throw ConfigError.invalidLearningParameter("gain_error_power must be ≥ 0 (got \(learning.gainErrorPower))")
        }
        if learning.gainErrorScale < 0 {
            throw ConfigError.invalidLearningParameter("gain_error_scale must be ≥ 0 (got \(learning.gainErrorScale))")
        }
        // Bounds arrays
        if learning.bounds.theta.count != 2 {
            throw ConfigError.invalidLearningParameter("bounds.theta must have exactly 2 elements [min, max]")
        }
        if learning.bounds.theta[0] >= learning.bounds.theta[1] {
            throw ConfigError.invalidLearningParameter("bounds.theta[0] must be < theta[1]")
        }
        if learning.bounds.radialBias.count != 2 {
            throw ConfigError.invalidLearningParameter("bounds.radial_bias must have exactly 2 elements [min, max]")
        }
        if learning.bounds.radialBias[0] >= learning.bounds.radialBias[1] {
            throw ConfigError.invalidLearningParameter("bounds.radial_bias[0] must be < radial_bias[1]")
        }
        if learning.bounds.spikeKick.count != 2 {
            throw ConfigError.invalidLearningParameter("bounds.spike_kick must have exactly 2 elements [min, max]")
        }
        if learning.bounds.spikeKick[0] >= learning.bounds.spikeKick[1] {
            throw ConfigError.invalidLearningParameter("bounds.spike_kick[0] must be < spike_kick[1]")
        }
        if learning.bounds.gain.count != 2 {
            throw ConfigError.invalidLearningParameter("bounds.gain must have exactly 2 elements [min, max]")
        }
        if learning.bounds.gain[0] >= learning.bounds.gain[1] {
            throw ConfigError.invalidLearningParameter("bounds.gain[0] must be < gain[1]")
        }
        // Aggregator parameters
        if learning.aggregator.sigmaR <= 0 {
            throw ConfigError.invalidLearningParameter("aggregator.sigma_r must be > 0 (got \(learning.aggregator.sigmaR))")
        }
        if learning.aggregator.sigmaE <= 0 {
            throw ConfigError.invalidLearningParameter("aggregator.sigma_e must be > 0 (got \(learning.aggregator.sigmaE))")
        }
        // Output signal
        if let signal = learning.outputSignal?.lowercased() {
            let validSignals = ["completion_cpu", "weighted_bins_gpu"]
            if !validSignals.contains(signal) {
                throw ConfigError.invalidLearningParameter("output_signal must be one of \(validSignals) (got \(signal))")
            }
        }

        // Target type
        let validTypes = ["capsule-digits", "file"]
        if !validTypes.contains(learning.targets.type) {
            throw ConfigError.invalidLearningParameter("targets.type must be one of \(validTypes) (got \(learning.targets.type))")
        }
        if learning.targets.type == "file" && (learning.targets.path == nil || learning.targets.path!.isEmpty) {
            throw ConfigError.invalidLearningParameter("targets.path is required when type is 'file'")
        }
    }

    private static func ensureBlockSize(capsule: ConfigRoot.Capsule) throws {
        let headerBytes = 7
        if capsule.blockSize < capsule.maxInputBytes + headerBytes {
            throw ConfigError.blockSizeTooSmall(required: capsule.maxInputBytes + headerBytes, actual: capsule.blockSize)
        }
    }

    private static func ensureLoggingDestinations(logging: ConfigRoot.Logging) throws {
        if logging.destinations.isEmpty {
            throw ConfigError.noLoggingDestinations
        }
    }

    private static func ensureProcessRegistry(_ registry: [String: String]) throws {
        let values = registry.values
        if Set(values).count != values.count {
            throw ConfigError.duplicateProcessIdentifier
        }
    }

    private static func ensureOverridesWithinRegistry(logging: ConfigRoot.Logging, registry: [String: String]) throws {
        for key in logging.levelsOverride.keys {
            if registry[key] == nil {
                throw ConfigError.overrideForUnknownProcess(key)
            }
        }
    }

    private static func ensureHistogramLanguage(_ histogram: ConfigRoot.HistogramLanguage) throws {
        if histogram.metrics.isEmpty {
            throw ConfigError.invalidHistogramLanguageParameter("metrics must be a non-empty list")
        }
        let allowed: Set<String> = ["l1", "l2", "cosine"]
        let invalidMetrics = histogram.metrics
            .map { $0.lowercased() }
            .filter { !allowed.contains($0) }
        if !invalidMetrics.isEmpty {
            throw ConfigError.invalidHistogramLanguageParameter("metrics must be one of \(allowed.sorted())")
        }
        if histogram.retrieval.topK < 1 {
            throw ConfigError.invalidHistogramLanguageParameter("retrieval.top_k must be ≥ 1")
        }
        if histogram.retrieval.enabled {
            let trimmed = histogram.retrieval.corpusPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw ConfigError.invalidHistogramLanguageParameter("retrieval.corpus_path is required when retrieval.enabled is true")
            }
        }
    }
}

// MARK: - Errors

public enum ConfigError: LocalizedError {
    case fileNotFound(URL)
    case invalidEncoding(URL)
    case invalidAlphabetLength(expected: Int, actual: Int)
    case energyBaseMismatch(Int, Int)
    case blockSizeTooSmall(required: Int, actual: Int)
    case noLoggingDestinations
    case duplicateProcessIdentifier
    case overrideForUnknownProcess(String)
    case missingLogFilePath
    case failedToCreateLogFile(URL)
    case failedToOpenLogFile(URL)
    // Flow router validation
    case invalidRouterBackend(String)
    case invalidEnergyFloor(Double)
    case invalidFlowParameter(String)
    case invalidLearningParameter(String)
    case invalidHistogramLanguageParameter(String)

    public var errorDescription: String? {
        switch self {
        case let .fileNotFound(url):
            return "Config file not found at \(url.path)"
        case let .invalidEncoding(url):
            return "Config at \(url.path) is not valid UTF-8"
        case let .invalidAlphabetLength(expected, actual):
            return "Capsule alphabet length \(actual) does not match base \(expected)"
        case let .energyBaseMismatch(capsule, router):
            return "Capsule base (\(capsule)) does not match router energy base (\(router))"
        case let .blockSizeTooSmall(required, actual):
            return "Capsule block_size=\(actual) is smaller than required minimum \(required)"
        case .noLoggingDestinations:
            return "Logging configuration must contain at least one destination"
        case .duplicateProcessIdentifier:
            return "Process registry contains duplicate canonical identifiers"
        case let .overrideForUnknownProcess(key):
            return "Logging override references unknown process_id '\(key)'"
        case .missingLogFilePath:
            return "Logging destination of type 'file' requires non-empty path"
        case let .failedToCreateLogFile(url):
            return "Failed to create log file at \(url.path)"
        case let .failedToOpenLogFile(url):
            return "Failed to open log file at \(url.path)"
        case let .invalidRouterBackend(name):
            return "router.backend must be 'flow' (got \(name))"
        case let .invalidEnergyFloor(value):
            return "router.flow.dynamics.energy_floor must be ≥ 0 (got \(value))"
        case let .invalidFlowParameter(reason):
            return "Invalid flow router parameter: \(reason)"
        case let .invalidLearningParameter(reason):
            return "Invalid learning parameter: \(reason)"
        case let .invalidHistogramLanguageParameter(reason):
            return "Invalid histogram_language parameter: \(reason)"
        }
    }
}

// MARK: - Model

public struct ConfigRoot: Decodable {
    public let version: Int
    public let profile: String
    public let seed: Int
    public let logging: Logging
    public let processRegistry: [String: String]
    public let paths: Paths
    public let capsule: Capsule
    public let router: Router
    public let ui: UI
    public let histogramLanguage: HistogramLanguage

    enum CodingKeys: String, CodingKey {
        case version
        case profile
        case seed
        case logging
        case processRegistry = "process_registry"
        case paths
        case capsule
        case router
        case ui
        case histogramLanguage = "histogram_language"
    }

    public struct Logging: Decodable {
        public let defaultLevel: LogLevel
        public let signposts: Bool
        public let destinations: [Destination]
        public let levelsOverride: [String: LogLevel]
        public let timestampKind: TimestampKind
        public let fileSync: Bool

        enum CodingKeys: String, CodingKey {
            case defaultLevel = "default_level"
            case signposts
            case destinations
            case levelsOverride = "levels_override"
            case timestampKind = "timestamp_kind"
            case fileSync = "file_sync"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            defaultLevel = try container.decode(LogLevel.self, forKey: .defaultLevel)
            signposts = try container.decodeIfPresent(Bool.self, forKey: .signposts) ?? false
            destinations = try container.decodeIfPresent([Destination].self, forKey: .destinations) ?? [.init(type: .stdout, path: nil)]
            levelsOverride = try container.decodeIfPresent([String: LogLevel].self, forKey: .levelsOverride) ?? [:]
            timestampKind = try container.decodeIfPresent(TimestampKind.self, forKey: .timestampKind) ?? .relative
            fileSync = try container.decodeIfPresent(Bool.self, forKey: .fileSync) ?? true
        }

        public enum TimestampKind: String, Decodable {
            case relative
            case absolute
        }

        public struct Destination: Decodable {
            public let type: DestinationType
            public let path: String?

            enum CodingKeys: String, CodingKey {
                case type
                case path
            }

            public enum DestinationType: String, Decodable {
                case stdout
                case file
            }
        }

        public init(
            defaultLevel: LogLevel,
            signposts: Bool,
            destinations: [Destination],
            levelsOverride: [String: LogLevel],
            timestampKind: TimestampKind,
            fileSync: Bool
        ) {
            self.defaultLevel = defaultLevel
            self.signposts = signposts
            self.destinations = destinations
            self.levelsOverride = levelsOverride
            self.timestampKind = timestampKind
            self.fileSync = fileSync
        }
    }

    public struct Paths: Decodable {
        public let logsDir: String
        public let checkpointsDir: String
        public let snapshotsDir: String
        public let pipelineSnapshot: String

        enum CodingKeys: String, CodingKey {
            case logsDir = "logs_dir"
            case checkpointsDir = "checkpoints_dir"
            case snapshotsDir = "snapshots_dir"
            case pipelineSnapshot = "pipeline_snapshot"
        }
    }

    public struct Capsule: Decodable {
        public let enabled: Bool
        public let maxInputBytes: Int
        public let blockSize: Int
        public let base: Int
        public let alphabet: String
        public let prp: String
        public let feistelRounds: Int
        public let keyHex: String
        public let normalization: String
        public let pipelineExampleText: String
        public let crc: String
        public let gpuBatch: Int

        enum CodingKeys: String, CodingKey {
            case enabled
            case maxInputBytes = "max_input_bytes"
            case blockSize = "block_size"
            case base
            case alphabet
            case prp
            case feistelRounds = "feistel_rounds"
            case keyHex = "key_hex"
            case normalization
            case pipelineExampleText = "pipeline_example_text"
            case crc
            case gpuBatch = "gpu_batch"
        }
    }

    public struct Router: Decodable {
        public let backend: String
        public let flow: Flow
        public let energyConstraints: EnergyConstraints

        enum CodingKeys: String, CodingKey {
            case backend
            case flow
            case energyConstraints = "energy_constraints"
        }

        public struct Flow: Decodable {
            public let T: Int
            public let radius: Double
            public let computeBackend: String?
            public let seedLayout: String
            public let seedRadius: Double
            public let lif: LIF
            public let dynamics: Dynamics
            public let interactions: Interactions
            public let projection: Projection
            public let learning: Learning

            enum CodingKeys: String, CodingKey {
                case T
                case radius
                case computeBackend = "compute_backend"
                case seedLayout = "seed_layout"
                case seedRadius = "seed_radius"
                case lif
                case dynamics
                case interactions
                case projection
                case learning
            }

            public struct LIF: Decodable {
                public let decay: Double
                public let threshold: Double
                public let resetValue: Double
                public let surrogate: String

                enum CodingKeys: String, CodingKey {
                    case decay
                    case threshold
                    case resetValue = "reset_value"
                    case surrogate
                }
            }

            public struct Dynamics: Decodable {
                public let radialBias: Double
                public let spikeKick: Double
                public let gainSpikeKickScale: Double
                public let noiseStdPos: Double
                public let noiseStdDir: Double
                public let maxSpeed: Double
                public let energyAlpha: Double
                public let energyFloor: Double
                public let energySpikeGain: Double
                public let energyGainBias: Double
                public let energyCap: Double

                enum CodingKeys: String, CodingKey {
                    case radialBias = "radial_bias"
                    case spikeKick = "spike_kick"
                    case gainSpikeKickScale = "gain_spike_kick_scale"
                    case noiseStdPos = "noise_std_pos"
                    case noiseStdDir = "noise_std_dir"
                    case maxSpeed = "max_speed"
                    case energyAlpha = "energy_alpha"
                    case energyFloor = "energy_floor"
                    case energySpikeGain = "energy_spike_gain"
                    case energyGainBias = "energy_gain_bias"
                    case energyCap = "energy_cap"
                }

                public init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    radialBias = try container.decode(Double.self, forKey: .radialBias)
                    spikeKick = try container.decode(Double.self, forKey: .spikeKick)
                    gainSpikeKickScale = try container.decodeIfPresent(Double.self, forKey: .gainSpikeKickScale) ?? 0.0
                    noiseStdPos = try container.decode(Double.self, forKey: .noiseStdPos)
                    noiseStdDir = try container.decode(Double.self, forKey: .noiseStdDir)
                    maxSpeed = try container.decode(Double.self, forKey: .maxSpeed)
                    energyAlpha = try container.decode(Double.self, forKey: .energyAlpha)
                    energyFloor = try container.decode(Double.self, forKey: .energyFloor)
                    energySpikeGain = try container.decodeIfPresent(Double.self, forKey: .energySpikeGain) ?? 0.0
                    energyGainBias = try container.decodeIfPresent(Double.self, forKey: .energyGainBias) ?? 0.0
                    energyCap = try container.decodeIfPresent(Double.self, forKey: .energyCap) ?? 0.0
                }

                public init(
                    radialBias: Double,
                    spikeKick: Double,
                    gainSpikeKickScale: Double = 0.0,
                    noiseStdPos: Double,
                    noiseStdDir: Double,
                    maxSpeed: Double,
                    energyAlpha: Double,
                    energyFloor: Double,
                    energySpikeGain: Double = 0.0,
                    energyGainBias: Double = 0.0,
                    energyCap: Double = 0.0
                ) {
                    self.radialBias = radialBias
                    self.spikeKick = spikeKick
                    self.gainSpikeKickScale = gainSpikeKickScale
                    self.noiseStdPos = noiseStdPos
                    self.noiseStdDir = noiseStdDir
                    self.maxSpeed = maxSpeed
                    self.energyAlpha = energyAlpha
                    self.energyFloor = energyFloor
                    self.energySpikeGain = energySpikeGain
                    self.energyGainBias = energyGainBias
                    self.energyCap = energyCap
                }
            }

            public struct Interactions: Decodable {
                public let enabled: Bool
                public let type: String
                public let strength: Double
            }

            public struct Projection: Decodable {
                public let shape: String
                public let bins: Int
                public let binSmoothing: Double
                public let finalWeightPower: Double

                enum CodingKeys: String, CodingKey {
                    case shape
                    case bins
                    case binSmoothing = "bin_smoothing"
                    case finalWeightPower = "final_weight_power"
                }

                public init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    shape = try container.decode(String.self, forKey: .shape)
                    bins = try container.decode(Int.self, forKey: .bins)
                    binSmoothing = try container.decodeIfPresent(Double.self, forKey: .binSmoothing) ?? 0.0
                    finalWeightPower = try container.decodeIfPresent(Double.self, forKey: .finalWeightPower) ?? 1.0
                }

                public init(shape: String, bins: Int, binSmoothing: Double, finalWeightPower: Double = 1.0) {
                    self.shape = shape
                    self.bins = bins
                    self.binSmoothing = binSmoothing
                    self.finalWeightPower = finalWeightPower
                }
            }

            public struct Learning: Decodable {
                public let enabled: Bool
                public let epochs: Int
                public let stepsPerEpoch: Int
                public let targetSpikeRate: Double
                public let evalEvery: Int
                public let logSilence: Bool
                public let logEvery: Int
                public let logEveryUI: Int
                public let outputSignal: String?
                public let dataset: Dataset
                public let negative: Negative
                public let lr: LearningRates
                public let weights: LossWeights
                public let gainErrorPower: Double
                public let gainErrorScale: Double
                public let bounds: ParameterBounds
                public let aggregator: Aggregator
                public let targets: Targets

                enum CodingKeys: String, CodingKey {
                    case enabled
                    case epochs
                    case stepsPerEpoch = "steps_per_epoch"
                    case targetSpikeRate = "target_spike_rate"
                    case evalEvery = "eval_every"
                    case logSilence = "log_silence"
                    case logEvery = "log_every"
                    case logEveryUI = "log_every_ui"
                    case outputSignal = "output_signal"
                    case dataset
                    case negative
                    case lr
                    case weights
                    case gainErrorPower = "gain_error_power"
                    case gainErrorScale = "gain_error_scale"
                    case bounds
                    case aggregator
                    case targets
                }

                public struct Dataset: Decodable {
                    public let name: String
                    public let localPath: String
                    public let validPath: String?
                    public let cacheMode: String
                    public let trainLimit: Int
                    public let validLimit: Int
                    public let shuffle: Bool
                    public let seed: Int
                    public let autoScan: Bool

                    enum CodingKeys: String, CodingKey {
                        case name
                        case localPath = "local_path"
                        case validPath = "valid_path"
                        case cacheMode = "cache_mode"
                        case trainLimit = "train_limit"
                        case validLimit = "valid_limit"
                        case shuffle
                        case seed
                        case autoScan = "auto_scan"
                    }

                    public init(from decoder: Decoder) throws {
                        let container = try decoder.container(keyedBy: CodingKeys.self)
                        name = try container.decode(String.self, forKey: .name)
                        localPath = try container.decodeIfPresent(String.self, forKey: .localPath) ?? ""
                        validPath = try container.decodeIfPresent(String.self, forKey: .validPath)
                        cacheMode = try container.decode(String.self, forKey: .cacheMode)
                        trainLimit = try container.decode(Int.self, forKey: .trainLimit)
                        validLimit = try container.decode(Int.self, forKey: .validLimit)
                        shuffle = try container.decode(Bool.self, forKey: .shuffle)
                        seed = try container.decode(Int.self, forKey: .seed)
                        autoScan = try container.decodeIfPresent(Bool.self, forKey: .autoScan) ?? false
                    }

                    public init(
                        name: String,
                        localPath: String,
                        validPath: String?,
                        cacheMode: String,
                        trainLimit: Int,
                        validLimit: Int,
                        shuffle: Bool,
                        seed: Int,
                        autoScan: Bool = false
                    ) {
                        self.name = name
                        self.localPath = localPath
                        self.validPath = validPath
                        self.cacheMode = cacheMode
                        self.trainLimit = trainLimit
                        self.validLimit = validLimit
                        self.shuffle = shuffle
                        self.seed = seed
                        self.autoScan = autoScan
                    }
                }

                public struct Negative: Decodable {
                    public let enabled: Bool
                    public let weight: Double
                    public let margin: Double
                }

                public struct LearningRates: Decodable {
                    public let gain: Double
                    public let lif: Double
                    public let dynamics: Double

                    public init(gain: Double, lif: Double, dynamics: Double) {
                        self.gain = gain
                        self.lif = lif
                        self.dynamics = dynamics
                    }
                }

                public struct LossWeights: Decodable {
                    public let spike: Double
                    public let boundary: Double

                    public init(spike: Double, boundary: Double) {
                        self.spike = spike
                        self.boundary = boundary
                    }
                }

                public struct ParameterBounds: Decodable {
                    public let theta: [Double]
                    public let radialBias: [Double]
                    public let spikeKick: [Double]
                    public let gain: [Double]

                    enum CodingKeys: String, CodingKey {
                        case theta
                        case radialBias = "radial_bias"
                        case spikeKick = "spike_kick"
                        case gain
                    }

                    public init(theta: [Double], radialBias: [Double], spikeKick: [Double], gain: [Double]) {
                        self.theta = theta
                        self.radialBias = radialBias
                        self.spikeKick = spikeKick
                        self.gain = gain
                    }
                }

                public struct Aggregator: Decodable {
                    public let sigmaR: Double
                    public let sigmaE: Double
                    public let alpha: Double
                    public let beta: Double
                    public let gamma: Double
                    public let tau: Double

                    enum CodingKeys: String, CodingKey {
                        case sigmaR = "sigma_r"
                        case sigmaE = "sigma_e"
                        case alpha
                        case beta
                        case gamma
                        case tau
                    }

                    public init(sigmaR: Double, sigmaE: Double, alpha: Double, beta: Double, gamma: Double, tau: Double) {
                        self.sigmaR = sigmaR
                        self.sigmaE = sigmaE
                        self.alpha = alpha
                        self.beta = beta
                        self.gamma = gamma
                        self.tau = tau
                    }
                }

                public struct Targets: Decodable {
                    public let type: String
                    public let path: String?

                    public init(type: String, path: String?) {
                        self.type = type
                        self.path = path
                    }
                }

                public init(enabled: Bool, epochs: Int, stepsPerEpoch: Int, targetSpikeRate: Double, evalEvery: Int, logSilence: Bool, logEvery: Int, logEveryUI: Int, outputSignal: String? = nil, dataset: Dataset, negative: Negative, lr: LearningRates, weights: LossWeights, gainErrorPower: Double = 1.0, gainErrorScale: Double = 1.0, bounds: ParameterBounds, aggregator: Aggregator, targets: Targets) {
                    self.enabled = enabled
                    self.epochs = epochs
                    self.stepsPerEpoch = stepsPerEpoch
                    self.targetSpikeRate = targetSpikeRate
                    self.evalEvery = evalEvery
                    self.logSilence = logSilence
                    self.logEvery = logEvery
                    self.logEveryUI = logEveryUI
                    self.outputSignal = outputSignal
                    self.dataset = dataset
                    self.negative = negative
                    self.lr = lr
                    self.weights = weights
                    self.gainErrorPower = gainErrorPower
                    self.gainErrorScale = gainErrorScale
                    self.bounds = bounds
                    self.aggregator = aggregator
                    self.targets = targets
                }

                public init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    enabled = try container.decode(Bool.self, forKey: .enabled)
                    epochs = try container.decode(Int.self, forKey: .epochs)
                    stepsPerEpoch = try container.decode(Int.self, forKey: .stepsPerEpoch)
                    targetSpikeRate = try container.decode(Double.self, forKey: .targetSpikeRate)
                    evalEvery = try container.decodeIfPresent(Int.self, forKey: .evalEvery) ?? 1
                    logSilence = try container.decodeIfPresent(Bool.self, forKey: .logSilence) ?? false
                    logEvery = try container.decodeIfPresent(Int.self, forKey: .logEvery) ?? 1
                    logEveryUI = try container.decodeIfPresent(Int.self, forKey: .logEveryUI) ?? logEvery
                    outputSignal = try container.decodeIfPresent(String.self, forKey: .outputSignal)
                    dataset = try container.decode(Dataset.self, forKey: .dataset)
                    negative = try container.decode(Negative.self, forKey: .negative)
                    lr = try container.decode(LearningRates.self, forKey: .lr)
                    weights = try container.decode(LossWeights.self, forKey: .weights)
                    gainErrorPower = try container.decodeIfPresent(Double.self, forKey: .gainErrorPower) ?? 1.0
                    gainErrorScale = try container.decodeIfPresent(Double.self, forKey: .gainErrorScale) ?? 1.0
                    bounds = try container.decode(ParameterBounds.self, forKey: .bounds)
                    aggregator = try container.decode(Aggregator.self, forKey: .aggregator)
                    targets = try container.decode(Targets.self, forKey: .targets)
                }
            }
        }

        public struct EnergyConstraints: Decodable {
            public let energyBase: Int

            enum CodingKeys: String, CodingKey {
                case energyBase = "energy_base"
            }
        }
    }

    public struct UI: Decodable {
        public let enabled: Bool
        public let refreshHZ: Int
        public let headlessOverride: Bool
        public let showPipeline: Bool
        public let showGraph: Bool
        public let pipelineSnapshotPath: String
        public let metricsPollMS: Int

        enum CodingKeys: String, CodingKey {
            case enabled
            case refreshHZ = "refresh_hz"
            case headlessOverride = "headless_override"
            case showPipeline = "show_pipeline"
            case showGraph = "show_graph"
            case pipelineSnapshotPath = "pipeline_snapshot_path"
            case metricsPollMS = "metrics_poll_ms"
        }
    }

    public struct HistogramLanguage: Decodable {
        public let enabled: Bool
        public let normalizeInput: Bool
        public let normalizeOutput: Bool
        public let metrics: [String]
        public let retrieval: Retrieval

        enum CodingKeys: String, CodingKey {
            case enabled
            case normalizeInput = "normalize_input"
            case normalizeOutput = "normalize_output"
            case metrics
            case retrieval
        }

        public struct Retrieval: Decodable {
            public let enabled: Bool
            public let topK: Int
            public let corpusPath: String

            enum CodingKeys: String, CodingKey {
                case enabled
                case topK = "top_k"
                case corpusPath = "corpus_path"
            }
        }
    }
}
