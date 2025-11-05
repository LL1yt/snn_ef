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
        try ensureBlockSize(capsule: root.capsule)
        try ensureLoggingDestinations(logging: root.logging)
        try ensureProcessRegistry(root.processRegistry)
        try ensureOverridesWithinRegistry(logging: root.logging, registry: root.processRegistry)
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
        if flow.dynamics.maxSpeed <= 0 {
            throw ConfigError.invalidFlowParameter("dynamics.max_speed must be > 0")
        }
        if flow.dynamics.energyAlpha <= 0 || flow.dynamics.energyAlpha > 1 {
            throw ConfigError.invalidFlowParameter("dynamics.energy_alpha must be in (0, 1]")
        }
        if flow.dynamics.energyFloor < 0 {
            throw ConfigError.invalidEnergyFloor(flow.dynamics.energyFloor)
        }
        // Projection
        if flow.projection.shape.lowercased() != "circle" {
            throw ConfigError.invalidFlowParameter("projection.shape must be 'circle' in this profile")
        }
        if flow.projection.bins != router.energyConstraints.energyBase {
            throw ConfigError.invalidFlowParameter("projection.bins must equal energy_constraints.energy_base")
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
    // Flow router validation
    case invalidRouterBackend(String)
    case invalidEnergyFloor(Double)
    case invalidFlowParameter(String)

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
            public let seedLayout: String
            public let seedRadius: Double
            public let lif: LIF
            public let dynamics: Dynamics
            public let interactions: Interactions
            public let projection: Projection

            enum CodingKeys: String, CodingKey {
                case T
                case radius
                case seedLayout = "seed_layout"
                case seedRadius = "seed_radius"
                case lif
                case dynamics
                case interactions
                case projection
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
                public let noiseStdPos: Double
                public let noiseStdDir: Double
                public let maxSpeed: Double
                public let energyAlpha: Double
                public let energyFloor: Double

                enum CodingKeys: String, CodingKey {
                    case radialBias = "radial_bias"
                    case noiseStdPos = "noise_std_pos"
                    case noiseStdDir = "noise_std_dir"
                    case maxSpeed = "max_speed"
                    case energyAlpha = "energy_alpha"
                    case energyFloor = "energy_floor"
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

                enum CodingKeys: String, CodingKey {
                    case shape
                    case bins
                    case binSmoothing = "bin_smoothing"
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
}
