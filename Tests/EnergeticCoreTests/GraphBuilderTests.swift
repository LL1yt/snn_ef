import XCTest
@testable import EnergeticCore

final class RouterFactoryTests: XCTestCase {

    // MARK: - SNNConfig Creation Tests
    
    func testCreateValidSNNConfig() throws {
        let config = try RouterFactory.createSNNConfig(
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
    }
    
    func testCreateSNNConfigInvalidParameterCount() {
        XCTAssertThrowsError(try RouterFactory.createSNNConfig(
            parameterCount: 0,  // Invalid
            decay: 0.9,
            threshold: 0.5,
            resetValue: 0.0,
            deltaXRange: 1...3,
            deltaYRange: -10...10,
            surrogate: "fast_sigmoid",
            dt: 1
        )) { error in
            guard case RouterError.invalidConfiguration = error else {
                XCTFail("Expected RouterError.invalidConfiguration")
                return
            }
        }
    }
    
    func testCreateSNNConfigInvalidDecay() {
        XCTAssertThrowsError(try RouterFactory.createSNNConfig(
            parameterCount: 128,
            decay: 1.0,  // Must be < 1
            threshold: 0.5,
            resetValue: 0.0,
            deltaXRange: 1...3,
            deltaYRange: -10...10,
            surrogate: "fast_sigmoid",
            dt: 1
        ))
        
        XCTAssertThrowsError(try RouterFactory.createSNNConfig(
            parameterCount: 128,
            decay: 0.0,  // Must be > 0
            threshold: 0.5,
            resetValue: 0.0,
            deltaXRange: 1...3,
            deltaYRange: -10...10,
            surrogate: "fast_sigmoid",
            dt: 1
        ))
    }
    
    func testCreateSNNConfigInvalidThreshold() {
        XCTAssertThrowsError(try RouterFactory.createSNNConfig(
            parameterCount: 128,
            decay: 0.9,
            threshold: 0.0,  // Must be > 0
            resetValue: 0.0,
            deltaXRange: 1...3,
            deltaYRange: -10...10,
            surrogate: "fast_sigmoid",
            dt: 1
        ))
        
        XCTAssertThrowsError(try RouterFactory.createSNNConfig(
            parameterCount: 128,
            decay: 0.9,
            threshold: 1.5,  // Must be <= 1
            resetValue: 0.0,
            deltaXRange: 1...3,
            deltaYRange: -10...10,
            surrogate: "fast_sigmoid",
            dt: 1
        ))
    }
    
    func testCreateSNNConfigInvalidDeltaXRange() {
        XCTAssertThrowsError(try RouterFactory.createSNNConfig(
            parameterCount: 128,
            decay: 0.9,
            threshold: 0.5,
            resetValue: 0.0,
            deltaXRange: 0...3,  // lowerBound must be >= 1
            deltaYRange: -10...10,
            surrogate: "fast_sigmoid",
            dt: 1
        ))
    }
    
    func testCreateSNNConfigInvalidDeltaYRange() {
        XCTAssertThrowsError(try RouterFactory.createSNNConfig(
            parameterCount: 128,
            decay: 0.9,
            threshold: 0.5,
            resetValue: 0.0,
            deltaXRange: 1...3,
            deltaYRange: 5...10,  // Must contain 0
            surrogate: "fast_sigmoid",
            dt: 1
        ))
        
        XCTAssertThrowsError(try RouterFactory.createSNNConfig(
            parameterCount: 128,
            decay: 0.9,
            threshold: 0.5,
            resetValue: 0.0,
            deltaXRange: 1...3,
            deltaYRange: -10...(-5),  // Must contain 0
            surrogate: "fast_sigmoid",
            dt: 1
        ))
    }
    
    func testCreateSNNConfigInvalidSurrogate() {
        XCTAssertThrowsError(try RouterFactory.createSNNConfig(
            parameterCount: 128,
            decay: 0.9,
            threshold: 0.5,
            resetValue: 0.0,
            deltaXRange: 1...3,
            deltaYRange: -10...10,
            surrogate: "unknown_func",  // Not in valid list
            dt: 1
        )) { error in
            guard case RouterError.invalidSurrogate = error else {
                XCTFail("Expected RouterError.invalidSurrogate")
                return
            }
        }
    }

    // MARK: - RouterConfig Creation Tests
    
    func testCreateValidRouterConfig() throws {
        let snn = try RouterFactory.createSNNConfig(
            parameterCount: 256,
            decay: 0.9,
            threshold: 0.5,
            resetValue: 0.0,
            deltaXRange: 1...3,
            deltaYRange: -10...10,
            surrogate: "fast_sigmoid",
            dt: 1
        )
        
        let config = try RouterFactory.createConfig(
            layers: 10,
            nodesPerLayer: 1024,
            snn: snn,
            alpha: 0.9,
            energyFloor: 1e-5,
            energyBase: 256
        )
        
        XCTAssertEqual(config.layers, 10)
        XCTAssertEqual(config.nodesPerLayer, 1024)
        XCTAssertEqual(config.totalNodes, 10 * 1024)
        XCTAssertEqual(config.alpha, 0.9, accuracy: 1e-6)
    }
    
    func testCreateRouterConfigInvalidLayers() {
        let snn = try! RouterFactory.createSNNConfig(
            parameterCount: 128,
            decay: 0.9,
            threshold: 0.5,
            resetValue: 0.0,
            deltaXRange: 1...3,
            deltaYRange: -10...10,
            surrogate: "fast_sigmoid",
            dt: 1
        )
        
        XCTAssertThrowsError(try RouterFactory.createConfig(
            layers: 0,
            nodesPerLayer: 100,
            snn: snn,
            alpha: 0.9,
            energyFloor: 1e-5,
            energyBase: 256
        ))
    }
    
    func testCreateRouterConfigInvalidAlpha() {
        let snn = try! RouterFactory.createSNNConfig(
            parameterCount: 128,
            decay: 0.9,
            threshold: 0.5,
            resetValue: 0.0,
            deltaXRange: 1...3,
            deltaYRange: -10...10,
            surrogate: "fast_sigmoid",
            dt: 1
        )
        
        XCTAssertThrowsError(try RouterFactory.createConfig(
            layers: 10,
            nodesPerLayer: 100,
            snn: snn,
            alpha: 0.0,  // Must be > 0
            energyFloor: 1e-5,
            energyBase: 256
        ))
        
        XCTAssertThrowsError(try RouterFactory.createConfig(
            layers: 10,
            nodesPerLayer: 100,
            snn: snn,
            alpha: 1.5,  // Must be <= 1
            energyFloor: 1e-5,
            energyBase: 256
        ))
    }
    
    func testCreateRouterConfigInvalidEnergyFloor() {
        let snn = try! RouterFactory.createSNNConfig(
            parameterCount: 128,
            decay: 0.9,
            threshold: 0.5,
            resetValue: 0.0,
            deltaXRange: 1...3,
            deltaYRange: -10...10,
            surrogate: "fast_sigmoid",
            dt: 1
        )
        
        XCTAssertThrowsError(try RouterFactory.createConfig(
            layers: 10,
            nodesPerLayer: 100,
            snn: snn,
            alpha: 0.9,
            energyFloor: -0.1,  // Must be >= 0
            energyBase: 256
        ))
    }
    
    // MARK: - Grid Creation Tests
    
    func testCreateGridFromConfig() throws {
        let config = RouterFactory.createTestConfig()
        let grid = try RouterFactory.createGrid(from: config)
        
        XCTAssertEqual(grid.layers, config.layers)
        XCTAssertEqual(grid.nodesPerLayer, config.nodesPerLayer)
        XCTAssertEqual(grid.totalNodes, config.totalNodes)
    }
    
    func testCreateGridValidation() throws {
        // Grid creation should validate config first
        let invalidSNN = SNNConfig(
            parameterCount: 0,  // Invalid, but we bypass validation
            decay: 0.9,
            threshold: 0.5,
            resetValue: 0.0,
            deltaXRange: 1...3,
            deltaYRange: -10...10,
            surrogate: "fast_sigmoid",
            dt: 1
        )
        
        let invalidConfig = RouterConfig(
            layers: 5,
            nodesPerLayer: 64,
            snn: invalidSNN,
            alpha: 0.9,
            energyFloor: 1e-5,
            energyBase: 256
        )
        
        // createGrid validates the config
        XCTAssertThrowsError(try RouterFactory.createGrid(from: invalidConfig))
    }
    
    // MARK: - Test Helpers
    
    func testCreateTestConfig() {
        let config = RouterFactory.createTestConfig()
        
        XCTAssertEqual(config.layers, 5)
        XCTAssertEqual(config.nodesPerLayer, 64)
        XCTAssertEqual(config.totalNodes, 5 * 64)
        XCTAssertEqual(config.snn.parameterCount, 128)
        XCTAssertEqual(config.energyBase, 256)
    }
}
