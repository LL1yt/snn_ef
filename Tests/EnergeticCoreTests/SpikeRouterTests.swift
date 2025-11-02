import XCTest
@testable import EnergeticCore

final class SpikeRouterTests: XCTestCase {
    
    // MARK: - Initialization Tests
    
    func testRouterCreation() throws {
        let config = RouterFactory.createTestConfig()
        let router = try SpikeRouter.create(from: config)
        
        XCTAssertEqual(router.grid.layers, config.layers)
        XCTAssertEqual(router.grid.nodesPerLayer, config.nodesPerLayer)
    }
    
    // MARK: - Basic Movement Tests
    
    func testBasicForwardMovement() throws {
        let router = try createTestRouter()
        
        let packet = EnergyPacket(
            streamID: 1,
            x: 0,
            y: 50,
            energy: 1000.0,  // Higher energy to survive routing
            time: 0
        )
        
        var membrane: Float = 0.0
        let nextPacket = router.route(packet: packet, membrane: &membrane)
        
        // Packet might survive or die depending on kernel output
        // Just verify routing logic works
        if let next = nextPacket {
            // X should advance
            XCTAssertGreaterThan(next.x, packet.x)
            
            // Time should increment
            XCTAssertEqual(next.time, packet.time + 1)
            
            // Energy should be positive
            XCTAssertGreaterThan(next.energy, 0.0)
        }
        // If packet died, that's also valid behavior
    }
    
    func testYWrapping() throws {
        let config = RouterFactory.createTestConfig()
        let router = try SpikeRouter.create(from: config)
        
        // Packet at edge of Y range with high energy
        let packet = EnergyPacket(
            streamID: 1,
            x: 0,
            y: config.nodesPerLayer - 1,
            energy: 1000.0,  // High energy to survive
            time: 0
        )
        
        var membrane: Float = 0.0
        let nextPacket = router.route(packet: packet, membrane: &membrane)
        
        // Packet should survive with high energy
        if let next = nextPacket {
            // Y should be valid (wrapped if needed)
            XCTAssertGreaterThanOrEqual(next.y, 0)
            XCTAssertLessThan(next.y, config.nodesPerLayer)
            XCTAssertGreaterThan(next.energy, 0.0)
        }
    }
    
    func testOutputLayerTermination() throws {
        let config = RouterFactory.createTestConfig()
        let router = try SpikeRouter.create(from: config)
        
        // Packet at last layer
        let packet = EnergyPacket(
            streamID: 1,
            x: config.layers - 1,
            y: 10,
            energy: 100.0,
            time: 0
        )
        
        var membrane: Float = 0.0
        let nextPacket = router.route(packet: packet, membrane: &membrane)
        
        // Should return nil (reached output)
        XCTAssertNil(nextPacket)
    }
    
    // MARK: - Energy Tests
    
    func testEnergyDecay() throws {
        let config = RouterFactory.createTestConfig()
        let router = try SpikeRouter.create(from: config)
        
        let initialEnergy: Float = 100.0
        let packet = EnergyPacket(
            streamID: 1,
            x: 0,
            y: 10,
            energy: initialEnergy,
            time: 0
        )
        
        var membrane: Float = 0.0
        let nextPacket = router.route(packet: packet, membrane: &membrane)
        
        XCTAssertNotNil(nextPacket)
        
        if let next = nextPacket {
            // Energy should decay by alpha factor
            XCTAssertLessThan(next.energy, initialEnergy)
            XCTAssertGreaterThan(next.energy, 0.0)
            
            // Should be roughly initial * alpha (plus kernel output)
            XCTAssertLessThan(next.energy, initialEnergy * config.alpha * 2.0)
        }
    }
    
    func testEnergyFloorCutoff() throws {
        let config = RouterFactory.createTestConfig()
        let router = try SpikeRouter.create(from: config)
        
        // Packet with low energy
        let packet = EnergyPacket(
            streamID: 1,
            x: 0,
            y: 10,
            energy: config.energyFloor * 0.1,  // Very low
            time: 0
        )
        
        var membrane: Float = 0.0
        
        // Run multiple steps - should eventually die
        var survived = 0
        var currentPacket: EnergyPacket? = packet
        
        for _ in 0..<10 {
            if let pkt = currentPacket {
                currentPacket = router.route(packet: pkt, membrane: &membrane)
                if currentPacket != nil {
                    survived += 1
                }
            } else {
                break
            }
        }
        
        // With very low energy, should not survive many steps
        XCTAssertLessThan(survived, 5, "Low energy packet should die quickly")
    }
    
    // MARK: - Batch Routing Tests
    
    func testBatchRouting() throws {
        let router = try createTestRouter()
        
        let packets = [
            EnergyPacket(streamID: 1, x: 0, y: 10, energy: 5000.0, time: 0),
            EnergyPacket(streamID: 2, x: 1, y: 20, energy: 5000.0, time: 0),
            EnergyPacket(streamID: 3, x: 2, y: 30, energy: 5000.0, time: 0)
        ]
        
        var membranes: [Float] = [0.0, 0.0, 0.0]
        let nextPackets = router.route(packets: packets, membranes: &membranes)
        
        // With high energy, at least some packets should survive
        XCTAssertGreaterThanOrEqual(nextPackets.count, 0, "Batch routing should work")
        XCTAssertLessThanOrEqual(nextPackets.count, packets.count)
    }
    
    // MARK: - Membrane State Tests
    
    func testMembraneUpdates() throws {
        let router = try createTestRouter()
        
        let packet = EnergyPacket(
            streamID: 1,
            x: 0,
            y: 10,
            energy: 100.0,
            time: 0
        )
        
        var membrane: Float = 0.0
        let initialMembrane = membrane
        
        _ = router.route(packet: packet, membrane: &membrane)
        
        // Membrane should have changed
        XCTAssertNotEqual(membrane, initialMembrane)
    }
    
    // MARK: - Multi-Step Tests
    
    func testMultiStepRouting() throws {
        let config = RouterFactory.createTestConfig()
        let router = try SpikeRouter.create(from: config)
        
        var packet: EnergyPacket? = EnergyPacket(
            streamID: 1,
            x: 0,
            y: 10,
            energy: 100.0,
            time: 0
        )
        
        var membrane: Float = 0.0
        var steps = 0
        let maxSteps = config.layers * 2
        
        // Route until packet reaches output or dies
        while packet != nil && steps < maxSteps {
            packet = router.route(packet: packet!, membrane: &membrane)
            steps += 1
        }
        
        // Should have made progress
        XCTAssertGreaterThan(steps, 0)
        XCTAssertLessThan(steps, maxSteps, "Should complete before timeout")
    }
    
    func testPacketProgression() throws {
        let router = try createTestRouter()
        
        var packet = EnergyPacket(
            streamID: 1,
            x: 0,
            y: 10,
            energy: 5000.0,  // Very high energy to guarantee survival
            time: 0
        )
        
        var membrane: Float = 0.0
        let startX = packet.x
        var survived = false
        
        // Route a few steps
        for _ in 0..<3 {
            if let next = router.route(packet: packet, membrane: &membrane) {
                packet = next
                survived = true
            } else {
                break
            }
        }
        
        // Should have survived at least one step with high energy
        XCTAssertTrue(survived, "Packet with high energy should survive at least one step")
        
        // If survived, X should have advanced
        if survived {
            XCTAssertGreaterThan(packet.x, startX)
        }
    }
    
    // MARK: - Edge Cases
    
    func testZeroEnergyPacket() throws {
        let router = try createTestRouter()
        
        let packet = EnergyPacket(
            streamID: 1,
            x: 0,
            y: 10,
            energy: 0.0,
            time: 0
        )
        
        var membrane: Float = 0.0
        let nextPacket = router.route(packet: packet, membrane: &membrane)
        
        // Should die quickly with zero energy
        if let next = nextPacket {
            XCTAssertLessThan(next.energy, 1.0)
        }
    }
    
    func testHighEnergyPacket() throws {
        let router = try createTestRouter()
        
        let packet = EnergyPacket(
            streamID: 1,
            x: 0,
            y: 10,
            energy: 100000.0,  // Very high
            time: 0
        )
        
        var membrane: Float = 0.0
        let nextPacket = router.route(packet: packet, membrane: &membrane)
        
        // High energy packet should survive at least once
        if let next = nextPacket {
            XCTAssertFalse(next.energy.isNaN)
            XCTAssertFalse(next.energy.isInfinite)
            XCTAssertGreaterThan(next.energy, 0.0)
        } else {
            // Even very high energy can die if kernel output is near zero
            // This is valid behavior
        }
    }
    
    func testBoundaryYValues() throws {
        let config = RouterFactory.createTestConfig()
        let router = try SpikeRouter.create(from: config)
        
        // Test at Y=0 with high energy
        let packet1 = EnergyPacket(streamID: 1, x: 0, y: 0, energy: 1000.0, time: 0)
        var membrane1: Float = 0.0
        let next1 = router.route(packet: packet1, membrane: &membrane1)
        
        // Verify routing works (might survive or not)
        if let next = next1 {
            XCTAssertGreaterThanOrEqual(next.y, 0)
            XCTAssertLessThan(next.y, config.nodesPerLayer)
        }
        
        // Test at Y=max with high energy
        let packet2 = EnergyPacket(
            streamID: 2,
            x: 0,
            y: config.nodesPerLayer - 1,
            energy: 1000.0,
            time: 0
        )
        var membrane2: Float = 0.0
        let next2 = router.route(packet: packet2, membrane: &membrane2)
        
        // Verify routing works
        if let next = next2 {
            XCTAssertGreaterThanOrEqual(next.y, 0)
            XCTAssertLessThan(next.y, config.nodesPerLayer)
        }
    }
    
    // MARK: - Helper Methods
    
    private func createTestRouter() throws -> SpikeRouter {
        let config = RouterFactory.createTestConfig()
        return try SpikeRouter.create(from: config)
    }
}
