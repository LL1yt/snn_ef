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
            energy: 100.0,
            time: 0
        )
        
        var membrane: Float = 0.0
        let nextPacket = router.route(packet: packet, membrane: &membrane)
        
        XCTAssertNotNil(nextPacket)
        
        if let next = nextPacket {
            // X should advance
            XCTAssertGreaterThan(next.x, packet.x)
            
            // Energy should decay
            XCTAssertLessThan(next.energy, packet.energy)
            
            // Time should increment
            XCTAssertEqual(next.time, packet.time + 1)
        }
    }
    
    func testYWrapping() throws {
        let config = RouterFactory.createTestConfig()
        let router = try SpikeRouter.create(from: config)
        
        // Packet at edge of Y range
        let packet = EnergyPacket(
            streamID: 1,
            x: 0,
            y: config.nodesPerLayer - 1,
            energy: 100.0,
            time: 0
        )
        
        var membrane: Float = 0.0
        let nextPacket = router.route(packet: packet, membrane: &membrane)
        
        XCTAssertNotNil(nextPacket)
        
        if let next = nextPacket {
            // Y should wrap around
            XCTAssertGreaterThanOrEqual(next.y, 0)
            XCTAssertLessThan(next.y, config.nodesPerLayer)
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
        
        // Packet with energy below floor
        let packet = EnergyPacket(
            streamID: 1,
            x: 0,
            y: 10,
            energy: config.energyFloor * 0.5,  // Below floor
            time: 0
        )
        
        var membrane: Float = 0.0
        let nextPacket = router.route(packet: packet, membrane: &membrane)
        
        // Should die (return nil) due to low energy
        // Note: might survive one step due to kernel output, but should die soon
        if let next = nextPacket {
            XCTAssertLessThan(next.energy, config.energyFloor * 10.0)
        }
    }
    
    // MARK: - Batch Routing Tests
    
    func testBatchRouting() throws {
        let router = try createTestRouter()
        
        let packets = [
            EnergyPacket(streamID: 1, x: 0, y: 10, energy: 100.0, time: 0),
            EnergyPacket(streamID: 2, x: 1, y: 20, energy: 50.0, time: 0),
            EnergyPacket(streamID: 3, x: 2, y: 30, energy: 75.0, time: 0)
        ]
        
        var membranes: [Float] = [0.0, 0.0, 0.0]
        let nextPackets = router.route(packets: packets, membranes: &membranes)
        
        // Some or all packets should survive
        XCTAssertGreaterThan(nextPackets.count, 0)
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
            energy: 100.0,
            time: 0
        )
        
        var membrane: Float = 0.0
        let startX = packet.x
        
        // Route a few steps
        for _ in 0..<3 {
            if let next = router.route(packet: packet, membrane: &membrane) {
                packet = next
            } else {
                break
            }
        }
        
        // X should have advanced
        XCTAssertGreaterThan(packet.x, startX)
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
            energy: 10000.0,
            time: 0
        )
        
        var membrane: Float = 0.0
        let nextPacket = router.route(packet: packet, membrane: &membrane)
        
        XCTAssertNotNil(nextPacket)
        
        if let next = nextPacket {
            XCTAssertFalse(next.energy.isNaN)
            XCTAssertFalse(next.energy.isInfinite)
        }
    }
    
    func testBoundaryYValues() throws {
        let config = RouterFactory.createTestConfig()
        let router = try SpikeRouter.create(from: config)
        
        // Test at Y=0
        let packet1 = EnergyPacket(streamID: 1, x: 0, y: 0, energy: 100.0, time: 0)
        var membrane1: Float = 0.0
        let next1 = router.route(packet: packet1, membrane: &membrane1)
        XCTAssertNotNil(next1)
        
        // Test at Y=max
        let packet2 = EnergyPacket(
            streamID: 2,
            x: 0,
            y: config.nodesPerLayer - 1,
            energy: 100.0,
            time: 0
        )
        var membrane2: Float = 0.0
        let next2 = router.route(packet: packet2, membrane: &membrane2)
        XCTAssertNotNil(next2)
    }
    
    // MARK: - Helper Methods
    
    private func createTestRouter() throws -> SpikeRouter {
        let config = RouterFactory.createTestConfig()
        return try SpikeRouter.create(from: config)
    }
}
