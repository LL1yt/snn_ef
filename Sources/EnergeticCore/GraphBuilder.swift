import Foundation

/// Builds graph structures from configuration, primarily lattice-style graphs
/// with local and jump connections.
public struct GraphBuilder {

    // MARK: - Public API

    /// Builds a lattice graph from the given configuration.
    ///
    /// Lattice structure:
    /// - Layer 0: input nodes (no incoming edges)
    /// - Layers 1..L-2: nodes with local (layer j+1) and jump (layer j+2) neighbors
    /// - Layer L-1: output nodes (no outgoing edges)
    ///
    /// - Parameter config: Graph configuration
    /// - Returns: A fully constructed Graph
    /// - Throws: `GraphError.invalidConfiguration` if config is invalid
    public static func buildLattice(config: GraphConfig) throws -> Graph {
        // Validate configuration
        try validateConfig(config)

        // Build edge list
        let edges = try buildEdgeList(config: config)

        // Convert to CSR format
        let (rowPtr, colIdx, weights) = convertToCSR(
            edges: edges,
            numNodes: config.totalNodes
        )

        // Initialize positional embeddings
        let positions = initializePositions(config: config)

        // Create graph
        return try Graph(
            rowPtr: rowPtr,
            colIdx: colIdx,
            weights: weights,
            config: config,
            nodePositions: positions
        )
    }

    // MARK: - Configuration Validation

    private static func validateConfig(_ config: GraphConfig) throws {
        guard config.layers >= 1 else {
            throw GraphError.invalidConfiguration("layers must be >= 1")
        }

        guard config.nodesPerLayer >= 1 else {
            throw GraphError.invalidConfiguration("nodesPerLayer must be >= 1")
        }

        guard config.localNeighbors >= 0 else {
            throw GraphError.invalidConfiguration("localNeighbors must be >= 0")
        }

        guard config.jumpNeighbors >= 0 else {
            throw GraphError.invalidConfiguration("jumpNeighbors must be >= 0")
        }

        // Warn if neighbors exceed layer size (not an error, but suboptimal)
        if config.localNeighbors > config.nodesPerLayer {
            // This is allowed, will just connect to available nodes
        }
    }

    // MARK: - Edge List Construction

    /// Builds a list of edges with source, destination, and initial weights.
    private static func buildEdgeList(config: GraphConfig) throws -> [(src: Int, dst: Int, weight: Float)] {
        var edges: [(Int, Int, Float)] = []
        edges.reserveCapacity(config.estimatedEdges)

        for layer in 0..<config.layers {
            for nodeIdx in 0..<config.nodesPerLayer {
                let srcFlatIdx = layer * config.nodesPerLayer + nodeIdx

                // Generate local edges (to layer + 1)
                if layer + 1 < config.layers {
                    let localEdges = generateLocalEdges(
                        srcLayer: layer,
                        srcIndex: nodeIdx,
                        config: config
                    )
                    edges.append(contentsOf: localEdges)
                }

                // Generate jump edges (to layer + 2)
                if layer + 2 < config.layers {
                    let jumpEdges = generateJumpEdges(
                        srcLayer: layer,
                        srcIndex: nodeIdx,
                        config: config
                    )
                    edges.append(contentsOf: jumpEdges)
                }
            }
        }

        return edges
    }

    /// Generates local edges (to next layer) for a source node.
    ///
    /// Strategy: Connect to `localNeighbors` nodes in the next layer,
    /// centered around the same index with some spread.
    private static func generateLocalEdges(
        srcLayer: Int,
        srcIndex: Int,
        config: GraphConfig
    ) -> [(src: Int, dst: Int, weight: Float)] {
        let srcFlatIdx = srcLayer * config.nodesPerLayer + srcIndex
        let dstLayer = srcLayer + 1

        var edges: [(Int, Int, Float)] = []
        edges.reserveCapacity(config.localNeighbors)

        guard dstLayer < config.layers else { return edges }

        // Connect to neighbors centered around same index
        // Spread: [-spread, +spread] around srcIndex
        let spread = (config.localNeighbors + 1) / 2

        // Calculate target indices with wraparound
        var targetIndices: Set<Int> = []

        for offset in -spread...spread {
            if targetIndices.count >= config.localNeighbors {
                break
            }

            var targetIdx = srcIndex + offset

            // Clamp to valid range (no wraparound for simplicity)
            if targetIdx < 0 {
                targetIdx = 0
            } else if targetIdx >= config.nodesPerLayer {
                targetIdx = config.nodesPerLayer - 1
            }

            targetIndices.insert(targetIdx)
        }

        // If we still need more neighbors, add random ones
        while targetIndices.count < config.localNeighbors && targetIndices.count < config.nodesPerLayer {
            let randomIdx = Int.random(in: 0..<config.nodesPerLayer)
            targetIndices.insert(randomIdx)
        }

        // Create edges
        for dstIndex in targetIndices.sorted() {
            let dstFlatIdx = dstLayer * config.nodesPerLayer + dstIndex
            edges.append((srcFlatIdx, dstFlatIdx, 1.0))
        }

        return edges
    }

    /// Generates jump edges (to layer + 2) for a source node.
    ///
    /// Strategy: Connect to `jumpNeighbors` nodes two layers ahead,
    /// with random selection for diversity.
    private static func generateJumpEdges(
        srcLayer: Int,
        srcIndex: Int,
        config: GraphConfig
    ) -> [(src: Int, dst: Int, weight: Float)] {
        let srcFlatIdx = srcLayer * config.nodesPerLayer + srcIndex
        let dstLayer = srcLayer + 2

        var edges: [(Int, Int, Float)] = []
        edges.reserveCapacity(config.jumpNeighbors)

        guard dstLayer < config.layers else { return edges }
        guard config.jumpNeighbors > 0 else { return edges }

        // Select random target indices (could be deterministic with seed)
        var targetIndices: Set<Int> = []

        // Start with same index as anchor
        targetIndices.insert(srcIndex % config.nodesPerLayer)

        // Add random neighbors
        while targetIndices.count < config.jumpNeighbors && targetIndices.count < config.nodesPerLayer {
            let randomIdx = Int.random(in: 0..<config.nodesPerLayer)
            targetIndices.insert(randomIdx)
        }

        // Create edges
        for dstIndex in targetIndices.sorted() {
            let dstFlatIdx = dstLayer * config.nodesPerLayer + dstIndex
            edges.append((srcFlatIdx, dstFlatIdx, 1.0))
        }

        return edges
    }

    // MARK: - CSR Conversion

    /// Converts an edge list to CSR format.
    ///
    /// - Parameters:
    ///   - edges: List of (src, dst, weight) tuples
    ///   - numNodes: Total number of nodes
    /// - Returns: (rowPtr, colIdx, weights) in CSR format
    private static func convertToCSR(
        edges: [(src: Int, dst: Int, weight: Float)],
        numNodes: Int
    ) -> (rowPtr: [Int], colIdx: [Int], weights: [Float]) {
        // Sort edges by source node for CSR construction
        let sortedEdges = edges.sorted { $0.src < $1.src }

        var rowPtr = Array(repeating: 0, count: numNodes + 1)
        var colIdx: [Int] = []
        var weights: [Float] = []

        colIdx.reserveCapacity(sortedEdges.count)
        weights.reserveCapacity(sortedEdges.count)

        // Build CSR
        var currentSrc = 0
        var edgeCount = 0

        for (src, dst, weight) in sortedEdges {
            // Fill rowPtr for nodes with no edges
            while currentSrc <= src {
                rowPtr[currentSrc] = edgeCount
                currentSrc += 1
            }

            colIdx.append(dst)
            weights.append(weight)
            edgeCount += 1
        }

        // Fill remaining rowPtr entries
        while currentSrc <= numNodes {
            rowPtr[currentSrc] = edgeCount
            currentSrc += 1
        }

        return (rowPtr, colIdx, weights)
    }

    // MARK: - Positional Embeddings

    /// Initializes positional embeddings for all nodes.
    ///
    /// Position encoding:
    /// - x = layer / (layers - 1) ∈ [0, 1] (0 for single layer)
    /// - y = index / nodesPerLayer ∈ [0, 1]
    ///
    /// - Parameter config: Graph configuration
    /// - Returns: Array of SIMD2<Float> positions
    private static func initializePositions(config: GraphConfig) -> [SIMD2<Float>] {
        var positions: [SIMD2<Float>] = []
        positions.reserveCapacity(config.totalNodes)

        let layerDenom = max(config.layers - 1, 1)
        let nodeDenom = max(config.nodesPerLayer - 1, 1)

        for layer in 0..<config.layers {
            for nodeIdx in 0..<config.nodesPerLayer {
                let x = Float(layer) / Float(layerDenom)
                let y = Float(nodeIdx) / Float(nodeDenom)
                positions.append(SIMD2(x, y))
            }
        }

        return positions
    }
}

// MARK: - Seeded Graph Builder

extension GraphBuilder {
    /// Builds a lattice graph with a fixed random seed for reproducibility.
    ///
    /// - Parameters:
    ///   - config: Graph configuration
    ///   - seed: Random seed for edge generation
    /// - Returns: A fully constructed Graph
    /// - Throws: `GraphError.invalidConfiguration` if config is invalid
    public static func buildLattice(config: GraphConfig, seed: UInt64) throws -> Graph {
        // Set random seed (Note: Swift doesn't have global seed, this is a placeholder)
        // In practice, you'd use a custom RNG or SystemRandomNumberGenerator with seed

        // For now, build without explicit seeding
        // TODO: Implement seeded RNG for reproducible graphs
        return try buildLattice(config: config)
    }
}
