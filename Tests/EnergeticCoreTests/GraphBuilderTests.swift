import XCTest
@testable import EnergeticCore

final class GraphBuilderTests: XCTestCase {

    // MARK: - Basic Construction Tests

    func testBuildSmallLattice() throws {
        let config = GraphConfig(
            layers: 3,
            nodesPerLayer: 4,
            localNeighbors: 2,
            jumpNeighbors: 1
        )

        let graph = try GraphBuilder.buildLattice(config: config)

        XCTAssertEqual(graph.numNodes, 12, "3 layers × 4 nodes = 12")
        XCTAssertGreaterThan(graph.numEdges, 0, "Should have edges")
        XCTAssertEqual(graph.config, config)
    }

    func testBuildBaselineConfigGraph() throws {
        // Baseline config from YAML: 10 layers × 1024 nodes
        let config = GraphConfig(
            layers: 10,
            nodesPerLayer: 1024,
            localNeighbors: 8,
            jumpNeighbors: 2
        )

        let graph = try GraphBuilder.buildLattice(config: config)

        XCTAssertEqual(graph.numNodes, 10240, "10 × 1024 = 10,240")
        XCTAssertGreaterThan(graph.numEdges, 0)

        // Check statistics
        let stats = graph.statistics()
        XCTAssertGreaterThan(stats.avgOutDegree, 0)
        XCTAssertLessThanOrEqual(stats.maxOutDegree, 10, "Should not exceed local + jump")
    }

    func testSingleLayerGraph() throws {
        let config = GraphConfig(
            layers: 1,
            nodesPerLayer: 10,
            localNeighbors: 3,
            jumpNeighbors: 1
        )

        let graph = try GraphBuilder.buildLattice(config: config)

        XCTAssertEqual(graph.numNodes, 10)
        XCTAssertEqual(graph.numEdges, 0, "Single layer has no outgoing edges")

        let stats = graph.statistics()
        XCTAssertEqual(stats.maxOutDegree, 0)
    }

    func testTwoLayerGraph() throws {
        let config = GraphConfig(
            layers: 2,
            nodesPerLayer: 5,
            localNeighbors: 3,
            jumpNeighbors: 1  // No jump possible with only 2 layers
        )

        let graph = try GraphBuilder.buildLattice(config: config)

        XCTAssertEqual(graph.numNodes, 10)
        XCTAssertGreaterThan(graph.numEdges, 0, "Should have edges from layer 0 to 1")

        // Layer 0 should have edges, layer 1 should not
        for nodeIdx in 0..<5 {
            let node0 = NodeID(layer: 0, index: nodeIdx)
            let degree0 = try graph.outDegree(of: node0)
            XCTAssertGreaterThan(degree0, 0, "Layer 0 nodes should have outgoing edges")

            let node1 = NodeID(layer: 1, index: nodeIdx)
            let degree1 = try graph.outDegree(of: node1)
            XCTAssertEqual(degree1, 0, "Layer 1 nodes should have no outgoing edges")
        }
    }

    // MARK: - Edge Connectivity Tests

    func testLocalEdgesExist() throws {
        let config = GraphConfig(
            layers: 3,
            nodesPerLayer: 4,
            localNeighbors: 2,
            jumpNeighbors: 0
        )

        let graph = try GraphBuilder.buildLattice(config: config)

        // Check that nodes in layer 0 have edges to layer 1
        for nodeIdx in 0..<config.nodesPerLayer {
            let node = NodeID(layer: 0, index: nodeIdx)
            let neighbors = try graph.neighbors(of: node)

            XCTAssertGreaterThan(neighbors.count, 0, "Node \(node) should have neighbors")

            // All neighbors should be in layer 1
            for neighbor in neighbors {
                XCTAssertEqual(neighbor.layer, 1, "Local edges should go to next layer")
            }
        }
    }

    func testJumpEdgesExist() throws {
        let config = GraphConfig(
            layers: 4,
            nodesPerLayer: 3,
            localNeighbors: 2,
            jumpNeighbors: 1
        )

        let graph = try GraphBuilder.buildLattice(config: config)

        // Check that nodes in layer 0 have edges to layer 2 (jump)
        var hasJumpEdges = false

        for nodeIdx in 0..<config.nodesPerLayer {
            let node = NodeID(layer: 0, index: nodeIdx)
            let neighbors = try graph.neighbors(of: node)

            for neighbor in neighbors {
                if neighbor.layer == 2 {
                    hasJumpEdges = true
                    break
                }
            }

            if hasJumpEdges { break }
        }

        XCTAssertTrue(hasJumpEdges, "Should have at least some jump edges")
    }

    func testNoEdgesFromLastLayer() throws {
        let config = GraphConfig(
            layers: 5,
            nodesPerLayer: 4,
            localNeighbors: 3,
            jumpNeighbors: 1
        )

        let graph = try GraphBuilder.buildLattice(config: config)

        // Last layer (layer 4) should have no outgoing edges
        for nodeIdx in 0..<config.nodesPerLayer {
            let node = NodeID(layer: 4, index: nodeIdx)
            let degree = try graph.outDegree(of: node)
            XCTAssertEqual(degree, 0, "Last layer nodes should have no outgoing edges")
        }
    }

    func testNoIncomingEdgesToFirstLayer() throws {
        let config = GraphConfig(
            layers: 3,
            nodesPerLayer: 4,
            localNeighbors: 2,
            jumpNeighbors: 1
        )

        let graph = try GraphBuilder.buildLattice(config: config)

        // Check that no edges point to layer 0
        for edgeIdx in 0..<graph.numEdges {
            let dstNodeIdx = graph.colIdx[edgeIdx]
            let dstNode = graph.nodeID(from: dstNodeIdx)
            XCTAssertGreaterThan(dstNode.layer, 0, "No edges should point to layer 0")
        }
    }

    // MARK: - Edge Count Tests

    func testLocalNeighborCountRespected() throws {
        let config = GraphConfig(
            layers: 3,
            nodesPerLayer: 10,
            localNeighbors: 4,
            jumpNeighbors: 0
        )

        let graph = try GraphBuilder.buildLattice(config: config)

        // Nodes in layer 0 should have approximately localNeighbors edges
        for nodeIdx in 0..<config.nodesPerLayer {
            let node = NodeID(layer: 0, index: nodeIdx)
            let degree = try graph.outDegree(of: node)

            XCTAssertLessThanOrEqual(
                degree,
                config.localNeighbors,
                "Out-degree should not exceed localNeighbors"
            )

            // Should have at least 1 edge (unless no next layer, but we have layer 1)
            XCTAssertGreaterThan(degree, 0, "Should have at least one local edge")
        }
    }

    func testTotalEdgeCount() throws {
        let config = GraphConfig(
            layers: 4,
            nodesPerLayer: 5,
            localNeighbors: 3,
            jumpNeighbors: 1
        )

        let graph = try GraphBuilder.buildLattice(config: config)

        // Total edges should be within reasonable bounds
        let maxPossibleEdges = config.totalNodes * (config.localNeighbors + config.jumpNeighbors)
        XCTAssertLessThanOrEqual(graph.numEdges, maxPossibleEdges)

        // Should have at least some edges
        XCTAssertGreaterThan(graph.numEdges, 0)
    }

    // MARK: - Positional Embeddings Tests

    func testPositionalEmbeddings() throws {
        let config = GraphConfig(
            layers: 3,
            nodesPerLayer: 4,
            localNeighbors: 2,
            jumpNeighbors: 1
        )

        let graph = try GraphBuilder.buildLattice(config: config)

        XCTAssertEqual(graph.nodePositions.count, graph.numNodes)

        // Check layer 0, node 0
        let pos00 = graph.nodePositions[0]
        XCTAssertEqual(pos00.x, 0.0, accuracy: 1e-6, "First layer should have x=0")
        XCTAssertEqual(pos00.y, 0.0, accuracy: 1e-6, "First node should have y=0")

        // Check last layer, last node
        let lastIdx = graph.numNodes - 1
        let posLast = graph.nodePositions[lastIdx]
        XCTAssertEqual(posLast.x, 1.0, accuracy: 1e-6, "Last layer should have x=1")
        XCTAssertEqual(posLast.y, 1.0, accuracy: 1e-6, "Last node should have y=1")

        // Check all positions are in [0, 1]
        for pos in graph.nodePositions {
            XCTAssertGreaterThanOrEqual(pos.x, 0.0)
            XCTAssertLessThanOrEqual(pos.x, 1.0)
            XCTAssertGreaterThanOrEqual(pos.y, 0.0)
            XCTAssertLessThanOrEqual(pos.y, 1.0)
        }
    }

    // MARK: - Configuration Validation Tests

    func testInvalidLayersConfiguration() {
        let config = GraphConfig(
            layers: 0,  // Invalid
            nodesPerLayer: 10,
            localNeighbors: 2,
            jumpNeighbors: 1
        )

        XCTAssertThrowsError(try GraphBuilder.buildLattice(config: config)) { error in
            guard case GraphError.invalidConfiguration = error else {
                XCTFail("Expected invalidConfiguration error")
                return
            }
        }
    }

    func testInvalidNodesPerLayerConfiguration() {
        let config = GraphConfig(
            layers: 3,
            nodesPerLayer: 0,  // Invalid
            localNeighbors: 2,
            jumpNeighbors: 1
        )

        XCTAssertThrowsError(try GraphBuilder.buildLattice(config: config))
    }

    func testNegativeNeighborsConfiguration() {
        let config = GraphConfig(
            layers: 3,
            nodesPerLayer: 4,
            localNeighbors: -1,  // Invalid
            jumpNeighbors: 1
        )

        XCTAssertThrowsError(try GraphBuilder.buildLattice(config: config))
    }

    // MARK: - CSR Structure Validation

    func testCSRMonotonicity() throws {
        let config = GraphConfig(
            layers: 4,
            nodesPerLayer: 6,
            localNeighbors: 3,
            jumpNeighbors: 1
        )

        let graph = try GraphBuilder.buildLattice(config: config)

        // rowPtr should be monotonically increasing
        for i in 0..<graph.rowPtr.count - 1 {
            XCTAssertLessThanOrEqual(
                graph.rowPtr[i],
                graph.rowPtr[i + 1],
                "rowPtr should be monotonically increasing"
            )
        }

        // Last element should equal edge count
        XCTAssertEqual(graph.rowPtr.last, graph.numEdges)
    }

    func testCSRColumnIndicesValid() throws {
        let config = GraphConfig(
            layers: 3,
            nodesPerLayer: 5,
            localNeighbors: 2,
            jumpNeighbors: 1
        )

        let graph = try GraphBuilder.buildLattice(config: config)

        // All colIdx values should be valid node indices
        for colIdx in graph.colIdx {
            XCTAssertGreaterThanOrEqual(colIdx, 0)
            XCTAssertLessThan(colIdx, graph.numNodes)
        }
    }

    func testCSRWeightsLength() throws {
        let config = GraphConfig(
            layers: 4,
            nodesPerLayer: 4,
            localNeighbors: 2,
            jumpNeighbors: 1
        )

        let graph = try GraphBuilder.buildLattice(config: config)

        XCTAssertEqual(
            graph.weights.count,
            graph.colIdx.count,
            "Weights and colIdx should have same length"
        )

        XCTAssertEqual(
            graph.weights.count,
            graph.numEdges,
            "Weights count should equal numEdges"
        )
    }

    // MARK: - Edge Cases

    func testZeroLocalNeighbors() throws {
        let config = GraphConfig(
            layers: 3,
            nodesPerLayer: 4,
            localNeighbors: 0,
            jumpNeighbors: 2
        )

        let graph = try GraphBuilder.buildLattice(config: config)

        // Should only have jump edges
        // Nodes in layer 0 should have edges to layer 2
        let node = NodeID(layer: 0, index: 0)
        let neighbors = try graph.neighbors(of: node)

        for neighbor in neighbors {
            XCTAssertEqual(neighbor.layer, 2, "Only jump edges should exist")
        }
    }

    func testZeroJumpNeighbors() throws {
        let config = GraphConfig(
            layers: 4,
            nodesPerLayer: 3,
            localNeighbors: 2,
            jumpNeighbors: 0
        )

        let graph = try GraphBuilder.buildLattice(config: config)

        // Should only have local edges
        // Nodes in layer 0 should only connect to layer 1
        let node = NodeID(layer: 0, index: 0)
        let neighbors = try graph.neighbors(of: node)

        for neighbor in neighbors {
            XCTAssertEqual(neighbor.layer, 1, "Only local edges should exist")
        }
    }

    func testMoreNeighborsThanNodes() throws {
        let config = GraphConfig(
            layers: 3,
            nodesPerLayer: 2,
            localNeighbors: 10,  // More than available
            jumpNeighbors: 5
        )

        let graph = try GraphBuilder.buildLattice(config: config)

        // Should connect to all available nodes without error
        XCTAssertGreaterThan(graph.numEdges, 0)

        // Out-degree should not exceed nodesPerLayer
        let stats = graph.statistics()
        XCTAssertLessThanOrEqual(stats.maxOutDegree, config.nodesPerLayer)
    }
}
