import XCTest
@testable import EnergeticCore

final class SurrogateActivationTests: XCTestCase {
    
    // MARK: - Fast Sigmoid Tests
    
    func testFastSigmoidForward() {
        let surrogate = SurrogateActivation.fastSigmoid
        
        // At x=0, should be 1.0
        XCTAssertEqual(surrogate.forward(0.0), 1.0, accuracy: 1e-6)
        
        // Positive x should decrease output
        XCTAssertLessThan(surrogate.forward(1.0), 1.0)
        XCTAssertLessThan(surrogate.forward(5.0), 0.5)
        
        // Symmetric around 0
        let y1 = surrogate.forward(2.0)
        let y2 = surrogate.forward(-2.0)
        XCTAssertEqual(y1, y2, accuracy: 1e-6)
        
        // Always positive
        XCTAssertGreaterThan(surrogate.forward(100.0), 0.0)
    }
    
    func testFastSigmoidBackward() {
        let surrogate = SurrogateActivation.fastSigmoid
        
        // Gradient at x=0 should be maximum
        let grad0 = surrogate.backward(0.0)
        XCTAssertGreaterThan(grad0, 0.0)
        
        // Gradient decreases as |x| increases
        let grad1 = surrogate.backward(1.0)
        let grad2 = surrogate.backward(2.0)
        XCTAssertGreaterThan(grad1, grad2)
        
        // Gradient is symmetric
        let gradPos = surrogate.backward(3.0)
        let gradNeg = surrogate.backward(-3.0)
        XCTAssertEqual(gradPos, gradNeg, accuracy: 1e-6)
        
        // Gradient never negative
        XCTAssertGreaterThanOrEqual(surrogate.backward(10.0), 0.0)
    }
    
    func testFastSigmoidNumericalGradient() {
        let surrogate = SurrogateActivation.fastSigmoid
        let epsilon: Float = 1e-4
        
        // Check gradient via finite differences at x=1
        let x: Float = 1.0
        let analyticalGrad = surrogate.backward(x)
        
        let yPlus = surrogate.forward(x + epsilon)
        let yMinus = surrogate.forward(x - epsilon)
        let numericalGrad = (yPlus - yMinus) / (2 * epsilon)
        
        XCTAssertEqual(analyticalGrad, numericalGrad, accuracy: 1e-3)
    }
    
    // MARK: - Tanh Clip Tests
    
    func testTanhClipForward() {
        let surrogate = SurrogateActivation.tanhClip
        
        // At x=0, should be 0 (clipped)
        XCTAssertEqual(surrogate.forward(0.0), 0.0, accuracy: 1e-6)
        
        // Negative x should be clipped to 0
        XCTAssertEqual(surrogate.forward(-1.0), 0.0, accuracy: 1e-6)
        XCTAssertEqual(surrogate.forward(-10.0), 0.0, accuracy: 1e-6)
        
        // Positive x should give tanh(x)
        let y = surrogate.forward(1.0)
        XCTAssertGreaterThan(y, 0.0)
        XCTAssertLessThan(y, 1.0)
        
        // Large x should saturate near 1
        XCTAssertGreaterThan(surrogate.forward(5.0), 0.99)
    }
    
    func testTanhClipBackward() {
        let surrogate = SurrogateActivation.tanhClip
        
        // Gradient at x <= 0 should be 0 (clipped region)
        XCTAssertEqual(surrogate.backward(0.0), 0.0, accuracy: 1e-6)
        XCTAssertEqual(surrogate.backward(-1.0), 0.0, accuracy: 1e-6)
        
        // Gradient at positive x should be positive
        let grad1 = surrogate.backward(1.0)
        XCTAssertGreaterThan(grad1, 0.0)
        
        // Gradient decreases as x increases
        let grad2 = surrogate.backward(2.0)
        XCTAssertGreaterThan(grad1, grad2)
    }
    
    func testTanhClipNumericalGradient() {
        let surrogate = SurrogateActivation.tanhClip
        let epsilon: Float = 1e-4
        
        // Check gradient at x=1 (in active region)
        let x: Float = 1.0
        let analyticalGrad = surrogate.backward(x)
        
        let yPlus = surrogate.forward(x + epsilon)
        let yMinus = surrogate.forward(x - epsilon)
        let numericalGrad = (yPlus - yMinus) / (2 * epsilon)
        
        XCTAssertEqual(analyticalGrad, numericalGrad, accuracy: 1e-3)
    }
    
    // MARK: - Batch Processing Tests
    
    func testBatchForward() {
        let surrogate = SurrogateActivation.fastSigmoid
        let inputs: [Float] = [-2.0, -1.0, 0.0, 1.0, 2.0]
        
        let batchResults = surrogate.forward(inputs)
        
        XCTAssertEqual(batchResults.count, inputs.count)
        
        // Verify each output matches single forward
        for i in 0..<inputs.count {
            let expected = surrogate.forward(inputs[i])
            XCTAssertEqual(batchResults[i], expected, accuracy: 1e-6)
        }
    }
    
    func testBatchBackward() {
        let surrogate = SurrogateActivation.tanhClip
        let inputs: [Float] = [-1.0, 0.0, 0.5, 1.0, 2.0]
        
        let batchGrads = surrogate.backward(inputs)
        
        XCTAssertEqual(batchGrads.count, inputs.count)
        
        // Verify each gradient matches single backward
        for i in 0..<inputs.count {
            let expected = surrogate.backward(inputs[i])
            XCTAssertEqual(batchGrads[i], expected, accuracy: 1e-6)
        }
    }
    
    // MARK: - Beta Parameter Tests
    
    func testBetaParameter() {
        let surrogate = SurrogateActivation.fastSigmoid
        
        // Higher beta = steeper function
        let y1 = surrogate.forward(1.0, beta: 1.0)
        let y2 = surrogate.forward(1.0, beta: 5.0)
        
        // With higher beta, same input produces lower output (steeper)
        XCTAssertGreaterThan(y1, y2)
        
        // Gradient also affected by beta
        let grad1 = surrogate.backward(1.0, beta: 1.0)
        let grad2 = surrogate.backward(1.0, beta: 5.0)
        
        XCTAssertGreaterThan(grad2, grad1, "Higher beta should have higher gradient near step")
    }
    
    // MARK: - Factory Tests
    
    func testFromString() throws {
        let fs = try SurrogateActivation.from(name: "fast_sigmoid")
        XCTAssertEqual(fs, .fastSigmoid)
        
        let tc = try SurrogateActivation.from(name: "tanh_clip")
        XCTAssertEqual(tc, .tanhClip)
    }
    
    func testFromStringInvalid() {
        XCTAssertThrowsError(try SurrogateActivation.from(name: "unknown")) { error in
            guard case RouterError.invalidSurrogate = error else {
                XCTFail("Expected RouterError.invalidSurrogate")
                return
            }
        }
    }
    
    // MARK: - Edge Cases
    
    func testExtremeValues() {
        let surrogate = SurrogateActivation.fastSigmoid
        
        // Very large positive
        let yLarge = surrogate.forward(1000.0)
        XCTAssertGreaterThan(yLarge, 0.0)
        XCTAssertFalse(yLarge.isNaN)
        XCTAssertFalse(yLarge.isInfinite)
        
        // Very large negative
        let yNegLarge = surrogate.forward(-1000.0)
        XCTAssertGreaterThan(yNegLarge, 0.0)
        XCTAssertFalse(yNegLarge.isNaN)
    }
    
    func testZeroGradientStability() {
        let surrogate = SurrogateActivation.tanhClip
        
        // Gradient at large negative values should be exactly 0
        let grad = surrogate.backward(-100.0)
        XCTAssertEqual(grad, 0.0, accuracy: 1e-9)
        XCTAssertFalse(grad.isNaN)
    }
}
