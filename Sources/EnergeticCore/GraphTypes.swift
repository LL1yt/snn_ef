import Foundation

// MARK: - Node Identifier

/// Identifies a unique node in the graph by layer and index within that layer.
public struct NodeID: Hashable, Sendable, CustomStringConvertible {
    /// Layer index (0 = input layer, L-1 = output layer)
    public let layer: Int

    /// Index within the layer (0..<nodesPerLayer)
    public let index: Int

    public init(layer: Int, index: Int) {
        self.layer = layer
        self.index = index
    }

    public var description: String {
        "Node(L\(layer):\(index))"
    }
}

// MARK: - Edge

/// Represents a directed edge in the graph with an energy weight.
public struct Edge: Sendable, CustomStringConvertible {
    /// Source node
    public let src: NodeID

    /// Destination node
    public let dst: NodeID

    /// Energy weight (mutable for learning)
    public var weight: Float

    public init(src: NodeID, dst: NodeID, weight: Float = 1.0) {
        self.src = src
        self.dst = dst
        self.weight = weight
    }

    public var description: String {
        "\(src) → \(dst) [w=\(String(format: "%.3f", weight))]"
    }
}

// MARK: - Layer Configuration

/// Configuration for a single layer in the graph.
public struct LayerConfig: Sendable, Equatable {
    /// Number of nodes in this layer
    public let nodeCount: Int

    /// Number of local neighbors (connections to next layer)
    public let localNeighbors: Int

    /// Number of jump neighbors (connections to layer+2)
    public let jumpNeighbors: Int

    public init(nodeCount: Int, localNeighbors: Int, jumpNeighbors: Int) {
        self.nodeCount = nodeCount
        self.localNeighbors = localNeighbors
        self.jumpNeighbors = jumpNeighbors
    }
}

// MARK: - Graph Configuration

/// Global configuration for the entire graph, typically loaded from ConfigCenter.
public struct GraphConfig: Sendable, Equatable {
    /// Number of layers in the graph
    public let layers: Int

    /// Number of nodes per layer (uniform for simplicity in v1)
    public let nodesPerLayer: Int

    /// Number of local neighbors (edges to layer j+1)
    public let localNeighbors: Int

    /// Number of jump neighbors (edges to layer j+2)
    public let jumpNeighbors: Int

    public init(
        layers: Int,
        nodesPerLayer: Int,
        localNeighbors: Int,
        jumpNeighbors: Int
    ) {
        self.layers = layers
        self.nodesPerLayer = nodesPerLayer
        self.localNeighbors = localNeighbors
        self.jumpNeighbors = jumpNeighbors
    }

    /// Total number of nodes in the graph
    public var totalNodes: Int {
        layers * nodesPerLayer
    }

    /// Estimated number of edges (upper bound for CSR allocation)
    public var estimatedEdges: Int {
        // Most layers have local + jump edges
        // First layer: only outgoing
        // Last layer: no outgoing
        // Second-to-last: only local (no jump)

        let middleLayers = max(0, layers - 2)
        let middleEdges = middleLayers * nodesPerLayer * (localNeighbors + jumpNeighbors)

        // First layer (no jump to layer -1)
        let firstLayerEdges = (layers > 1) ? nodesPerLayer * localNeighbors : 0

        return middleEdges + firstLayerEdges
    }
}

// MARK: - Graph Errors

/// Errors that can occur during graph construction or manipulation.
public enum GraphError: Error, CustomStringConvertible {
    case invalidNodeID(NodeID)
    case invalidLayerIndex(Int)
    case invalidConfiguration(String)
    case edgeNotFound(src: NodeID, dst: NodeID)
    case csrIndexOutOfBounds

    public var description: String {
        switch self {
        case .invalidNodeID(let node):
            return "Invalid node ID: \(node)"
        case .invalidLayerIndex(let layer):
            return "Invalid layer index: \(layer)"
        case .invalidConfiguration(let reason):
            return "Invalid graph configuration: \(reason)"
        case .edgeNotFound(let src, let dst):
            return "Edge not found: \(src) → \(dst)"
        case .csrIndexOutOfBounds:
            return "CSR index out of bounds"
        }
    }
}
