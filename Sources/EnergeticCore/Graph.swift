import Foundation

/// TemporalGrid represents the spatial layout of the SNN router.
/// Energy packets move through layers (X axis) and nodes within layers (Y axis).
/// This replaces the old CSR-based graph representation.
public struct TemporalGrid: Sendable {
    
    // MARK: - Grid Structure
    
    /// Number of layers (X dimension)
    public let layers: Int
    
    /// Number of nodes per layer (Y dimension)
    public let nodesPerLayer: Int
    
    /// Total number of nodes in the grid
    public let totalNodes: Int
    
    // MARK: - Initialization
    
    /// Creates a temporal grid with specified dimensions.
    ///
    /// - Parameters:
    ///   - layers: Number of layers, must be >= 1
    ///   - nodesPerLayer: Number of nodes per layer, must be >= 1
    /// - Throws: `RouterError.invalidConfiguration` if dimensions invalid
    public init(layers: Int, nodesPerLayer: Int) throws {
        guard layers >= 1 else {
            throw RouterError.invalidConfiguration("layers must be >= 1, got \(layers)")
        }
        
        guard nodesPerLayer >= 1 else {
            throw RouterError.invalidConfiguration("nodesPerLayer must be >= 1, got \(nodesPerLayer)")
        }
        
        self.layers = layers
        self.nodesPerLayer = nodesPerLayer
        self.totalNodes = layers * nodesPerLayer
    }
    
    // MARK: - Navigation
    
    /// Advances X coordinate by one layer (forward step).
    /// Clamps to valid range [0, layers).
    public func advanceForward(_ x: Int) -> Int {
        min(x + 1, layers - 1)
    }
    
    /// Wraps Y coordinate to valid range using modulo.
    public func wrapY(_ y: Int) -> Int {
        ((y % nodesPerLayer) + nodesPerLayer) % nodesPerLayer
    }
    
    /// Clamps X coordinate to valid range [0, layers).
    public func clampX(_ x: Int) -> Int {
        max(0, min(x, layers - 1))
    }
    
    /// Checks if X coordinate is the output layer.
    public func isOutputLayer(_ x: Int) -> Bool {
        x >= layers - 1
    }
    
    /// Checks if X coordinate is within bounds.
    public func isValidX(_ x: Int) -> Bool {
        x >= 0 && x < layers
    }
    
    /// Checks if Y coordinate is within bounds.
    public func isValidY(_ y: Int) -> Bool {
        y >= 0 && y < nodesPerLayer
    }
    
    /// Validates packet coordinates.
    public func isValid(x: Int, y: Int) -> Bool {
        isValidX(x) && isValidY(y)
    }
    
    // MARK: - Flat Index Conversion
    
    /// Converts (x, y) coordinates to flat index.
    public func flatIndex(x: Int, y: Int) -> Int {
        x * nodesPerLayer + y
    }
    
    /// Converts flat index to (x, y) coordinates.
    public func coordinates(from index: Int) -> (x: Int, y: Int) {
        let x = index / nodesPerLayer
        let y = index % nodesPerLayer
        return (x, y)
    }
    
    // MARK: - Normalization
    
    /// Normalizes X coordinate to [0, 1].
    public func normalizeX(_ x: Int) -> Float {
        guard layers > 1 else { return 0.0 }
        return Float(x) / Float(layers - 1)
    }
    
    /// Normalizes Y coordinate to [0, 1].
    public func normalizeY(_ y: Int) -> Float {
        guard nodesPerLayer > 1 else { return 0.0 }
        return Float(y) / Float(nodesPerLayer - 1)
    }
    
    /// Returns normalized position for a node.
    public func normalizedPosition(x: Int, y: Int) -> SIMD2<Float> {
        SIMD2(normalizeX(x), normalizeY(y))
    }
    
    // MARK: - Utilities
    
    /// Returns grid statistics.
    public func statistics() -> GridStatistics {
        GridStatistics(
            layers: layers,
            nodesPerLayer: nodesPerLayer,
            totalNodes: totalNodes
        )
    }
}

// MARK: - Grid Statistics

/// Statistics about grid structure.
public struct GridStatistics: CustomStringConvertible {
    public let layers: Int
    public let nodesPerLayer: Int
    public let totalNodes: Int
    
    public var description: String {
        """
        Grid Statistics:
          Layers: \(layers)
          Nodes per layer: \(nodesPerLayer)
          Total nodes: \(totalNodes)
        """
    }
}
