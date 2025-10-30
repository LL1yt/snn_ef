import Foundation

/// Graph representation using Compressed Sparse Row (CSR) format for efficient
/// neighbor traversal and memory locality.
///
/// CSR format stores the graph as:
/// - `rowPtr[i]..rowPtr[i+1]`: range of edges for node i
/// - `colIdx[j]`: destination node index for edge j
/// - `weights[j]`: weight for edge j
///
/// This format is cache-friendly and well-suited for forward/backward passes.
public struct Graph: Sendable {

    // MARK: - CSR Structure

    /// Row pointers: rowPtr[nodeIdx] gives the start index in colIdx/weights
    /// for edges originating from nodeIdx. Length: numNodes + 1
    public let rowPtr: [Int]

    /// Column indices: colIdx[edgeIdx] gives the destination node index
    /// for edge edgeIdx. Length: numEdges
    public let colIdx: [Int]

    /// Edge weights: weights[edgeIdx] is the energy weight for edge edgeIdx.
    /// Length: numEdges (mutable for learning)
    public var weights: [Float]

    // MARK: - Metadata

    /// Configuration used to build this graph
    public let config: GraphConfig

    /// Total number of nodes
    public let numNodes: Int

    /// Total number of edges
    public let numEdges: Int

    /// Positional embeddings for each node (x, y) where:
    /// - x = layer / (layers - 1) ∈ [0, 1]
    /// - y = index / nodesPerLayer ∈ [0, 1]
    public let nodePositions: [SIMD2<Float>]

    // MARK: - Initialization

    /// Initializes a graph with the given CSR structure and metadata.
    ///
    /// - Parameters:
    ///   - rowPtr: CSR row pointers (length: numNodes + 1)
    ///   - colIdx: CSR column indices (length: numEdges)
    ///   - weights: Edge weights (length: numEdges)
    ///   - config: Graph configuration
    ///   - nodePositions: Positional embeddings for nodes
    ///
    /// - Throws: `GraphError.invalidConfiguration` if dimensions are inconsistent
    public init(
        rowPtr: [Int],
        colIdx: [Int],
        weights: [Float],
        config: GraphConfig,
        nodePositions: [SIMD2<Float>]
    ) throws {
        // Validate dimensions
        guard rowPtr.count == config.totalNodes + 1 else {
            throw GraphError.invalidConfiguration(
                "rowPtr length (\(rowPtr.count)) must be totalNodes + 1 (\(config.totalNodes + 1))"
            )
        }

        guard colIdx.count == weights.count else {
            throw GraphError.invalidConfiguration(
                "colIdx length (\(colIdx.count)) must match weights length (\(weights.count))"
            )
        }

        guard nodePositions.count == config.totalNodes else {
            throw GraphError.invalidConfiguration(
                "nodePositions length (\(nodePositions.count)) must match totalNodes (\(config.totalNodes))"
            )
        }

        // Validate rowPtr is monotonic
        for i in 0..<rowPtr.count - 1 {
            guard rowPtr[i] <= rowPtr[i + 1] else {
                throw GraphError.invalidConfiguration(
                    "rowPtr must be monotonically increasing at index \(i)"
                )
            }
        }

        // Validate rowPtr end matches edge count
        guard rowPtr.last == colIdx.count else {
            throw GraphError.invalidConfiguration(
                "rowPtr last element (\(rowPtr.last ?? -1)) must equal edge count (\(colIdx.count))"
            )
        }

        // Validate colIdx bounds
        for (idx, col) in colIdx.enumerated() {
            guard col >= 0 && col < config.totalNodes else {
                throw GraphError.invalidConfiguration(
                    "colIdx[\(idx)] = \(col) out of bounds [0, \(config.totalNodes))"
                )
            }
        }

        self.rowPtr = rowPtr
        self.colIdx = colIdx
        self.weights = weights
        self.config = config
        self.numNodes = config.totalNodes
        self.numEdges = colIdx.count
        self.nodePositions = nodePositions
    }

    // MARK: - Node Index Conversion

    /// Converts a NodeID to a flat node index.
    public func nodeIndex(_ node: NodeID) -> Int {
        node.layer * config.nodesPerLayer + node.index
    }

    /// Converts a flat node index to a NodeID.
    public func nodeID(from index: Int) -> NodeID {
        let layer = index / config.nodesPerLayer
        let idx = index % config.nodesPerLayer
        return NodeID(layer: layer, index: idx)
    }

    /// Validates a NodeID is within bounds.
    public func isValid(_ node: NodeID) -> Bool {
        return node.layer >= 0 && node.layer < config.layers &&
               node.index >= 0 && node.index < config.nodesPerLayer
    }

    // MARK: - Edge Navigation

    /// Returns the range of edge indices for a given node.
    ///
    /// - Parameter node: The source node
    /// - Returns: Range of edge indices in colIdx/weights
    /// - Throws: `GraphError.invalidNodeID` if node is out of bounds
    public func edgeRange(for node: NodeID) throws -> Range<Int> {
        guard isValid(node) else {
            throw GraphError.invalidNodeID(node)
        }

        let idx = nodeIndex(node)
        return rowPtr[idx]..<rowPtr[idx + 1]
    }

    /// Returns the range of edge indices for a flat node index.
    public func edgeRange(for nodeIdx: Int) throws -> Range<Int> {
        guard nodeIdx >= 0 && nodeIdx < numNodes else {
            throw GraphError.csrIndexOutOfBounds
        }
        return rowPtr[nodeIdx]..<rowPtr[nodeIdx + 1]
    }

    /// Returns the number of outgoing edges from a node.
    public func outDegree(of node: NodeID) throws -> Int {
        let range = try edgeRange(for: node)
        return range.count
    }

    /// Returns the destination node IDs for all edges from a source node.
    public func neighbors(of node: NodeID) throws -> [NodeID] {
        let range = try edgeRange(for: node)
        return colIdx[range].map { nodeID(from: $0) }
    }

    /// Returns the destination node indices for all edges from a flat node index.
    public func neighbors(of nodeIdx: Int) throws -> ArraySlice<Int> {
        let range = try edgeRange(for: nodeIdx)
        return colIdx[range]
    }

    // MARK: - Edge Lookup

    /// Finds the edge index for a given (src, dst) pair.
    ///
    /// - Returns: Edge index in colIdx/weights, or nil if not found
    public func findEdge(from src: NodeID, to dst: NodeID) throws -> Int? {
        guard isValid(src), isValid(dst) else {
            throw GraphError.invalidNodeID(isValid(src) ? dst : src)
        }

        let srcIdx = nodeIndex(src)
        let dstIdx = nodeIndex(dst)
        let range = rowPtr[srcIdx]..<rowPtr[srcIdx + 1]

        for edgeIdx in range {
            if colIdx[edgeIdx] == dstIdx {
                return edgeIdx
            }
        }

        return nil
    }

    /// Gets the weight of an edge from src to dst.
    ///
    /// - Throws: `GraphError.edgeNotFound` if edge doesn't exist
    public func edgeWeight(from src: NodeID, to dst: NodeID) throws -> Float {
        guard let edgeIdx = try findEdge(from: src, to: dst) else {
            throw GraphError.edgeNotFound(src: src, dst: dst)
        }
        return weights[edgeIdx]
    }

    /// Sets the weight of an edge from src to dst.
    ///
    /// - Throws: `GraphError.edgeNotFound` if edge doesn't exist
    public mutating func setWeight(from src: NodeID, to dst: NodeID, weight: Float) throws {
        guard let edgeIdx = try findEdge(from: src, to: dst) else {
            throw GraphError.edgeNotFound(src: src, dst: dst)
        }
        weights[edgeIdx] = weight
    }

    // MARK: - Utilities

    /// Returns statistics about the graph structure.
    public func statistics() -> GraphStatistics {
        var minDegree = Int.max
        var maxDegree = 0
        var totalDegree = 0

        for i in 0..<numNodes {
            let degree = rowPtr[i + 1] - rowPtr[i]
            minDegree = min(minDegree, degree)
            maxDegree = max(maxDegree, degree)
            totalDegree += degree
        }

        let avgDegree = numNodes > 0 ? Float(totalDegree) / Float(numNodes) : 0.0

        return GraphStatistics(
            numNodes: numNodes,
            numEdges: numEdges,
            minOutDegree: minDegree == Int.max ? 0 : minDegree,
            maxOutDegree: maxDegree,
            avgOutDegree: avgDegree
        )
    }
}

// MARK: - Graph Statistics

/// Statistics about graph structure.
public struct GraphStatistics: CustomStringConvertible {
    public let numNodes: Int
    public let numEdges: Int
    public let minOutDegree: Int
    public let maxOutDegree: Int
    public let avgOutDegree: Float

    public var description: String {
        """
        Graph Statistics:
          Nodes: \(numNodes)
          Edges: \(numEdges)
          Out-degree: min=\(minOutDegree), max=\(maxOutDegree), avg=\(String(format: "%.2f", avgOutDegree))
        """
    }
}
