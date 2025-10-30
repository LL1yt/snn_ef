import XCTest
@testable import EnergeticCore

final class GraphTests: XCTestCase {

    // MARK: - Test Helpers

    /// Creates a simple 2-layer graph for testing:
    /// Layer 0: 3 nodes (0, 1, 2)
    /// Layer 1: 2 nodes (3, 4)
    ///
    /// Edges:
    /// Node 0 → [3, 4]
    /// Node 1 → [3]
    /// Node 2 → [4]
    /// Node 3 → []
    /// Node 4 → []
    func makeSimpleGraph() throws -> Graph {
        let config = GraphConfig(
            layers: 2,
            nodesPerLayer: 3,  // Not uniform, but we'll handle it
            localNeighbors: 2,
            jumpNeighbors: 0
        )

        // CSR structure:
        // Node 0: edges [0, 1] → dsts [3, 4]
        // Node 1: edge [2] → dst [3]
        // Node 2: edge [3] → dst [4]
        // Node 3: no edges
        // Node 4: no edges

        let rowPtr = [0, 2, 3, 4, 4, 4]  // 5 nodes + 1
        let colIdx = [3, 4, 3, 4]        // 4 edges
        let weights = [1.0, 1.0, 1.0, 1.0]

        // Positions (approximate for 5 nodes)
        let positions: [SIMD2<Float>] = [
            SIMD2(0.0, 0.0),  // Node 0
            SIMD2(0.0, 0.33), // Node 1
            SIMD2(0.0, 0.67), // Node 2
            SIMD2(1.0, 0.0),  // Node 3
            SIMD2(1.0, 0.5)   // Node 4
        ]

        // Adjust config for actual node count
        let actualConfig = GraphConfig(
            layers: 2,
            nodesPerLayer: 3,
            localNeighbors: 2,
            jumpNeighbors: 0
        )

        // We need to adjust for total nodes = 5, but config expects 2*3=6
        // Let's just use 6 nodes with last one having no edges

        let rowPtr6 = [0, 2, 3, 4, 4, 4, 4]
        let positions6 = positions + [SIMD2(1.0, 1.0)]

        return try Graph(
            rowPtr: rowPtr6,
            colIdx: colIdx,
            weights: weights,
            config: actualConfig,
            nodePositions: positions6
        )
    }

    // MARK: - Initialization Tests

    func testGraphInitialization() throws {
        let config = GraphConfig(layers: 2, nodesPerLayer: 2, localNeighbors: 2, jumpNeighbors: 0)

        let rowPtr = [0, 2, 2, 2, 2]  // 4 nodes, node 0 has 2 edges
        let colIdx = [2, 3]           // edges to nodes 2, 3
        let weights: [Float] = [0.5, 1.0]
        let positions = (0..<4).map { _ in SIMD2<Float>(0, 0) }

        let graph = try Graph(
            rowPtr: rowPtr,
            colIdx: colIdx,
            weights: weights,
            config: config,
            nodePositions: positions
        )

        XCTAssertEqual(graph.numNodes, 4)
        XCTAssertEqual(graph.numEdges, 2)
        XCTAssertEqual(graph.rowPtr.count, 5)
        XCTAssertEqual(graph.colIdx.count, 2)
    }

    func testGraphInitializationInvalidRowPtrLength() {
        let config = GraphConfig(layers: 2, nodesPerLayer: 2, localNeighbors: 1, jumpNeighbors: 0)

        let rowPtr = [0, 1, 2]  // Wrong length (should be 5 for 4 nodes)
        let colIdx = [1, 2]
        let weights: [Float] = [1.0, 1.0]
        let positions = (0..<4).map { _ in SIMD2<Float>(0, 0) }

        XCTAssertThrowsError(try Graph(
            rowPtr: rowPtr,
            colIdx: colIdx,
            weights: weights,
            config: config,
            nodePositions: positions
        )) { error in
            guard case GraphError.invalidConfiguration = error else {
                XCTFail("Expected invalidConfiguration error")
                return
            }
        }
    }

    func testGraphInitializationMismatchedWeights() {
        let config = GraphConfig(layers: 2, nodesPerLayer: 2, localNeighbors: 1, jumpNeighbors: 0)

        let rowPtr = [0, 1, 1, 1, 1]
        let colIdx = [2]
        let weights: [Float] = [1.0, 2.0]  // Wrong length
        let positions = (0..<4).map { _ in SIMD2<Float>(0, 0) }

        XCTAssertThrowsError(try Graph(
            rowPtr: rowPtr,
            colIdx: colIdx,
            weights: weights,
            config: config,
            nodePositions: positions
        )) { error in
            guard case GraphError.invalidConfiguration = error else {
                XCTFail("Expected invalidConfiguration error")
                return
            }
        }
    }

    func testGraphInitializationNonMonotonicRowPtr() {
        let config = GraphConfig(layers: 2, nodesPerLayer: 2, localNeighbors: 1, jumpNeighbors: 0)

        let rowPtr = [0, 2, 1, 2, 2]  // Non-monotonic at index 1→2
        let colIdx = [1, 2]
        let weights: [Float] = [1.0, 1.0]
        let positions = (0..<4).map { _ in SIMD2<Float>(0, 0) }

        XCTAssertThrowsError(try Graph(
            rowPtr: rowPtr,
            colIdx: colIdx,
            weights: weights,
            config: config,
            nodePositions: positions
        )) { error in
            guard case GraphError.invalidConfiguration = error else {
                XCTFail("Expected invalidConfiguration error")
                return
            }
        }
    }

    func testGraphInitializationColIdxOutOfBounds() {
        let config = GraphConfig(layers: 2, nodesPerLayer: 2, localNeighbors: 1, jumpNeighbors: 0)

        let rowPtr = [0, 1, 1, 1, 1]
        let colIdx = [10]  // Out of bounds (only 4 nodes)
        let weights: [Float] = [1.0]
        let positions = (0..<4).map { _ in SIMD2<Float>(0, 0) }

        XCTAssertThrowsError(try Graph(
            rowPtr: rowPtr,
            colIdx: colIdx,
            weights: weights,
            config: config,
            nodePositions: positions
        ))
    }

    // MARK: - Node Index Conversion Tests

    func testNodeIndexConversion() throws {
        let graph = try makeSimpleGraph()

        let node = NodeID(layer: 0, index: 2)
        let idx = graph.nodeIndex(node)
        XCTAssertEqual(idx, 2, "Layer 0, index 2 → flat index 2")

        let node2 = NodeID(layer: 1, index: 1)
        let idx2 = graph.nodeIndex(node2)
        XCTAssertEqual(idx2, 4, "Layer 1, index 1 → flat index 4 (3 nodes per layer)")
    }

    func testNodeIDFromIndex() throws {
        let graph = try makeSimpleGraph()

        let node = graph.nodeID(from: 2)
        XCTAssertEqual(node.layer, 0)
        XCTAssertEqual(node.index, 2)

        let node2 = graph.nodeID(from: 4)
        XCTAssertEqual(node2.layer, 1)
        XCTAssertEqual(node2.index, 1)
    }

    func testNodeValidation() throws {
        let graph = try makeSimpleGraph()

        XCTAssertTrue(graph.isValid(NodeID(layer: 0, index: 0)))
        XCTAssertTrue(graph.isValid(NodeID(layer: 1, index: 2)))

        XCTAssertFalse(graph.isValid(NodeID(layer: 2, index: 0)), "Layer 2 doesn't exist")
        XCTAssertFalse(graph.isValid(NodeID(layer: 0, index: 3)), "Index 3 out of bounds")
        XCTAssertFalse(graph.isValid(NodeID(layer: -1, index: 0)), "Negative layer")
    }

    // MARK: - Edge Navigation Tests

    func testEdgeRange() throws {
        let graph = try makeSimpleGraph()

        let node0 = NodeID(layer: 0, index: 0)
        let range0 = try graph.edgeRange(for: node0)
        XCTAssertEqual(range0, 0..<2, "Node 0 has edges [0, 1]")

        let node1 = NodeID(layer: 0, index: 1)
        let range1 = try graph.edgeRange(for: node1)
        XCTAssertEqual(range1, 2..<3, "Node 1 has edge [2]")

        let node3 = NodeID(layer: 1, index: 0)
        let range3 = try graph.edgeRange(for: node3)
        XCTAssertEqual(range3.count, 0, "Node 3 has no edges")
    }

    func testEdgeRangeInvalidNode() throws {
        let graph = try makeSimpleGraph()

        let invalidNode = NodeID(layer: 10, index: 0)
        XCTAssertThrowsError(try graph.edgeRange(for: invalidNode)) { error in
            guard case GraphError.invalidNodeID = error else {
                XCTFail("Expected invalidNodeID error")
                return
            }
        }
    }

    func testOutDegree() throws {
        let graph = try makeSimpleGraph()

        XCTAssertEqual(try graph.outDegree(of: NodeID(layer: 0, index: 0)), 2)
        XCTAssertEqual(try graph.outDegree(of: NodeID(layer: 0, index: 1)), 1)
        XCTAssertEqual(try graph.outDegree(of: NodeID(layer: 1, index: 0)), 0)
    }

    func testNeighbors() throws {
        let graph = try makeSimpleGraph()

        let neighbors0 = try graph.neighbors(of: NodeID(layer: 0, index: 0))
        XCTAssertEqual(neighbors0.count, 2)
        XCTAssertTrue(neighbors0.contains(NodeID(layer: 1, index: 0)))
        XCTAssertTrue(neighbors0.contains(NodeID(layer: 1, index: 1)))

        let neighbors1 = try graph.neighbors(of: NodeID(layer: 0, index: 1))
        XCTAssertEqual(neighbors1.count, 1)
        XCTAssertEqual(neighbors1[0], NodeID(layer: 1, index: 0))
    }

    // MARK: - Edge Lookup Tests

    func testFindEdge() throws {
        let graph = try makeSimpleGraph()

        let src = NodeID(layer: 0, index: 0)
        let dst1 = NodeID(layer: 1, index: 0)
        let dst2 = NodeID(layer: 1, index: 1)

        let edge1 = try graph.findEdge(from: src, to: dst1)
        XCTAssertNotNil(edge1, "Should find edge 0→3")

        let edge2 = try graph.findEdge(from: src, to: dst2)
        XCTAssertNotNil(edge2, "Should find edge 0→4")

        let nonExistent = try graph.findEdge(
            from: NodeID(layer: 0, index: 1),
            to: NodeID(layer: 1, index: 1)
        )
        XCTAssertNil(nonExistent, "Edge 1→4 doesn't exist")
    }

    func testEdgeWeight() throws {
        let graph = try makeSimpleGraph()

        let weight = try graph.edgeWeight(
            from: NodeID(layer: 0, index: 0),
            to: NodeID(layer: 1, index: 0)
        )
        XCTAssertEqual(weight, 1.0, accuracy: 1e-6)
    }

    func testEdgeWeightNotFound() throws {
        let graph = try makeSimpleGraph()

        XCTAssertThrowsError(try graph.edgeWeight(
            from: NodeID(layer: 0, index: 1),
            to: NodeID(layer: 1, index: 1)
        )) { error in
            guard case GraphError.edgeNotFound = error else {
                XCTFail("Expected edgeNotFound error")
                return
            }
        }
    }

    func testSetWeight() throws {
        var graph = try makeSimpleGraph()

        try graph.setWeight(
            from: NodeID(layer: 0, index: 0),
            to: NodeID(layer: 1, index: 0),
            weight: 2.5
        )

        let newWeight = try graph.edgeWeight(
            from: NodeID(layer: 0, index: 0),
            to: NodeID(layer: 1, index: 0)
        )
        XCTAssertEqual(newWeight, 2.5, accuracy: 1e-6)
    }

    // MARK: - Statistics Tests

    func testGraphStatistics() throws {
        let graph = try makeSimpleGraph()

        let stats = graph.statistics()

        XCTAssertEqual(stats.numNodes, 6)
        XCTAssertEqual(stats.numEdges, 4)
        XCTAssertEqual(stats.minOutDegree, 0, "Nodes 3, 4, 5 have no outgoing edges")
        XCTAssertEqual(stats.maxOutDegree, 2, "Node 0 has 2 edges")
        XCTAssertGreaterThan(stats.avgOutDegree, 0)
    }

    func testEmptyGraphStatistics() throws {
        let config = GraphConfig(layers: 1, nodesPerLayer: 2, localNeighbors: 0, jumpNeighbors: 0)

        let rowPtr = [0, 0, 0]
        let colIdx: [Int] = []
        let weights: [Float] = []
        let positions = [SIMD2<Float>(0, 0), SIMD2<Float>(0, 1)]

        let graph = try Graph(
            rowPtr: rowPtr,
            colIdx: colIdx,
            weights: weights,
            config: config,
            nodePositions: positions
        )

        let stats = graph.statistics()
        XCTAssertEqual(stats.numEdges, 0)
        XCTAssertEqual(stats.minOutDegree, 0)
        XCTAssertEqual(stats.maxOutDegree, 0)
        XCTAssertEqual(stats.avgOutDegree, 0.0, accuracy: 1e-6)
    }
}
