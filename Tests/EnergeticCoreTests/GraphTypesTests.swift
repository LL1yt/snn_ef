import XCTest
@testable import EnergeticCore

final class GraphTypesTests: XCTestCase {
    
    // MARK: - SNNConfig Tests

    
    func testSNNConfigCreation() {
        let config = SNNConfig(
            parameterCount: 512,
            decay: 0.92,
            threshold: 0.8,
            resetValue: 0.0,
            deltaXRange: 1...4,
            deltaYRange: -128...128,
            surrogate: "fast_sigmoid",
            dt: 1
        )
        
        XCTAssertEqual(config.parameterCount, 512)
        XCTAssertEqual(config.decay, 0.92, accuracy: 1e-6)
        XCTAssertEqual(config.threshold, 0.8, accuracy: 1e-6)
        XCTAssertEqual(config.resetValue, 0.0, accuracy: 1e-6)
        XCTAssertEqual(config.deltaXRange, 1...4)
        XCTAssertEqual(config.deltaYRange, -128...128)
        XCTAssertEqual(config.surrogate, "fast_sigmoid")
        XCTAssertEqual(config.dt, 1)
    }
    
    func testSNNConfigEquality() {
        let config1 = SNNConfig(
            parameterCount: 256,
            decay: 0.9,
            threshold: 0.5,
            resetValue: 0.0,
            deltaXRange: 1...3,
            deltaYRange: -10...10,
            surrogate: "fast_sigmoid",
            dt: 1
        )
        
        let config2 = SNNConfig(
            parameterCount: 256,
            decay: 0.9,
            threshold: 0.5,
            resetValue: 0.0,
            deltaXRange: 1...3,
            deltaYRange: -10...10,
            surrogate: "fast_sigmoid",
            dt: 1
        )
        
        let config3 = SNNConfig(
            parameterCount: 512,  // Different
            decay: 0.9,
            threshold: 0.5,
            resetValue: 0.0,
            deltaXRange: 1...3,
            deltaYRange: -10...10,
            surrogate: "fast_sigmoid",
            dt: 1
        )
        
        XCTAssertEqual(config1, config2)
        XCTAssertNotEqual(config1, config3)
    }
    
    // MARK: - RouterConfig Tests
    
    func testRouterConfigCreation() {
        let snn = SNNConfig(
            parameterCount: 128,
            decay: 0.9,
            threshold: 0.5,
            resetValue: 0.0,
            deltaXRange: 1...2,
            deltaYRange: -5...5,
            surrogate: "tanh_clip",
            dt: 1
        )
        
        let config = RouterConfig(
            layers: 10,
            nodesPerLayer: 1024,
            snn: snn,
            alpha: 0.9,
            energyFloor: 1e-5,
            energyBase: 256
        )
        
        XCTAssertEqual(config.layers, 10)
        XCTAssertEqual(config.nodesPerLayer, 1024)
        XCTAssertEqual(config.snn, snn)
        XCTAssertEqual(config.alpha, 0.9, accuracy: 1e-6)
        XCTAssertEqual(config.energyFloor, 1e-5, accuracy: 1e-9)
        XCTAssertEqual(config.energyBase, 256)
    }
    
    func testRouterConfigTotalNodes() {
        let config = RouterFactory.createTestConfig()
        XCTAssertEqual(config.totalNodes, 5 * 64)
    }

    // MARK: - EnergyPacket Tests
    
    func testEnergyPacketCreation() {
        let packet = EnergyPacket(
            streamID: 42,
            x: 3,
            y: 100,
            energy: 1.5,
            time: 10
        )
        
        XCTAssertEqual(packet.streamID, 42)
        XCTAssertEqual(packet.x, 3)
        XCTAssertEqual(packet.y, 100)
        XCTAssertEqual(packet.energy, 1.5, accuracy: 1e-6)
        XCTAssertEqual(packet.time, 10)
    }
    
    func testEnergyPacketNormalization() {
        let packet = EnergyPacket(
            streamID: 1,
            x: 5,
            y: 50,
            energy: 100.0,
            time: 20
        )
        
        let normalized = packet.asNormalizedInput(
            maxLayers: 10,
            maxNodesPerLayer: 100,
            maxEnergy: 200.0,
            maxTime: 40
        )
        
        // x_norm = 5 / 9 ≈ 0.556
        XCTAssertEqual(normalized.x, 5.0 / 9.0, accuracy: 1e-3)
        // y_norm = 50 / 99 ≈ 0.505
        XCTAssertEqual(normalized.y, 50.0 / 99.0, accuracy: 1e-3)
        // energy_norm = 100 / 200 = 0.5
        XCTAssertEqual(normalized.z, 0.5, accuracy: 1e-6)
        // time_norm = 20 / 40 = 0.5
        XCTAssertEqual(normalized.w, 0.5, accuracy: 1e-6)
    }
    
    func testEnergyPacketIsAlive() {
        let alive = EnergyPacket(streamID: 1, x: 0, y: 0, energy: 1.0, time: 0)
        let dead = EnergyPacket(streamID: 2, x: 0, y: 0, energy: 0.001, time: 0)
        
        XCTAssertTrue(alive.isAlive(minEnergy: 0.1))
        XCTAssertFalse(dead.isAlive(minEnergy: 0.1))
    }
    
    func testEnergyPacketEquality() {
        let packet1 = EnergyPacket(streamID: 1, x: 2, y: 3, energy: 1.0, time: 5)
        let packet2 = EnergyPacket(streamID: 1, x: 2, y: 3, energy: 1.0, time: 5)
        let packet3 = EnergyPacket(streamID: 2, x: 2, y: 3, energy: 1.0, time: 5)
        
        XCTAssertEqual(packet1, packet2)
        XCTAssertNotEqual(packet1, packet3)
    }

    // MARK: - SpikingOutput Tests
    
    func testSpikingOutputCreation() {
        let output = SpikingOutput(
            energyNext: 0.8,
            deltaXY: SIMD2(2.5, -10.3),
            spike: true
        )
        
        XCTAssertEqual(output.energyNext, 0.8, accuracy: 1e-6)
        XCTAssertEqual(output.deltaXY.x, 2.5, accuracy: 1e-6)
        XCTAssertEqual(output.deltaXY.y, -10.3, accuracy: 1e-6)
        XCTAssertTrue(output.spike)
    }
    
    func testSpikingOutputNoSpike() {
        let output = SpikingOutput(
            energyNext: 0.5,
            deltaXY: SIMD2(0.0, 0.0),
            spike: false
        )
        
        XCTAssertFalse(output.spike)
    }

    // MARK: - RouterError Tests
    
    func testRouterErrorDescriptions() {
        let packet = EnergyPacket(streamID: 5, x: 100, y: 200, energy: 1.0, time: 0)
        
        let error1 = RouterError.invalidConfiguration("test reason")
        XCTAssertTrue(error1.description.contains("test reason"))
        
        let error2 = RouterError.packetOutOfBounds(packet)
        XCTAssertTrue(error2.description.contains("streamID=5"))
        XCTAssertTrue(error2.description.contains("x=100"))
        
        let error3 = RouterError.negativeEnergy(streamID: 10, energy: -0.5)
        XCTAssertTrue(error3.description.contains("stream 10"))
        XCTAssertTrue(error3.description.contains("-0.5"))
        
        let error4 = RouterError.membraneNaN(streamID: 7)
        XCTAssertTrue(error4.description.contains("stream 7"))
        XCTAssertTrue(error4.description.contains("NaN"))
        
        let error5 = RouterError.invalidSurrogate("unknown_func")
        XCTAssertTrue(error5.description.contains("unknown_func"))
    }

    // MARK: - Edge Cases
    
    func testSingleLayerConfig() {
        let snn = SNNConfig(
            parameterCount: 64,
            decay: 0.9,
            threshold: 0.5,
            resetValue: 0.0,
            deltaXRange: 1...1,
            deltaYRange: 0...0,
            surrogate: "fast_sigmoid",
            dt: 1
        )
        
        let config = RouterConfig(
            layers: 1,
            nodesPerLayer: 10,
            snn: snn,
            alpha: 1.0,
            energyFloor: 0.0,
            energyBase: 256
        )
        
        XCTAssertEqual(config.totalNodes, 10)
    }
    
    func testZeroEnergyPacket() {
        let packet = EnergyPacket(streamID: 1, x: 0, y: 0, energy: 0.0, time: 0)
        XCTAssertFalse(packet.isAlive(minEnergy: 1e-5))
    }
    
    func testNegativeTimeNormalization() {
        // Edge case: time = 0, maxTime = 1
        let packet = EnergyPacket(streamID: 1, x: 0, y: 0, energy: 1.0, time: 0)
        let normalized = packet.asNormalizedInput(
            maxLayers: 10,
            maxNodesPerLayer: 10,
            maxEnergy: 1.0,
            maxTime: 1
        )
        
        XCTAssertEqual(normalized.w, 0.0, accuracy: 1e-6)
    }
}
