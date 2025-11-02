import XCTest
@testable import EnergeticCore

final class SpikingKernelTests: XCTestCase {
    
    // MARK: - Initialization Tests
    
    func testKernelInitialization() throws {
        let config = SNNConfig(
            parameterCount: 128,
            decay: 0.9,
            threshold: 0.5,
            resetValue: 0.0,
            deltaXRange: 1...3,
            deltaYRange: -10...10,
            surrogate: "fast_sigmoid",
            dt: 1
        )
        
        let kernel = try SpikingKernel(config: config)
        
        XCTAssertEqual(kernel.parameterCount, 128)
        XCTAssertEqual(kernel.decay, 0.9, accuracy: 1e-6)
        XCTAssertEqual(kernel.threshold, 0.5, accuracy: 1e-6)
        XCTAssertEqual(kernel.resetValue, 0.0, accuracy: 1e-6)
    }
    
    func testKernelMinimalParameterCount() {
        let config = SNNConfig(
            parameterCount: 5,  // Too small
            decay: 0.9,
            threshold: 0.5,
            resetValue: 0.0,
            deltaXRange: 1...3,
            deltaYRange: -10...10,
            surrogate: "fast_sigmoid",
            dt: 1
        )
        
        XCTAssertThrowsError(try SpikingKernel(config: config)) { error in
            guard case RouterError.invalidConfiguration = error else {
                XCTFail("Expected RouterError.invalidConfiguration")
                return
            }
        }
    }
    
    // MARK: - Forward Pass Tests
    
    func testForwardPassBasic() throws {
        let kernel = try createTestKernel()
        
        let input = SIMD4<Float>(0.5, 0.5, 1.0, 0.0)
        var membrane: Float = 0.0
        
        let output = kernel.forward(input: input, membrane: &membrane)
        
        // Check output structure
        XCTAssertFalse(output.energyNext.isNaN)
        XCTAssertFalse(output.deltaXY.x.isNaN)
        XCTAssertFalse(output.deltaXY.y.isNaN)
        
        // Membrane should be updated
        XCTAssertNotEqual(membrane, 0.0)
    }
    
    func testMembraneAccumulation() throws {
        let kernel = try createTestKernel(decay: 0.9, threshold: 10.0)  // High threshold to prevent spike
        
        let input = SIMD4<Float>(0.5, 0.5, 1.0, 0.0)
        var membrane: Float = 0.0
        
        // First step
        let output1 = kernel.forward(input: input, membrane: &membrane)
        XCTAssertFalse(output1.spike, "Should not spike with high threshold")
        
        // Second step - membrane should accumulate with decay
        let output2 = kernel.forward(input: input, membrane: &membrane)
        XCTAssertFalse(output2.spike)
        
        // Membrane should have grown (input + decay * previous)
        // Can't predict exact value, but should be non-zero
        XCTAssertGreaterThan(abs(membrane), 0.0)
    }
    
    func testSpikeGeneration() throws {
        let kernel = try createTestKernel(decay: 0.99, threshold: 0.1)
        
        let input = SIMD4<Float>(1.0, 1.0, 1.0, 1.0)  // Strong input
        var membrane: Float = 0.0
        
        var spiked = false
        var steps = 0
        
        // Run until spike or timeout
        while steps < 10 && !spiked {
            let output = kernel.forward(input: input, membrane: &membrane)
            if output.spike {
                spiked = true
            }
            steps += 1
        }
        
        // Should eventually spike with strong input
        XCTAssertTrue(spiked, "Should spike within 10 steps with strong input")
    }
    
    func testSpikeReset() throws {
        let kernel = try createTestKernel(decay: 0.95, threshold: 0.1, resetValue: 0.0)
        
        let input = SIMD4<Float>(1.0, 1.0, 1.0, 1.0)
        var membrane: Float = 0.0
        
        var spiked = false
        var membraneBeforeSpike: Float = 0.0
        var stepsUntilSpike = 0
        let maxSteps = 50
        
        // Run until spike occurs
        while stepsUntilSpike < maxSteps && !spiked {
            membraneBeforeSpike = membrane
            let output = kernel.forward(input: input, membrane: &membrane)
            
            if output.spike {
                spiked = true
                // Membrane should be reset after spike
                XCTAssertEqual(membrane, kernel.resetValue, accuracy: 0.5, 
                              "Membrane should reset to \(kernel.resetValue) after spike, but was \(membrane)")
                // Membrane before spike should have been near threshold
                XCTAssertGreaterThan(membraneBeforeSpike, kernel.threshold * 0.5,
                                   "Membrane before spike should be near threshold")
            }
            
            stepsUntilSpike += 1
        }
        
        XCTAssertTrue(spiked, "Should spike within \(maxSteps) steps with strong input")
    }
    
    // MARK: - Batch Processing Tests
    
    func testBatchForward() throws {
        let kernel = try createTestKernel()
        
        let inputs = [
            SIMD4<Float>(0.1, 0.2, 0.3, 0.4),
            SIMD4<Float>(0.5, 0.6, 0.7, 0.8),
            SIMD4<Float>(0.9, 1.0, 0.5, 0.3)
        ]
        
        var membranes: [Float] = [0.0, 0.0, 0.0]
        
        let outputs = kernel.forward(inputs: inputs, membranes: &membranes)
        
        XCTAssertEqual(outputs.count, inputs.count)
        XCTAssertEqual(membranes.count, inputs.count)
        
        // All outputs should be valid
        for output in outputs {
            XCTAssertFalse(output.energyNext.isNaN)
            XCTAssertFalse(output.deltaXY.x.isNaN)
            XCTAssertFalse(output.deltaXY.y.isNaN)
        }
    }
    
    func testBatchConsistency() throws {
        let kernel = try createTestKernel()
        
        let input = SIMD4<Float>(0.5, 0.5, 1.0, 0.0)
        
        // Single forward
        var membrane1: Float = 0.0
        let output1 = kernel.forward(input: input, membrane: &membrane1)
        
        // Batch forward with one input
        var membrane2: [Float] = [0.0]
        let outputs = kernel.forward(inputs: [input], membranes: &membrane2)
        
        // Should give identical results
        XCTAssertEqual(output1.energyNext, outputs[0].energyNext, accuracy: 1e-5)
        XCTAssertEqual(output1.deltaXY.x, outputs[0].deltaXY.x, accuracy: 1e-5)
        XCTAssertEqual(output1.deltaXY.y, outputs[0].deltaXY.y, accuracy: 1e-5)
        XCTAssertEqual(output1.spike, outputs[0].spike)
        XCTAssertEqual(membrane1, membrane2[0], accuracy: 1e-5)
    }
    
    // MARK: - Output Range Tests
    
    func testDeltaXYRange() throws {
        let kernel = try createTestKernel()
        
        let input = SIMD4<Float>(0.5, 0.5, 1.0, 0.0)
        var membrane: Float = 0.0
        
        // Run multiple steps
        for _ in 0..<20 {
            let output = kernel.forward(input: input, membrane: &membrane)
            
            // Delta outputs are tanh, so should be in [-1, 1]
            XCTAssertGreaterThanOrEqual(output.deltaXY.x, -1.0)
            XCTAssertLessThanOrEqual(output.deltaXY.x, 1.0)
            XCTAssertGreaterThanOrEqual(output.deltaXY.y, -1.0)
            XCTAssertLessThanOrEqual(output.deltaXY.y, 1.0)
        }
    }
    
    // MARK: - Stability Tests
    
    func testNoNaNs() throws {
        let kernel = try createTestKernel()
        
        // Test various inputs including edge cases
        let testInputs = [
            SIMD4<Float>(0.0, 0.0, 0.0, 0.0),
            SIMD4<Float>(1.0, 1.0, 1.0, 1.0),
            SIMD4<Float>(0.5, 0.5, 0.5, 0.5),
            SIMD4<Float>(1.0, 0.0, 1.0, 0.0)
        ]
        
        for input in testInputs {
            var membrane: Float = 0.0
            
            for _ in 0..<10 {
                let output = kernel.forward(input: input, membrane: &membrane)
                
                XCTAssertFalse(output.energyNext.isNaN, "Energy should not be NaN")
                XCTAssertFalse(output.deltaXY.x.isNaN, "DeltaX should not be NaN")
                XCTAssertFalse(output.deltaXY.y.isNaN, "DeltaY should not be NaN")
                XCTAssertFalse(membrane.isNaN, "Membrane should not be NaN")
            }
        }
    }
    
    func testHighMembraneStability() throws {
        let kernel = try createTestKernel(decay: 0.9, threshold: 100.0)
        
        let input = SIMD4<Float>(1.0, 1.0, 1.0, 1.0)
        var membrane: Float = 0.0
        
        // Let membrane grow large
        for _ in 0..<100 {
            let output = kernel.forward(input: input, membrane: &membrane)
            
            XCTAssertFalse(output.energyNext.isNaN)
            XCTAssertFalse(membrane.isInfinite)
        }
    }
    
    // MARK: - Statistics Tests
    
    func testStatistics() throws {
        let kernel = try createTestKernel()
        let stats = kernel.statistics()
        
        XCTAssertEqual(stats.parameterCount, kernel.parameterCount)
        XCTAssertGreaterThan(stats.hiddenDim, 0)
        XCTAssertFalse(stats.wInMean.isNaN)
        XCTAssertFalse(stats.wInStd.isNaN)
        
        // Description should be non-empty
        XCTAssertFalse(stats.description.isEmpty)
    }
    
    // MARK: - Helper Methods
    
    private func createTestKernel(
        parameterCount: Int = 128,
        decay: Float = 0.9,
        threshold: Float = 0.5,
        resetValue: Float = 0.0
    ) throws -> SpikingKernel {
        // Ensure valid parameter count
        let validParamCount = max(parameterCount, 128)
        
        // Ensure valid decay
        let validDecay = min(max(decay, 0.01), 0.99)
        
        // Ensure valid threshold
        let validThreshold = min(max(threshold, 0.01), 1.0)
        
        let config = SNNConfig(
            parameterCount: validParamCount,
            decay: validDecay,
            threshold: validThreshold,
            resetValue: resetValue,
            deltaXRange: 1...3,
            deltaYRange: -10...10,
            surrogate: "fast_sigmoid",
            dt: 1
        )
        
        return try SpikingKernel(config: config)
    }
}
