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
        try ensureBlockSize(capsule: root.capsule)
        try ensureLoggingDestinations(logging: root.logging)
        try ensureProcessRegistry(root.processRegistry)
        try ensureOverridesWithinRegistry(logging: root.logging, registry: root.processRegistry)
    }

    private static func ensureAlphabetLength(capsule: ConfigRoot.Capsule) throws {
        #if DEBUG
        let s = capsule.alphabet
        let graphemeCount = s.count
        let scalarCount = s.unicodeScalars.count
        let utf8Count = s.utf8.count
        let uniqueCount = Set(s).count

        var lines: [String] = []
        lines.reserveCapacity(graphemeCount)
        var i = 0
        for ch in s {
            let scalars = String(ch).unicodeScalars
                .map { String(format: "U+%04X", $0.value) }
                .joined(separator: "+")
            lines.append(String(format: "%03d '%@' [%@]", i, String(ch), scalars))
            i += 1
        }

        fputs("""
        [ConfigCenter] Alphabet diagnostics
        base=\(capsule.base)
        graphemes=\(graphemeCount) scalars=\(scalarCount) utf8_bytes=\(utf8Count) unique_graphemes=\(uniqueCount)
        alphabet="\(s)"
        indices:\n\(lines.joined(separator: "\n"))

        """, stderr)
        #endif

        if capsule.alphabet.count != capsule.base {
            throw ConfigError.invalidAlphabetLength(expected: capsule.base, actual: capsule.alphabet.count)
        }
    }

    private static func ensureEnergyBaseMatches(capsule: ConfigRoot.Capsule, router: ConfigRoot.Router) throws {
        if capsule.base != router.energyConstraints.energyBase {
            throw ConfigError.energyBaseMismatch(capsule.base, router.energyConstraints.energyBase)
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
        #if DEBUG
        let overrideKeys = Array(logging.levelsOverride.keys).sorted()
        let registryKeys = Array(registry.keys).sorted()
        fputs("""
        [ConfigCenter] Overrides check
        override_keys=[\(overrideKeys.joined(separator: ", "))]
        registry_keys=[\(registryKeys.joined(separator: ", "))]
        """, stderr)
        #endif
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
        public let prototypes: Prototypes
        public let neighbors: Neighbors
        public let alpha: Double
        public let tau: Double
        public let topK: Int
        public let energyConstraints: EnergyConstraints
        public let optimizer: Optimizer
        public let entropyReg: Double
        public let batchSize: Int
        public let epochs: Int
        public let backend: String
        public let task: String
        public let headless: Bool
        public let checkpoints: Checkpoints
        public let localLearning: LocalLearning

        enum CodingKeys: String, CodingKey {
            case layers
            case nodesPerLayer = "nodes_per_layer"
            case prototypes
            case neighbors
            case alpha
            case tau
            case topK = "top_k"
            case energyConstraints = "energy_constraints"
            case optimizer
            case entropyReg = "entropy_reg"
            case batchSize = "batch_size"
            case epochs
            case backend
            case task
            case headless
            case checkpoints
            case localLearning = "local_learning"
        }

        public struct Prototypes: Decodable {
            public let count: Int
            public let hiddenDim: Int

            enum CodingKeys: String, CodingKey {
                case count
                case hiddenDim = "hidden_dim"
            }
        }

        public struct Neighbors: Decodable {
            public let local: Int
            public let jump: Int
        }

        public struct EnergyConstraints: Decodable {
            public let maxDX: Int
            public let minDX: Int
            public let maxDY: Int
            public let energyBase: Int

            enum CodingKeys: String, CodingKey {
                case maxDX = "max_dx"
                case minDX = "min_dx"
                case maxDY = "max_dy"
                case energyBase = "energy_base"
            }
        }

        public struct Optimizer: Decodable {
            public let type: String
            public let lr: Double
            public let beta1: Double
            public let beta2: Double
            public let eps: Double
        }

        public struct Checkpoints: Decodable {
            public let everySteps: Int
            public let keep: Int

            enum CodingKeys: String, CodingKey {
                case everySteps = "every_steps"
                case keep
            }
        }

        public struct LocalLearning: Decodable {
            public let enabled: Bool
            public let rho: Double
            public let lr: Double
            public let baselineBeta: Double

            enum CodingKeys: String, CodingKey {
                case enabled
                case rho
                case lr
                case baselineBeta = "baseline_beta"
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
