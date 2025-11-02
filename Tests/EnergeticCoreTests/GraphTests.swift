import XCTest
@testable import EnergeticCore

final class TemporalGridTests: XCTestCase {

    // MARK: - Initialization Tests
    
    func testGridInitialization() throws {
        let grid = try TemporalGrid(layers: 10, nodesPerLayer: 1024)
        
        XCTAssertEqual(grid.layers, 10)
        XCTAssertEqual(grid.nodesPerLayer, 1024)
        XCTAssertEqual(grid.totalNodes, 10 * 1024)
    }
    
    func testGridInitializationInvalidLayers() {
        XCTAssertThrowsError(try TemporalGrid(layers: 0, nodesPerLayer: 100)) { error in
            guard case RouterError.invalidConfiguration(let message) = error else {
                XCTFail("Expected RouterError.invalidConfiguration")
                return
            }
            XCTAssertTrue(message.contains("layers"))
        }
        
        XCTAssertThrowsError(try TemporalGrid(layers: -5, nodesPerLayer: 100))
    }
    
    func testGridInitializationInvalidNodesPerLayer() {
        XCTAssertThrowsError(try TemporalGrid(layers: 10, nodesPerLayer: 0)) { error in
            guard case RouterError.invalidConfiguration(let message) = error else {
                XCTFail("Expected RouterError.invalidConfiguration")
                return
            }
            XCTAssertTrue(message.contains("nodesPerLayer"))
        }
        
        XCTAssertThrowsError(try TemporalGrid(layers: 10, nodesPerLayer: -3))
    }
    
    // MARK: - Navigation Tests
    
    func testAdvanceForward() throws {
        let grid = try TemporalGrid(layers: 10, nodesPerLayer: 100)
        
        XCTAssertEqual(grid.advanceForward(0), 1)
        XCTAssertEqual(grid.advanceForward(5), 6)
        XCTAssertEqual(grid.advanceForward(8), 9)
        XCTAssertEqual(grid.advanceForward(9), 9, "Should clamp at last layer")
    }
    
    func testWrapY() throws {
        let grid = try TemporalGrid(layers: 5, nodesPerLayer: 10)
        
        XCTAssertEqual(grid.wrapY(5), 5, "Within bounds")
        XCTAssertEqual(grid.wrapY(10), 0, "Wrap at boundary")
        XCTAssertEqual(grid.wrapY(15), 5, "Wrap beyond boundary")
        XCTAssertEqual(grid.wrapY(-1), 9, "Negative wrap")
        XCTAssertEqual(grid.wrapY(-11), 9, "Large negative wrap")
    }
    
    func testClampX() throws {
        let grid = try TemporalGrid(layers: 8, nodesPerLayer: 50)
        
        XCTAssertEqual(grid.clampX(3), 3, "Within bounds")
        XCTAssertEqual(grid.clampX(-1), 0, "Clamp negative")
        XCTAssertEqual(grid.clampX(0), 0, "At min")
        XCTAssertEqual(grid.clampX(7), 7, "At max")
        XCTAssertEqual(grid.clampX(10), 7, "Clamp above max")
    }
    
    func testIsOutputLayer() throws {
        let grid = try TemporalGrid(layers: 5, nodesPerLayer: 10)
        
        XCTAssertFalse(grid.isOutputLayer(0))
        XCTAssertFalse(grid.isOutputLayer(3))
        XCTAssertTrue(grid.isOutputLayer(4), "Last layer is output")
        XCTAssertTrue(grid.isOutputLayer(5), "Beyond last is also output")
    }
    
    func testIsValidX() throws {
        let grid = try TemporalGrid(layers: 7, nodesPerLayer: 20)
        
        XCTAssertFalse(grid.isValidX(-1))
        XCTAssertTrue(grid.isValidX(0))
        XCTAssertTrue(grid.isValidX(3))
        XCTAssertTrue(grid.isValidX(6))
        XCTAssertFalse(grid.isValidX(7))
        XCTAssertFalse(grid.isValidX(100))
    }
    
    func testIsValidY() throws {
        let grid = try TemporalGrid(layers: 5, nodesPerLayer: 64)
        
        XCTAssertFalse(grid.isValidY(-1))
        XCTAssertTrue(grid.isValidY(0))
        XCTAssertTrue(grid.isValidY(32))
        XCTAssertTrue(grid.isValidY(63))
        XCTAssertFalse(grid.isValidY(64))
        XCTAssertFalse(grid.isValidY(100))
    }
    
    func testIsValid() throws {
        let grid = try TemporalGrid(layers: 3, nodesPerLayer: 5)
        
        XCTAssertTrue(grid.isValid(x: 0, y: 0))
        XCTAssertTrue(grid.isValid(x: 2, y: 4))
        XCTAssertFalse(grid.isValid(x: -1, y: 0))
        XCTAssertFalse(grid.isValid(x: 0, y: 5))
        XCTAssertFalse(grid.isValid(x: 3, y: 0))
    }
    
    // MARK: - Index Conversion Tests
    
    func testFlatIndex() throws {
        let grid = try TemporalGrid(layers: 10, nodesPerLayer: 100)
        
        XCTAssertEqual(grid.flatIndex(x: 0, y: 0), 0)
        XCTAssertEqual(grid.flatIndex(x: 0, y: 50), 50)
        XCTAssertEqual(grid.flatIndex(x: 1, y: 0), 100)
        XCTAssertEqual(grid.flatIndex(x: 5, y: 25), 5 * 100 + 25)
    }
    
    func testCoordinatesFromIndex() throws {
        let grid = try TemporalGrid(layers: 10, nodesPerLayer: 100)
        
        let (x0, y0) = grid.coordinates(from: 0)
        XCTAssertEqual(x0, 0)
        XCTAssertEqual(y0, 0)
        
        let (x1, y1) = grid.coordinates(from: 50)
        XCTAssertEqual(x1, 0)
        XCTAssertEqual(y1, 50)
        
        let (x2, y2) = grid.coordinates(from: 100)
        XCTAssertEqual(x2, 1)
        XCTAssertEqual(y2, 0)
        
        let (x3, y3) = grid.coordinates(from: 525)
        XCTAssertEqual(x3, 5)
        XCTAssertEqual(y3, 25)
    }
    
    func testRoundTripIndexConversion() throws {
        let grid = try TemporalGrid(layers: 8, nodesPerLayer: 128)
        
        for x in 0..<8 {
            for y in stride(from: 0, to: 128, by: 10) {
                let flat = grid.flatIndex(x: x, y: y)
                let (x2, y2) = grid.coordinates(from: flat)
                XCTAssertEqual(x, x2)
                XCTAssertEqual(y, y2)
            }
        }
    }
    
    // MARK: - Normalization Tests
    
    func testNormalizeX() throws {
        let grid = try TemporalGrid(layers: 10, nodesPerLayer: 100)
        
        XCTAssertEqual(grid.normalizeX(0), 0.0, accuracy: 1e-6)
        XCTAssertEqual(grid.normalizeX(9), 1.0, accuracy: 1e-6)
        XCTAssertEqual(grid.normalizeX(5), 5.0/9.0, accuracy: 1e-6)
    }
    
    func testNormalizeY() throws {
        let grid = try TemporalGrid(layers: 5, nodesPerLayer: 100)
        
        XCTAssertEqual(grid.normalizeY(0), 0.0, accuracy: 1e-6)
        XCTAssertEqual(grid.normalizeY(99), 1.0, accuracy: 1e-6)
        XCTAssertEqual(grid.normalizeY(50), 50.0/99.0, accuracy: 1e-3)
    }
    
    func testNormalizedPosition() throws {
        let grid = try TemporalGrid(layers: 5, nodesPerLayer: 10)
        
        let pos = grid.normalizedPosition(x: 2, y: 5)
        XCTAssertEqual(pos.x, 2.0/4.0, accuracy: 1e-6)
        XCTAssertEqual(pos.y, 5.0/9.0, accuracy: 1e-6)
    }
    
    func testNormalizeSingleLayer() throws {
        let grid = try TemporalGrid(layers: 1, nodesPerLayer: 10)
        
        XCTAssertEqual(grid.normalizeX(0), 0.0)
        XCTAssertEqual(grid.normalizeX(5), 0.0, "Single layer always 0")
    }
    
    func testNormalizeSingleNodePerLayer() throws {
        let grid = try TemporalGrid(layers: 5, nodesPerLayer: 1)
        
        XCTAssertEqual(grid.normalizeY(0), 0.0)
        XCTAssertEqual(grid.normalizeY(5), 0.0, "Single node always 0")
    }
    
    // MARK: - Statistics Tests
    
    func testStatistics() throws {
        let grid = try TemporalGrid(layers: 10, nodesPerLayer: 1024)
        let stats = grid.statistics()
        
        XCTAssertEqual(stats.layers, 10)
        XCTAssertEqual(stats.nodesPerLayer, 1024)
        XCTAssertEqual(stats.totalNodes, 10 * 1024)
        XCTAssertTrue(stats.description.contains("10"))
        XCTAssertTrue(stats.description.contains("1024"))
    }
}
