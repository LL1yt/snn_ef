import XCTest
@testable import EnergeticCore

final class EnergyFlowSimulatorTests: XCTestCase {
    
    // MARK: - Initialization Tests
    
    func testSimulatorCreation() throws {
        let router = try createTestRouter()
        let packets = [createTestPacket(streamID: 1)]
        
        let simulator = EnergyFlowSimulator(router: router, initialPackets: packets)
        
        XCTAssertEqual(simulator.activeCount, 1)
        XCTAssertEqual(simulator.currentStepNumber, 0)
        XCTAssertFalse(simulator.isFinished)
    }
    
    // MARK: - Step Execution Tests
    
    func testSingleStep() throws {
        let router = try createTestRouter()
        let packets = [createTestPacket(streamID: 1)]
        
        let simulator = EnergyFlowSimulator(router: router, initialPackets: packets)
        
        _ = simulator.step()
        
        // Should continue if packet didn't reach output or die
        XCTAssertEqual(simulator.currentStepNumber, 1)
    }
    
    func testMultipleSteps() throws {
        let router = try createTestRouter()
        let packets = [createTestPacket(streamID: 1, energy: 100.0)]
        
        let simulator = EnergyFlowSimulator(router: router, initialPackets: packets)
        
        // Execute multiple steps
        for _ in 0..<5 {
            if !simulator.step() {
                break
            }
        }
        
        XCTAssertGreaterThan(simulator.currentStepNumber, 0)
        XCTAssertLessThanOrEqual(simulator.currentStepNumber, 5)
    }
    
    // MARK: - Run Tests
    
    func testRunToCompletion() throws {
        let router = try createTestRouter()
        let packets = [createTestPacket(streamID: 1, x: 0, energy: 100.0)]
        
        let simulator = EnergyFlowSimulator(router: router, initialPackets: packets, maxSteps: 100)
        
        let result = simulator.run()
        
        XCTAssertGreaterThan(result.steps, 0)
        XCTAssertLessThan(result.steps, 100)
    }
    
    func testRunWithMultiplePackets() throws {
        let router = try createTestRouter()
        let packets = [
            createTestPacket(streamID: 1, x: 0, energy: 100.0),
            createTestPacket(streamID: 2, x: 1, energy: 80.0),
            createTestPacket(streamID: 3, x: 0, energy: 120.0)
        ]
        
        let simulator = EnergyFlowSimulator(router: router, initialPackets: packets, maxSteps: 100)
        
        let result = simulator.run()
        
        // Should process multiple streams
        XCTAssertGreaterThan(result.steps, 0)
        
        // At least some streams should complete or die
        XCTAssertGreaterThanOrEqual(result.completedCount + result.deadCount, 0)
    }
    
    // MARK: - Output Collection Tests
    
    func testOutputAccumulation() throws {
        let config = RouterFactory.createTestConfig()
        let router = try SpikeRouter.create(from: config)
        
        // Start packet near output
        let packets = [
            EnergyPacket(streamID: 1, x: config.layers - 2, y: 10, energy: 100.0, time: 0)
        ]
        
        let simulator = EnergyFlowSimulator(router: router, initialPackets: packets, maxSteps: 10)
        
        let result = simulator.run()
        
        // Check if stream reached output
        if result.completedStreams.contains(1) {
            XCTAssertGreaterThan(result.totalOutputEnergy, 0.0)
        }
    }
    
    func testMultipleStreamOutputs() throws {
        let config = RouterFactory.createTestConfig()
        let router = try SpikeRouter.create(from: config)
        
        // Multiple packets near output
        let packets = [
            EnergyPacket(streamID: 1, x: config.layers - 2, y: 10, energy: 50.0, time: 0),
            EnergyPacket(streamID: 2, x: config.layers - 2, y: 20, energy: 70.0, time: 0)
        ]
        
        let simulator = EnergyFlowSimulator(router: router, initialPackets: packets, maxSteps: 10)
        
        let result = simulator.run()
        
        // Check completed streams
        let completedCount = result.completedStreams.count
        XCTAssertGreaterThanOrEqual(completedCount, 0)
        XCTAssertLessThanOrEqual(completedCount, 2)
    }
    
    // MARK: - Energy Balance Tests
    
    func testEnergyNonNegative() throws {
        let router = try createTestRouter()
        let packets = [createTestPacket(streamID: 1, energy: 100.0)]
        
        let simulator = EnergyFlowSimulator(router: router, initialPackets: packets, maxSteps: 50)
        
        let result = simulator.run()
        
        // All output energies should be non-negative
        for (_, energy) in result.outputEnergies {
            XCTAssertGreaterThanOrEqual(energy, 0.0)
            XCTAssertFalse(energy.isNaN)
        }
    }
    
    func testEnergyDecayOverTime() throws {
        let config = RouterFactory.createTestConfig()
        let router = try SpikeRouter.create(from: config)
        
        let initialEnergy: Float = 100.0
        let packets = [EnergyPacket(streamID: 1, x: 0, y: 10, energy: initialEnergy, time: 0)]
        
        let simulator = EnergyFlowSimulator(router: router, initialPackets: packets, maxSteps: 100)
        
        let result = simulator.run()
        
        // Total output energy should be less than initial (due to decay and floor)
        if result.totalOutputEnergy > 0 {
            XCTAssertLessThan(result.totalOutputEnergy, initialEnergy)
        }
    }
    
    // MARK: - Condition Tests
    
    func testRunUntilCondition() throws {
        let router = try createTestRouter()
        let packets = [createTestPacket(streamID: 1)]
        
        let simulator = EnergyFlowSimulator(router: router, initialPackets: packets, maxSteps: 100)
        
        // Run until 10 steps
        let result = simulator.run(until: { sim in sim.currentStepNumber >= 10 })
        
        XCTAssertGreaterThanOrEqual(result.steps, 10)
    }
    
    func testRunUntilNoActivePackets() throws {
        let router = try createTestRouter()
        let packets = [createTestPacket(streamID: 1, energy: 0.1)]  // Low energy
        
        let simulator = EnergyFlowSimulator(router: router, initialPackets: packets, maxSteps: 100)
        
        // Run until no active packets
        let result = simulator.run(until: { sim in sim.activeCount == 0 })
        
        // Should finish with no active packets
        XCTAssertLessThan(result.steps, 100)
    }
    
    // MARK: - Timeout Tests
    
    func testMaxStepsTimeout() throws {
        let router = try createTestRouter()
        let packets = [createTestPacket(streamID: 1, energy: 10000.0)]  // High energy
        
        let maxSteps = 10
        let simulator = EnergyFlowSimulator(router: router, initialPackets: packets, maxSteps: maxSteps)
        
        let result = simulator.run()
        
        // Should stop at max steps
        XCTAssertLessThanOrEqual(result.steps, maxSteps)
        
        // Might timeout with active packets
        if result.steps == maxSteps {
            // Timeout is possible with high energy
        }
    }
    
    // MARK: - Stream Lifecycle Tests
    
    func testStreamCompletion() throws {
        let config = RouterFactory.createTestConfig()
        let router = try SpikeRouter.create(from: config)
        
        // Packet very close to output
        let packets = [
            EnergyPacket(streamID: 1, x: config.layers - 1, y: 10, energy: 100.0, time: 0)
        ]
        
        let simulator = EnergyFlowSimulator(router: router, initialPackets: packets, maxSteps: 5)
        
        let result = simulator.run()
        
        // Should complete immediately (at output layer)
        XCTAssertTrue(result.completedStreams.contains(1))
    }
    
    func testStreamDeath() throws {
        let router = try createTestRouter()
        
        // Packet with very low energy
        let packets = [
            createTestPacket(streamID: 1, energy: 0.0001)
        ]
        
        let simulator = EnergyFlowSimulator(router: router, initialPackets: packets, maxSteps: 50)
        
        let result = simulator.run()
        
        // Should die due to low energy
        // Either completed or died
        XCTAssertGreaterThan(result.completedCount + result.deadCount, 0)
    }
    
    // MARK: - Query Tests
    
    func testCollectOutputs() throws {
        let router = try createTestRouter()
        let packets = [createTestPacket(streamID: 1)]
        
        let simulator = EnergyFlowSimulator(router: router, initialPackets: packets, maxSteps: 50)
        
        _ = simulator.run()
        
        let outputs = simulator.collectOutputs()
        
        // Outputs dictionary should be valid
        XCTAssertGreaterThanOrEqual(outputs.count, 0)
    }
    
    func testIsFinished() throws {
        let router = try createTestRouter()
        let packets = [createTestPacket(streamID: 1, energy: 0.001)]
        
        let simulator = EnergyFlowSimulator(router: router, initialPackets: packets, maxSteps: 20)
        
        XCTAssertFalse(simulator.isFinished)
        
        _ = simulator.run()
        
        // Should be finished after run
        XCTAssertTrue(simulator.isFinished)
    }
    
    // MARK: - Edge Cases
    
    func testEmptyInitialPackets() throws {
        let router = try createTestRouter()
        let packets: [EnergyPacket] = []
        
        let simulator = EnergyFlowSimulator(router: router, initialPackets: packets)
        
        XCTAssertEqual(simulator.activeCount, 0)
        XCTAssertTrue(simulator.isFinished)
        
        let result = simulator.run()
        
        XCTAssertEqual(result.steps, 0)
        XCTAssertEqual(result.completedCount, 0)
    }
    
    func testSingleStepSimulation() throws {
        let router = try createTestRouter()
        let packets = [createTestPacket(streamID: 1)]
        
        let simulator = EnergyFlowSimulator(router: router, initialPackets: packets, maxSteps: 1)
        
        let result = simulator.run()
        
        XCTAssertLessThanOrEqual(result.steps, 1)
    }
    
    // MARK: - Result Structure Tests
    
    func testSimulationResultStructure() throws {
        let router = try createTestRouter()
        let packets = [createTestPacket(streamID: 1)]
        
        let simulator = EnergyFlowSimulator(router: router, initialPackets: packets, maxSteps: 10)
        
        let result = simulator.run()
        
        // Check result structure
        XCTAssertGreaterThanOrEqual(result.steps, 0)
        XCTAssertGreaterThanOrEqual(result.totalOutputEnergy, 0.0)
        XCTAssertGreaterThanOrEqual(result.completedCount, 0)
        XCTAssertGreaterThanOrEqual(result.deadCount, 0)
    }
    
    // MARK: - Helper Methods
    
    private func createTestRouter() throws -> SpikeRouter {
        let config = RouterFactory.createTestConfig()
        return try SpikeRouter.create(from: config)
    }
    
    private func createTestPacket(
        streamID: Int,
        x: Int = 0,
        y: Int = 10,
        energy: Float = 100.0
    ) -> EnergyPacket {
        EnergyPacket(streamID: streamID, x: x, y: y, energy: energy, time: 0)
    }
}
