import Foundation

/// Factory for creating SNN router components and validating configurations.
public struct RouterFactory {
    
    // MARK: - Public API
    
    /// Creates a TemporalGrid from RouterConfig.
    ///
    /// - Parameter config: Router configuration
    /// - Returns: Initialized TemporalGrid
    /// - Throws: `RouterError.invalidConfiguration` if validation fails
    public static func createGrid(from config: RouterConfig) throws -> TemporalGrid {
        try validateConfig(config)
        return try TemporalGrid(layers: config.layers, nodesPerLayer: config.nodesPerLayer)
    }
    
    /// Creates a RouterConfig from raw parameters with validation.
    ///
    /// - Parameters:
    ///   - layers: Number of layers
    ///   - nodesPerLayer: Number of nodes per layer
    ///   - snn: SNN configuration
    ///   - alpha: Energy decay factor
    ///   - energyFloor: Minimum energy threshold
    ///   - energyBase: Energy base (must match capsule.base)
    /// - Returns: Validated RouterConfig
    /// - Throws: `RouterError.invalidConfiguration` if validation fails
    public static func createConfig(
        layers: Int,
        nodesPerLayer: Int,
        snn: SNNConfig,
        alpha: Float,
        energyFloor: Float,
        energyBase: Int
    ) throws -> RouterConfig {
        let config = RouterConfig(
            layers: layers,
            nodesPerLayer: nodesPerLayer,
            snn: snn,
            alpha: alpha,
            energyFloor: energyFloor,
            energyBase: energyBase
        )
        try validateConfig(config)
        return config
    }
    
    /// Creates an SNNConfig from raw parameters with validation.
    ///
    /// - Parameters:
    ///   - parameterCount: Total trainable parameters
    ///   - decay: Membrane decay factor
    ///   - threshold: Spike threshold
    ///   - resetValue: Post-spike reset value
    ///   - deltaXRange: X jump range
    ///   - deltaYRange: Y movement range
    ///   - surrogate: Surrogate function name
    ///   - dt: Time step
    /// - Returns: Validated SNNConfig
    /// - Throws: `RouterError.invalidConfiguration` if validation fails
    public static func createSNNConfig(
        parameterCount: Int,
        decay: Float,
        threshold: Float,
        resetValue: Float,
        deltaXRange: ClosedRange<Int>,
        deltaYRange: ClosedRange<Int>,
        surrogate: String,
        dt: Int
    ) throws -> SNNConfig {
        let config = SNNConfig(
            parameterCount: parameterCount,
            decay: decay,
            threshold: threshold,
            resetValue: resetValue,
            deltaXRange: deltaXRange,
            deltaYRange: deltaYRange,
            surrogate: surrogate,
            dt: dt
        )
        try validateSNNConfig(config)
        return config
    }
    
    // MARK: - Validation
    
    /// Validates RouterConfig constraints.
    private static func validateConfig(_ config: RouterConfig) throws {
        // Grid dimensions
        guard config.layers >= 1 else {
            throw RouterError.invalidConfiguration("layers must be >= 1, got \(config.layers)")
        }
        
        guard config.nodesPerLayer >= 1 else {
            throw RouterError.invalidConfiguration("nodesPerLayer must be >= 1, got \(config.nodesPerLayer)")
        }
        
        // Energy parameters
        guard config.alpha > 0 && config.alpha <= 1 else {
            throw RouterError.invalidConfiguration("alpha must be in (0, 1], got \(config.alpha)")
        }
        
        guard config.energyFloor >= 0 else {
            throw RouterError.invalidConfiguration("energyFloor must be >= 0, got \(config.energyFloor)")
        }
        
        guard config.energyBase > 0 else {
            throw RouterError.invalidConfiguration("energyBase must be > 0, got \(config.energyBase)")
        }
        
        // Validate nested SNN config
        try validateSNNConfig(config.snn)
    }
    
    /// Validates SNNConfig constraints.
    private static func validateSNNConfig(_ config: SNNConfig) throws {
        // Parameter count
        guard config.parameterCount >= 1 else {
            throw RouterError.invalidConfiguration("parameterCount must be >= 1, got \(config.parameterCount)")
        }
        
        // Decay
        guard config.decay > 0 && config.decay < 1 else {
            throw RouterError.invalidConfiguration("decay must be in (0, 1), got \(config.decay)")
        }
        
        // Threshold
        guard config.threshold > 0 && config.threshold <= 1 else {
            throw RouterError.invalidConfiguration("threshold must be in (0, 1], got \(config.threshold)")
        }
        
        // Delta X range
        guard config.deltaXRange.lowerBound >= 1 else {
            throw RouterError.invalidConfiguration(
                "deltaXRange.lowerBound must be >= 1, got \(config.deltaXRange.lowerBound)"
            )
        }
        
        guard config.deltaXRange.upperBound >= config.deltaXRange.lowerBound else {
            throw RouterError.invalidConfiguration(
                "deltaXRange.upperBound must be >= lowerBound"
            )
        }
        
        // Delta Y range must contain 0
        guard config.deltaYRange.contains(0) else {
            throw RouterError.invalidConfiguration(
                "deltaYRange must contain 0, got [\(config.deltaYRange.lowerBound), \(config.deltaYRange.upperBound)]"
            )
        }
        
        // Time step
        guard config.dt >= 1 else {
            throw RouterError.invalidConfiguration("dt must be >= 1, got \(config.dt)")
        }
        
        // Surrogate function (check known types)
        let validSurrogates = ["fast_sigmoid", "tanh_clip"]
        guard validSurrogates.contains(config.surrogate) else {
            throw RouterError.invalidSurrogate(config.surrogate)
        }
    }
}

// MARK: - Test Helpers

extension RouterFactory {
    /// Creates a minimal valid configuration for testing.
    public static func createTestConfig() -> RouterConfig {
        let snn = SNNConfig(
            parameterCount: 128,
            decay: 0.9,
            threshold: 0.5,
            resetValue: 0.0,
            deltaXRange: 1...3,
            deltaYRange: -10...10,
            surrogate: "fast_sigmoid",
            dt: 1
        )
        
        return RouterConfig(
            layers: 5,
            nodesPerLayer: 64,
            snn: snn,
            alpha: 0.95,
            energyFloor: 1e-5,
            energyBase: 256
        )
    }
}

// MARK: - ConfigCenter Integration

#if canImport(SharedInfrastructure)
import SharedInfrastructure

extension RouterFactory {
    /// Creates RouterConfig from ConfigCenter's ConfigRoot.Router.
    ///
    /// - Parameter routerConfig: Router configuration from YAML
    /// - Returns: Validated RouterConfig
    /// - Throws: `RouterError.invalidConfiguration` if validation fails
    public static func createFrom(_ routerConfig: ConfigRoot.Router) throws -> RouterConfig {
        let snn = SNNConfig(
            parameterCount: routerConfig.snn.parameterCount,
            decay: Float(routerConfig.snn.decay),
            threshold: Float(routerConfig.snn.threshold),
            resetValue: Float(routerConfig.snn.resetValue),
            deltaXRange: routerConfig.snn.deltaXRange.min...routerConfig.snn.deltaXRange.max,
            deltaYRange: routerConfig.snn.deltaYRange.min...routerConfig.snn.deltaYRange.max,
            surrogate: routerConfig.snn.surrogate,
            dt: routerConfig.snn.dt
        )
        
        return try createConfig(
            layers: routerConfig.layers,
            nodesPerLayer: routerConfig.nodesPerLayer,
            snn: snn,
            alpha: Float(routerConfig.alpha),
            energyFloor: Float(routerConfig.energyFloor),
            energyBase: routerConfig.energyConstraints.energyBase
        )
    }
}
#endif
