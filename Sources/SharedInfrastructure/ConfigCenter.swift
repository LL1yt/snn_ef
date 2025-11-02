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
        try ensureRouterParameters(router: root.router)
        try ensureBlockSize(capsule: root.capsule)
        try ensureLoggingDestinations(logging: root.logging)
        try ensureProcessRegistry(root.processRegistry)
        try ensureOverridesWithinRegistry(logging: root.logging, registry: root.processRegistry)
    }

    private static func ensureAlphabetLength(capsule: ConfigRoot.Capsule) throws {
        // #if DEBUG
        // let s = capsule.alphabet
        // let graphemeCount = s.count
        // let scalarCount = s.unicodeScalars.count
        // let utf8Count = s.utf8.count
        // let uniqueCount = Set(s).count

        // var lines: [String] = []
        // lines.reserveCapacity(graphemeCount)
        // var i = 0
        // for ch in s {
        //     let scalars = String(ch).unicodeScalars
        //         .map { String(format: "U+%04X", $0.value) }
        //         .joined(separator: "+")
        //     lines.append(String(format: "%03d '%@' [%@]", i, String(ch), scalars))
        //     i += 1
        // }

        // fputs("""
        // [ConfigCenter] Alphabet diagnostics
        // base=\(capsule.base)
        // graphemes=\(graphemeCount) scalars=\(scalarCount) utf8_bytes=\(utf8Count) unique_graphemes=\(uniqueCount)
        // alphabet="\(s)"
        // indices:\n\(lines.joined(separator: "\n"))

        // """, stderr)
        // #endif

        if capsule.alphabet.count != capsule.base {
            throw ConfigError.invalidAlphabetLength(expected: capsule.base, actual: capsule.alphabet.count)
        }
    }

    private static func ensureEnergyBaseMatches(capsule: ConfigRoot.Capsule, router: ConfigRoot.Router) throws {
        if capsule.base != router.energyConstraints.energyBase {
            throw ConfigError.energyBaseMismatch(capsule.base, router.energyConstraints.energyBase)
        }
    }

    private static func ensureRouterParameters(router: ConfigRoot.Router) throws {
        if router.layers < 1 {
            throw ConfigError.invalidRouterLayers(router.layers)
        }

        if router.nodesPerLayer < 1 {
            throw ConfigError.invalidRouterNodesPerLayer(router.nodesPerLayer)
        }

        if router.snn.parameterCount < 1 {
            throw ConfigError.invalidSNNParameterCount(router.snn.parameterCount)
        }

        if router.snn.decay <= 0 || router.snn.decay >= 1 {
            throw ConfigError.invalidSNNDecay(router.snn.decay)
        }

        if router.snn.threshold <= 0 || router.snn.threshold > 1 {
            throw ConfigError.invalidSNNThreshold(router.snn.threshold)
        }

        let dx = router.snn.deltaXRange
        if dx.min < 1 || dx.max < dx.min {
            throw ConfigError.invalidSNNDeltaXRange(dx.min, dx.max)
        }

        let dy = router.snn.deltaYRange
        if dy.max < dy.min || dy.min > 0 || dy.max < 0 {
            throw ConfigError.invalidSNNDeltaYRange(dy.min, dy.max)
        }

        if router.snn.dt < 1 {
            throw ConfigError.invalidSNNTimeStep(router.snn.dt)
        }

        if router.alpha <= 0 || router.alpha > 1 {
            throw ConfigError.invalidAlpha(router.alpha)
        }

        if router.energyFloor < 0 {
            throw ConfigError.invalidEnergyFloor(router.energyFloor)
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
    case invalidRouterLayers(Int)
    case invalidRouterNodesPerLayer(Int)
    case invalidSNNParameterCount(Int)
    case invalidSNNDecay(Double)
    case invalidSNNThreshold(Double)
    case invalidSNNDeltaXRange(Int, Int)
    case invalidSNNDeltaYRange(Int, Int)
    case invalidAlpha(Double)
    case invalidEnergyFloor(Double)
    case invalidSNNTimeStep(Int)

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
        case let .invalidRouterLayers(value):
            return "router.layers must be ≥ 1 (got \(value))"
        case let .invalidRouterNodesPerLayer(value):
            return "router.nodes_per_layer must be ≥ 1 (got \(value))"
        case let .invalidSNNParameterCount(value):
            return "router.snn.parameter_count must be ≥ 1 (got \(value))"
        case let .invalidSNNDecay(value):
            return "router.snn.decay must be in (0, 1) (got \(value))"
        case let .invalidSNNThreshold(value):
            return "router.snn.threshold must be in (0, 1] (got \(value))"
        case let .invalidSNNDeltaXRange(min, max):
            return "router.snn.delta_x_range must satisfy min ≥ 1 and max ≥ min (got [\(min), \(max)])"
        case let .invalidSNNDeltaYRange(min, max):
            return "router.snn.delta_y_range must include 0 and have min ≤ max (got [\(min), \(max)])"
        case let .invalidAlpha(value):
            return "router.alpha must be in (0, 1] (got \(value))"
        case let .invalidEnergyFloor(value):
            return "router.energy_floor must be ≥ 0 (got \(value))"
        case let .invalidSNNTimeStep(value):
            return "router.snn.dt must be ≥ 1 (got \(value))"
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
    }

    public struct Logging: Decodable {
        public let defaultLevel: LogLevel
        public let signposts: Bool
        public let destinations: [Destination]
        public let levelsOverride: [String: LogLevel]
        public let timestampKind: TimestampKind

        enum CodingKeys: String, CodingKey {
            case defaultLevel = "default_level"
            case signposts
            case destinations
            case levelsOverride = "levels_override"
            case timestampKind = "timestamp_kind"
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
        public let layers: Int
        public let nodesPerLayer: Int
        public let snn: SNN
        public let alpha: Double
        public let energyFloor: Double
        public let energyConstraints: EnergyConstraints
        public let training: Training

        enum CodingKeys: String, CodingKey {
            case layers
            case nodesPerLayer = "nodes_per_layer"
            case snn
            case alpha
            case energyFloor = "energy_floor"
            case energyConstraints = "energy_constraints"
            case training
        }

        public struct SNN: Decodable {
            public let parameterCount: Int
            public let decay: Double
            public let threshold: Double
            public let resetValue: Double
            public let deltaXRange: IntRange
            public let deltaYRange: IntRange
            public let surrogate: String
            public let dt: Int

            enum CodingKeys: String, CodingKey {
                case parameterCount = "parameter_count"
                case decay
                case threshold
                case resetValue = "reset_value"
                case deltaXRange = "delta_x_range"
                case deltaYRange = "delta_y_range"
                case surrogate
                case dt
            }

            public struct IntRange: Decodable {
                public let min: Int
                public let max: Int

                public init(min: Int, max: Int) {
                    self.min = min
                    self.max = max
                }

                public init(from decoder: Decoder) throws {
                    var container = try decoder.unkeyedContainer()
                    let min = try container.decode(Int.self)
                    let max = try container.decode(Int.self)
                    if !container.isAtEnd {
                        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected exactly two elements in range")
                    }
                    self.min = min
                    self.max = max
                }
            }
        }

        public struct EnergyConstraints: Decodable {
            public let energyBase: Int

            enum CodingKeys: String, CodingKey {
                case energyBase = "energy_base"
            }
        }

        public struct Training: Decodable {
            public let optimizer: Optimizer
            public let losses: Losses
        }

        public struct Optimizer: Decodable {
            public let type: String
            public let lr: Double
            public let beta1: Double
            public let beta2: Double
            public let eps: Double
        }

        public struct Losses: Decodable {
            public let energyBalanceWeight: Double
            public let jumpPenaltyWeight: Double
            public let spikeRateTarget: Double

            enum CodingKeys: String, CodingKey {
                case energyBalanceWeight = "energy_balance_weight"
                case jumpPenaltyWeight = "jump_penalty_weight"
                case spikeRateTarget = "spike_rate_target"
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
}
