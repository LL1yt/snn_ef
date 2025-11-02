import Foundation
import Accelerate

/// Surrogate activation functions for SNN training.
/// Provides differentiable approximations of the Heaviside step function.
public enum SurrogateActivation: String, Sendable {
    case fastSigmoid = "fast_sigmoid"
    case tanhClip = "tanh_clip"
    
    // MARK: - Forward Pass
    
    /// Computes forward pass (approximates Heaviside step).
    ///
    /// - Parameters:
    ///   - x: Input value (typically membrane potential - threshold)
    ///   - beta: Steepness parameter (higher = sharper step)
    /// - Returns: Activation value in [0, 1]
    public func forward(_ x: Float, beta: Float = 1.0) -> Float {
        switch self {
        case .fastSigmoid:
            return fastSigmoidForward(x, beta: beta)
        case .tanhClip:
            return tanhClipForward(x, beta: beta)
        }
    }
    
    /// Batch forward pass using Accelerate for SIMD optimization.
    public func forward(_ x: [Float], beta: Float = 1.0) -> [Float] {
        var result = [Float](repeating: 0, count: x.count)
        
        switch self {
        case .fastSigmoid:
            for i in 0..<x.count {
                result[i] = fastSigmoidForward(x[i], beta: beta)
            }
        case .tanhClip:
            for i in 0..<x.count {
                result[i] = tanhClipForward(x[i], beta: beta)
            }
        }
        
        return result
    }
    
    // MARK: - Backward Pass (Gradient)
    
    /// Computes gradient (derivative) for backpropagation.
    ///
    /// - Parameters:
    ///   - x: Input value (same as forward)
    ///   - beta: Steepness parameter
    /// - Returns: Derivative value
    public func backward(_ x: Float, beta: Float = 1.0) -> Float {
        switch self {
        case .fastSigmoid:
            return fastSigmoidBackward(x, beta: beta)
        case .tanhClip:
            return tanhClipBackward(x, beta: beta)
        }
    }
    
    /// Batch backward pass.
    public func backward(_ x: [Float], beta: Float = 1.0) -> [Float] {
        var result = [Float](repeating: 0, count: x.count)
        
        switch self {
        case .fastSigmoid:
            for i in 0..<x.count {
                result[i] = fastSigmoidBackward(x[i], beta: beta)
            }
        case .tanhClip:
            for i in 0..<x.count {
                result[i] = tanhClipBackward(x[i], beta: beta)
            }
        }
        
        return result
    }
    
    // MARK: - Fast Sigmoid Implementation
    
    /// Fast sigmoid: σ(x) = 1 / (1 + |βx|)
    /// Simple, fast, no exponentials.
    private func fastSigmoidForward(_ x: Float, beta: Float) -> Float {
        return 1.0 / (1.0 + abs(beta * x))
    }
    
    /// Gradient: dσ/dx = β / (1 + |βx|)²
    private func fastSigmoidBackward(_ x: Float, beta: Float) -> Float {
        let denom = 1.0 + abs(beta * x)
        return beta / (denom * denom)
    }
    
    // MARK: - Tanh Clip Implementation
    
    /// Tanh clip: σ(x) = max(0, tanh(βx))
    /// Smoother than fast_sigmoid, clipped at 0.
    private func tanhClipForward(_ x: Float, beta: Float) -> Float {
        return max(0.0, tanh(beta * x))
    }
    
    /// Gradient: dσ/dx = β · sech²(βx) if tanh(βx) > 0, else 0
    private func tanhClipBackward(_ x: Float, beta: Float) -> Float {
        let t = tanh(beta * x)
        if t <= 0 {
            return 0.0
        }
        let sech = 1.0 / cosh(beta * x)
        return beta * sech * sech
    }
}

// MARK: - Factory

extension SurrogateActivation {
    /// Creates surrogate from string name.
    ///
    /// - Parameter name: Function name from config
    /// - Throws: `RouterError.invalidSurrogate` if unknown
    public static func from(name: String) throws -> SurrogateActivation {
        guard let surrogate = SurrogateActivation(rawValue: name) else {
            throw RouterError.invalidSurrogate(name)
        }
        return surrogate
    }
}
