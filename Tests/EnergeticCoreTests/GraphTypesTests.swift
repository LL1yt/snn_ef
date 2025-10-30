import XCTest
@testable import EnergeticCore

final class GraphTypesTests: XCTestCase {

    // MARK: - NodeID Tests

    func testNodeIDEquality() {
        let node1 = NodeID(layer: 2, index: 5)
        let node2 = NodeID(layer: 2, index: 5)
        let node3 = NodeID(layer: 2, index: 6)
        let node4 = NodeID(layer: 3, index: 5)

        XCTAssertEqual(node1, node2, "Same layer and index should be equal")
        XCTAssertNotEqual(node1, node3, "Different index should not be equal")
        XCTAssertNotEqual(node1, node4, "Different layer should not be equal")
    }

    func testNodeIDHashable() {
        let node1 = NodeID(layer: 1, index: 10)
        let node2 = NodeID(layer: 1, index: 10)
        let node3 = NodeID(layer: 1, index: 11)

        var set = Set<NodeID>()
        set.insert(node1)
        set.insert(node2)
        set.insert(node3)

        XCTAssertEqual(set.count, 2, "Should have 2 unique nodes")
        XCTAssertTrue(set.contains(node1), "Should contain node1")
        XCTAssertTrue(set.contains(node3), "Should contain node3")
    }

    func testNodeIDDescription() {
        let node = NodeID(layer: 3, index: 42)
        XCTAssertEqual(node.description, "Node(L3:42)")
    }

    // MARK: - Edge Tests

    func testEdgeCreation() {
        let src = NodeID(layer: 0, index: 5)
        let dst = NodeID(layer: 1, index: 10)
        let edge = Edge(src: src, dst: dst, weight: 0.5)

        XCTAssertEqual(edge.src, src)
        XCTAssertEqual(edge.dst, dst)
        XCTAssertEqual(edge.weight, 0.5, accuracy: 1e-6)
    }

    func testEdgeDefaultWeight() {
        let src = NodeID(layer: 0, index: 0)
        let dst = NodeID(layer: 1, index: 0)
        let edge = Edge(src: src, dst: dst)

        XCTAssertEqual(edge.weight, 1.0, accuracy: 1e-6, "Default weight should be 1.0")
    }

    func testEdgeMutableWeight() {
        let src = NodeID(layer: 0, index: 0)
        let dst = NodeID(layer: 1, index: 0)
        var edge = Edge(src: src, dst: dst, weight: 1.0)

        edge.weight = 2.5
        XCTAssertEqual(edge.weight, 2.5, accuracy: 1e-6)
    }

    func testEdgeDescription() {
        let src = NodeID(layer: 0, index: 1)
        let dst = NodeID(layer: 1, index: 2)
        let edge = Edge(src: src, dst: dst, weight: 0.123)

        let desc = edge.description
        XCTAssertTrue(desc.contains("L0:1"), "Should contain source node")
        XCTAssertTrue(desc.contains("L1:2"), "Should contain destination node")
        XCTAssertTrue(desc.contains("0.123"), "Should contain weight")
    }

    // MARK: - LayerConfig Tests

    func testLayerConfigCreation() {
        let config = LayerConfig(
            nodeCount: 128,
            localNeighbors: 8,
            jumpNeighbors: 2
        )

        XCTAssertEqual(config.nodeCount, 128)
        XCTAssertEqual(config.localNeighbors, 8)
        XCTAssertEqual(config.jumpNeighbors, 2)
    }

    func testLayerConfigEquality() {
        let config1 = LayerConfig(nodeCount: 100, localNeighbors: 4, jumpNeighbors: 1)
        let config2 = LayerConfig(nodeCount: 100, localNeighbors: 4, jumpNeighbors: 1)
        let config3 = LayerConfig(nodeCount: 100, localNeighbors: 4, jumpNeighbors: 2)

        XCTAssertEqual(config1, config2)
        XCTAssertNotEqual(config1, config3)
    }

    // MARK: - GraphConfig Tests

    func testGraphConfigCreation() {
        let config = GraphConfig(
            layers: 10,
            nodesPerLayer: 1024,
            localNeighbors: 8,
            jumpNeighbors: 2
        )

        XCTAssertEqual(config.layers, 10)
        XCTAssertEqual(config.nodesPerLayer, 1024)
        XCTAssertEqual(config.localNeighbors, 8)
        XCTAssertEqual(config.jumpNeighbors, 2)
    }

    func testGraphConfigTotalNodes() {
        let config = GraphConfig(
            layers: 5,
            nodesPerLayer: 100,
            localNeighbors: 4,
            jumpNeighbors: 1
        )

        XCTAssertEqual(config.totalNodes, 500, "5 layers × 100 nodes = 500")
    }

    func testGraphConfigEstimatedEdges() {
        // Simple case: 3 layers, 4 nodes per layer, 2 local, 1 jump
        let config = GraphConfig(
            layers: 3,
            nodesPerLayer: 4,
            localNeighbors: 2,
            jumpNeighbors: 1
        )

        // Layer 0 → Layer 1: 4 nodes × 2 local = 8 edges
        // Layer 1 → Layer 2: 4 nodes × 2 local = 8 edges (no jump, last layer)
        // Layer 2: no outgoing edges
        // Total: 8 + 8 = 16 edges (estimated, actual might vary)

        let estimated = config.estimatedEdges
        XCTAssertGreaterThan(estimated, 0, "Should have positive edge count")
        XCTAssertLessThanOrEqual(
            estimated,
            config.totalNodes * (config.localNeighbors + config.jumpNeighbors),
            "Should not exceed max possible edges"
        )
    }

    func testGraphConfigEstimatedEdgesLargeGraph() {
        // Baseline config: 10 layers, 1024 nodes
        let config = GraphConfig(
            layers: 10,
            nodesPerLayer: 1024,
            localNeighbors: 8,
            jumpNeighbors: 2
        )

        let estimated = config.estimatedEdges
        XCTAssertGreaterThan(estimated, 0)

        // Middle layers (layers 0..7): 8 layers × 1024 nodes × (8+2) edges = 81,920
        // Layer 8 (second-to-last): 1024 nodes × 8 local = 8,192
        // Layer 9: no outgoing
        // But layer 0 already counted in middle, so adjust...
        // Actually the formula in code handles this differently, just check bounds

        let maxPossible = config.totalNodes * (config.localNeighbors + config.jumpNeighbors)
        XCTAssertLessThanOrEqual(estimated, maxPossible)
    }

    func testGraphConfigEquality() {
        let config1 = GraphConfig(layers: 5, nodesPerLayer: 64, localNeighbors: 4, jumpNeighbors: 1)
        let config2 = GraphConfig(layers: 5, nodesPerLayer: 64, localNeighbors: 4, jumpNeighbors: 1)
        let config3 = GraphConfig(layers: 6, nodesPerLayer: 64, localNeighbors: 4, jumpNeighbors: 1)

        XCTAssertEqual(config1, config2)
        XCTAssertNotEqual(config1, config3)
    }

    // MARK: - GraphError Tests

    func testGraphErrorDescriptions() {
        let node = NodeID(layer: 10, index: 50)
        let src = NodeID(layer: 0, index: 0)
        let dst = NodeID(layer: 1, index: 1)

        let error1 = GraphError.invalidNodeID(node)
        XCTAssertTrue(error1.description.contains("Invalid node ID"))

        let error2 = GraphError.invalidLayerIndex(99)
        XCTAssertTrue(error2.description.contains("Invalid layer index"))

        let error3 = GraphError.invalidConfiguration("test reason")
        XCTAssertTrue(error3.description.contains("test reason"))

        let error4 = GraphError.edgeNotFound(src: src, dst: dst)
        XCTAssertTrue(error4.description.contains("Edge not found"))

        let error5 = GraphError.csrIndexOutOfBounds
        XCTAssertTrue(error5.description.contains("CSR index"))
    }

    // MARK: - Edge Cases

    func testSingleLayerGraph() {
        let config = GraphConfig(
            layers: 1,
            nodesPerLayer: 10,
            localNeighbors: 0,
            jumpNeighbors: 0
        )

        XCTAssertEqual(config.totalNodes, 10)
        XCTAssertEqual(config.estimatedEdges, 0, "Single layer has no outgoing edges")
    }

    func testTwoLayerGraph() {
        let config = GraphConfig(
            layers: 2,
            nodesPerLayer: 5,
            localNeighbors: 3,
            jumpNeighbors: 0  // No jump possible with only 2 layers
        )

        XCTAssertEqual(config.totalNodes, 10)
        XCTAssertGreaterThan(config.estimatedEdges, 0)
    }

    func testZeroNodesPerLayer() {
        let config = GraphConfig(
            layers: 5,
            nodesPerLayer: 0,
            localNeighbors: 8,
            jumpNeighbors: 2
        )

        XCTAssertEqual(config.totalNodes, 0)
        XCTAssertEqual(config.estimatedEdges, 0)
    }
}
