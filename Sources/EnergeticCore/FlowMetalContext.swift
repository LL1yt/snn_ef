import Foundation
import Metal
import SharedInfrastructure

struct FlowMetalParams {
    var count: UInt32
    var bins: UInt32
    var step: UInt32
    var baseSeed: UInt32
    var radius: Float
    var lifDecay: Float
    var lifThreshold: Float
    var lifReset: Float
    var radialBias: Float
    var spikeKick: Float
    var gainSpikeKickScale: Float
    var noiseStdPos: Float
    var noiseStdDir: Float
    var maxSpeed: Float
    var energyAlpha: Float
    var energyFloor: Float
    var energySpikeGain: Float
    var energyGainBias: Float
    var energyCap: Float
    var finalWeightPower: Float
    var gainsCount: UInt32
    var threadsPerGroup: UInt32
    var groupCount: UInt32
    // Weighted-aggregator parameters (training fast path)
    var aggEnabled: UInt32
    var aggSigmaR: Float
    var aggSigmaE: Float
    var aggAlpha: Float
    var aggBeta: Float
    var aggGamma: Float
    var aggTau: Float
    var recordCompletions: UInt32
    var recordHistogram: UInt32
}

final class FlowMetalContext {
    static var lastInitError: String?
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let stepPipeline: MTLComputePipelineState
    private let trainStepPipeline: MTLComputePipelineState
    private let finalPipeline: MTLComputePipelineState
    private let reducePipeline: MTLComputePipelineState
    private let finalizeWeightedYHatPipeline: MTLComputePipelineState

    private var particleCapacity: Int = 0
    private var binsCapacity: Int = 0
    private var groupHistogramCapacityGroups: Int = 0
    private var groupHistogramCapacityBins: Int = 0

    private var idsBuffer: MTLBuffer?
    private var posXBuffer: MTLBuffer?
    private var posYBuffer: MTLBuffer?
    private var velXBuffer: MTLBuffer?
    private var velYBuffer: MTLBuffer?
    private var energyBuffer: MTLBuffer?
    private var vBuffer: MTLBuffer?
    private var histogramBuffer: MTLBuffer?
    private var groupHistogramBuffer: MTLBuffer?
    private var gainsBuffer: MTLBuffer?
    private var projectedBinBuffer: MTLBuffer?
    private var spikedBuffer: MTLBuffer?
    private var aliveBuffer: MTLBuffer?

    // Buffers used by simulateWithCompletions fast path
    private var initialBinByIndexBuffer: MTLBuffer?
    private var completionWrittenBuffer: MTLBuffer?
    private var completionIDBuffer: MTLBuffer?
    private var completionBinBuffer: MTLBuffer?
    private var completionPosXBuffer: MTLBuffer?
    private var completionPosYBuffer: MTLBuffer?
    private var completionEnergyBuffer: MTLBuffer?
    private var completionSpikedBuffer: MTLBuffer?
    private var completionInitialBinBuffer: MTLBuffer?

    // Weighted yHat aggregation (optional)
    private var targetsRawBuffer: MTLBuffer?
    private var weightedSumBuffer: MTLBuffer?
    private var weightSumBuffer: MTLBuffer?
    private var weightedYHatBuffer: MTLBuffer?
    private var groupWeightedSumBuffer: MTLBuffer?
    private var groupWeightSumBuffer: MTLBuffer?

    // Scalar learning metrics (GPU reduced)
    private var radialMissSumBuffer: MTLBuffer?
    private var boundaryLossSumBuffer: MTLBuffer?
    private var groupRadialMissSumBuffer: MTLBuffer?
    private var groupBoundaryLossSumBuffer: MTLBuffer?

    private var groupSpikeCountBuffer: MTLBuffer?
    private var groupStepCountBuffer: MTLBuffer?
    private var groupCompletionCountBuffer: MTLBuffer?

    private var groupCounterCapacity: Int = 0

    init?() {
        FlowMetalContext.lastInitError = nil
        guard let device = MTLCreateSystemDefaultDevice() else {
            FlowMetalContext.lastInitError = "MTLCreateSystemDefaultDevice returned nil"
            return nil
        }
        guard let queue = device.makeCommandQueue() else {
            FlowMetalContext.lastInitError = "device.makeCommandQueue() returned nil"
            return nil
        }
        let library: MTLLibrary
        if let url = Bundle.module.url(forResource: "default", withExtension: "metallib", subdirectory: "Shaders")
            ?? Bundle.module.url(forResource: "default", withExtension: "metallib") {
            do {
                library = try device.makeLibrary(URL: url)
            } catch {
                FlowMetalContext.lastInitError = "device.makeLibrary(URL: \(url.path)) failed: \(error)"
                return nil
            }
        } else if let metalURL = Bundle.module.url(forResource: "FlowKernels", withExtension: "metal", subdirectory: "Shaders")
            ?? Bundle.module.url(forResource: "FlowKernels", withExtension: "metal") {
            do {
                let source = try String(contentsOf: metalURL, encoding: .utf8)
                library = try device.makeLibrary(source: source, options: nil)
            } catch {
                FlowMetalContext.lastInitError = "compile FlowKernels.metal failed at \(metalURL.path): \(error)"
                return nil
            }
        } else if let lib = device.makeDefaultLibrary() {
            library = lib
        } else if let lib = try? device.makeDefaultLibrary(bundle: .module) {
            library = lib
        } else {
            let resourcePath = Bundle.module.resourceURL?.path ?? "nil"
            FlowMetalContext.lastInitError = "No metallib or .metal source found in bundle. Bundle.module.resourceURL=\(resourcePath)"
            return nil
        }
        guard let stepFunction = library.makeFunction(name: "flow_step"),
              let trainStepFunction = library.makeFunction(name: "flow_step_train"),
              let finalFunction = library.makeFunction(name: "flow_project_final"),
              let reduceFunction = library.makeFunction(name: "flow_reduce_hist"),
              let finalizeFunction = library.makeFunction(name: "flow_finalize_weighted_yhat") else {
            FlowMetalContext.lastInitError = "Missing Metal functions flow_step/flow_step_train/flow_project_final/flow_reduce_hist/flow_finalize_weighted_yhat in library"
            return nil
        }
        do {
            self.stepPipeline = try device.makeComputePipelineState(function: stepFunction)
            self.trainStepPipeline = try device.makeComputePipelineState(function: trainStepFunction)
            self.finalPipeline = try device.makeComputePipelineState(function: finalFunction)
            self.reducePipeline = try device.makeComputePipelineState(function: reduceFunction)
            self.finalizeWeightedYHatPipeline = try device.makeComputePipelineState(function: finalizeFunction)
        } catch {
            FlowMetalContext.lastInitError = "makeComputePipelineState failed: \(error)"
            return nil
        }
        self.device = device
        self.queue = queue
    }

    func step(
        state: inout FlowState,
        cfg: FlowConfig,
        baseSeed: UInt32,
        gains: [Float]?,
        emitEvents: Bool
    ) -> [FlowStepEvent] {
        let token = LoggingHub.beginSignpost("flow.step")
        let count = state.count
        guard count > 0 else {
            LoggingHub.endSignpost("flow.step", token: token)
            return []
        }

        ensureParticleCapacity(count)
        ensureBinsCapacity(cfg.bins)

        let ids32 = state.ids.map { Int32($0) }
        writeArray(ids32, to: idsBuffer!, count: count)
        writeArray(state.posX, to: posXBuffer!, count: count)
        writeArray(state.posY, to: posYBuffer!, count: count)
        writeArray(state.velX, to: velXBuffer!, count: count)
        writeArray(state.velY, to: velYBuffer!, count: count)
        writeArray(state.energy, to: energyBuffer!, count: count)
        writeArray(state.V, to: vBuffer!, count: count)
        writeArray(state.outputs, to: histogramBuffer!, count: cfg.bins)
        fillBuffer(aliveBuffer!, value: 1, length: count * MemoryLayout<UInt8>.stride)
        let stepTG = min(stepPipeline.maxTotalThreadsPerThreadgroup, stepPipeline.threadExecutionWidth * 4)
        let threadsPerGroup = max(1, stepTG)
        let groupCount = (count + threadsPerGroup - 1) / threadsPerGroup
        ensureGroupHistogramCapacity(groupCount: groupCount, bins: cfg.bins)
        clearBuffer(groupHistogramBuffer!, length: groupCount * cfg.bins * MemoryLayout<Float>.stride)

        var gainsCount: UInt32 = 0
        if let gains, gains.count == cfg.bins {
            gainsCount = UInt32(gains.count)
            writeArray(gains, to: gainsBuffer!, count: gains.count)
        } else {
            let one: [Float] = [1.0]
            writeArray(one, to: gainsBuffer!, count: 1)
        }

        let params = FlowMetalParams(
            count: UInt32(count),
            bins: UInt32(cfg.bins),
            step: UInt32(state.step),
            baseSeed: baseSeed,
            radius: cfg.radius,
            lifDecay: cfg.lif.decay,
            lifThreshold: cfg.lif.threshold,
            lifReset: cfg.lif.resetValue,
            radialBias: cfg.dynamics.radialBias,
            spikeKick: cfg.dynamics.spikeKick,
            gainSpikeKickScale: cfg.dynamics.gainSpikeKickScale,
            noiseStdPos: cfg.dynamics.noiseStdPos,
            noiseStdDir: cfg.dynamics.noiseStdDir,
            maxSpeed: cfg.dynamics.maxSpeed,
            energyAlpha: cfg.dynamics.energyAlpha,
            energyFloor: cfg.dynamics.energyFloor,
            energySpikeGain: cfg.dynamics.energySpikeGain,
            energyGainBias: cfg.dynamics.energyGainBias,
            energyCap: cfg.dynamics.energyCap,
            finalWeightPower: cfg.finalWeightPower,
            gainsCount: gainsCount,
            threadsPerGroup: UInt32(threadsPerGroup),
            groupCount: UInt32(groupCount),
            aggEnabled: 0,
            aggSigmaR: 1,
            aggSigmaE: 1,
            aggAlpha: 1,
            aggBeta: 1,
            aggGamma: 1,
            aggTau: 1,
            recordCompletions: 0,
            recordHistogram: 0
        )

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return [] }
        enc.setComputePipelineState(stepPipeline)
        enc.setBuffer(idsBuffer, offset: 0, index: 0)
        enc.setBuffer(posXBuffer, offset: 0, index: 1)
        enc.setBuffer(posYBuffer, offset: 0, index: 2)
        enc.setBuffer(velXBuffer, offset: 0, index: 3)
        enc.setBuffer(velYBuffer, offset: 0, index: 4)
        enc.setBuffer(energyBuffer, offset: 0, index: 5)
        enc.setBuffer(vBuffer, offset: 0, index: 6)
        enc.setBuffer(histogramBuffer, offset: 0, index: 7)
        enc.setBuffer(groupHistogramBuffer, offset: 0, index: 8)
        enc.setBuffer(projectedBinBuffer, offset: 0, index: 9)
        enc.setBuffer(spikedBuffer, offset: 0, index: 10)
        enc.setBuffer(aliveBuffer, offset: 0, index: 11)
        enc.setBuffer(gainsBuffer, offset: 0, index: 12)

        var paramsCopy = params
        enc.setBytes(&paramsCopy, length: MemoryLayout<FlowMetalParams>.stride, index: 13)
        let threadsPerThreadgroup = MTLSize(
            width: max(1, stepTG),
            height: 1,
            depth: 1
        )
        let threads = MTLSize(width: count, height: 1, depth: 1)
        enc.dispatchThreads(threads, threadsPerThreadgroup: threadsPerThreadgroup)
        enc.endEncoding()

        if let reduceEnc = cmd.makeComputeCommandEncoder() {
            reduceEnc.setComputePipelineState(reducePipeline)
            reduceEnc.setBuffer(histogramBuffer, offset: 0, index: 0)
            reduceEnc.setBuffer(groupHistogramBuffer, offset: 0, index: 1)
            var reduceParams = params
            reduceEnc.setBytes(&reduceParams, length: MemoryLayout<FlowMetalParams>.stride, index: 2)
            let reduceTG = min(reducePipeline.maxTotalThreadsPerThreadgroup, reducePipeline.threadExecutionWidth * 4)
            let reduceThreadsPerThreadgroup = MTLSize(width: max(1, reduceTG), height: 1, depth: 1)
            let reduceThreads = MTLSize(width: cfg.bins, height: 1, depth: 1)
            reduceEnc.dispatchThreads(reduceThreads, threadsPerThreadgroup: reduceThreadsPerThreadgroup)
            reduceEnc.endEncoding()
        }
        cmd.commit()
        cmd.waitUntilCompleted()
        LoggingHub.endSignpost("flow.step", token: token)

        // Read back updated arrays
        state.posX = readArray(from: posXBuffer!, count: count)
        state.posY = readArray(from: posYBuffer!, count: count)
        state.velX = readArray(from: velXBuffer!, count: count)
        state.velY = readArray(from: velYBuffer!, count: count)
        state.energy = readArray(from: energyBuffer!, count: count)
        state.V = readArray(from: vBuffer!, count: count)
        state.outputs = readArray(from: histogramBuffer!, count: cfg.bins)

        let projected = readArray(from: projectedBinBuffer!, count: count) as [Int32]
        let spiked = readArray(from: spikedBuffer!, count: count) as [UInt8]
        let alive = readArray(from: aliveBuffer!, count: count) as [UInt8]

        var events: [FlowStepEvent] = []
        if emitEvents {
            events.reserveCapacity(count)
            for i in 0..<count {
                let bin = projected[i] >= 0 ? Int(projected[i]) : nil
                events.append(
                    FlowStepEvent(
                        id: state.ids[i],
                        pos: SIMD2<Float>(state.posX[i], state.posY[i]),
                        vel: SIMD2<Float>(state.velX[i], state.velY[i]),
                        energy: state.energy[i],
                        V: state.V[i],
                        spiked: spiked[i] != 0,
                        projectedBin: bin
                    )
                )
            }
        }

        // Compact in-place
        var write = 0
        for i in 0..<count where alive[i] != 0 {
            if write != i {
                state.ids[write] = state.ids[i]
                state.posX[write] = state.posX[i]
                state.posY[write] = state.posY[i]
                state.velX[write] = state.velX[i]
                state.velY[write] = state.velY[i]
                state.energy[write] = state.energy[i]
                state.V[write] = state.V[i]
            }
            write += 1
        }
        state.truncate(to: write)
        state.step += 1
        return events
    }

    func simulate(
        initial particles: [FlowParticle],
        cfg: FlowConfig,
        baseSeed: UInt32,
        gains: [Float]?
    ) -> [Float] {
        let token = LoggingHub.beginSignpost("flow.run")
        let count = particles.count
        guard count > 0 else {
            LoggingHub.endSignpost("flow.run", token: token)
            return [Float](repeating: 0, count: cfg.bins)
        }

        ensureParticleCapacity(count)
        ensureBinsCapacity(cfg.bins)

        var ids32: [Int32] = []
        var posX: [Float] = []
        var posY: [Float] = []
        var velX: [Float] = []
        var velY: [Float] = []
        var energy: [Float] = []
        var v: [Float] = []
        ids32.reserveCapacity(count)
        posX.reserveCapacity(count)
        posY.reserveCapacity(count)
        velX.reserveCapacity(count)
        velY.reserveCapacity(count)
        energy.reserveCapacity(count)
        v.reserveCapacity(count)

        for p in particles {
            ids32.append(Int32(p.id))
            posX.append(p.pos.x)
            posY.append(p.pos.y)
            velX.append(p.vel.x)
            velY.append(p.vel.y)
            energy.append(p.energy)
            v.append(p.V)
        }

        writeArray(ids32, to: idsBuffer!, count: count)
        writeArray(posX, to: posXBuffer!, count: count)
        writeArray(posY, to: posYBuffer!, count: count)
        writeArray(velX, to: velXBuffer!, count: count)
        writeArray(velY, to: velYBuffer!, count: count)
        writeArray(energy, to: energyBuffer!, count: count)
        writeArray(v, to: vBuffer!, count: count)
        clearBuffer(histogramBuffer!, length: cfg.bins * MemoryLayout<Float>.stride)
        fillBuffer(aliveBuffer!, value: 1, length: count * MemoryLayout<UInt8>.stride)
        let stepTG = min(stepPipeline.maxTotalThreadsPerThreadgroup, stepPipeline.threadExecutionWidth * 4)
        let stepThreadsPerGroup = max(1, stepTG)
        let stepGroupCount = (count + stepThreadsPerGroup - 1) / stepThreadsPerGroup
        let finalTG = min(finalPipeline.maxTotalThreadsPerThreadgroup, finalPipeline.threadExecutionWidth * 4)
        let finalThreadsPerGroup = max(1, finalTG)
        let finalGroupCount = (count + finalThreadsPerGroup - 1) / finalThreadsPerGroup
        let maxGroupCount = max(stepGroupCount, finalGroupCount)
        ensureGroupHistogramCapacity(groupCount: maxGroupCount, bins: cfg.bins)
        clearBuffer(groupHistogramBuffer!, length: maxGroupCount * cfg.bins * MemoryLayout<Float>.stride)

        var gainsCount: UInt32 = 0
        if let gains, gains.count == cfg.bins {
            gainsCount = UInt32(gains.count)
            writeArray(gains, to: gainsBuffer!, count: gains.count)
        } else {
            let one: [Float] = [1.0]
            writeArray(one, to: gainsBuffer!, count: 1)
        }

        var stepParams = FlowMetalParams(
            count: UInt32(count),
            bins: UInt32(cfg.bins),
            step: 0,
            baseSeed: baseSeed,
            radius: cfg.radius,
            lifDecay: cfg.lif.decay,
            lifThreshold: cfg.lif.threshold,
            lifReset: cfg.lif.resetValue,
            radialBias: cfg.dynamics.radialBias,
            spikeKick: cfg.dynamics.spikeKick,
            gainSpikeKickScale: cfg.dynamics.gainSpikeKickScale,
            noiseStdPos: cfg.dynamics.noiseStdPos,
            noiseStdDir: cfg.dynamics.noiseStdDir,
            maxSpeed: cfg.dynamics.maxSpeed,
            energyAlpha: cfg.dynamics.energyAlpha,
            energyFloor: cfg.dynamics.energyFloor,
            energySpikeGain: cfg.dynamics.energySpikeGain,
            energyGainBias: cfg.dynamics.energyGainBias,
            energyCap: cfg.dynamics.energyCap,
            finalWeightPower: cfg.finalWeightPower,
            gainsCount: gainsCount,
            threadsPerGroup: UInt32(stepThreadsPerGroup),
            groupCount: UInt32(stepGroupCount),
            aggEnabled: 0,
            aggSigmaR: 1,
            aggSigmaE: 1,
            aggAlpha: 1,
            aggBeta: 1,
            aggGamma: 1,
            aggTau: 1,
            recordCompletions: 0,
            recordHistogram: 0
        )

        guard let cmd = queue.makeCommandBuffer(),
              let stepEnc = cmd.makeComputeCommandEncoder() else {
            LoggingHub.endSignpost("flow.run", token: token)
            return readArray(from: histogramBuffer!, count: cfg.bins) as [Float]
        }
        stepEnc.setComputePipelineState(stepPipeline)
        stepEnc.setBuffer(idsBuffer, offset: 0, index: 0)
        stepEnc.setBuffer(posXBuffer, offset: 0, index: 1)
        stepEnc.setBuffer(posYBuffer, offset: 0, index: 2)
        stepEnc.setBuffer(velXBuffer, offset: 0, index: 3)
        stepEnc.setBuffer(velYBuffer, offset: 0, index: 4)
        stepEnc.setBuffer(energyBuffer, offset: 0, index: 5)
        stepEnc.setBuffer(vBuffer, offset: 0, index: 6)
        stepEnc.setBuffer(histogramBuffer, offset: 0, index: 7)
        stepEnc.setBuffer(groupHistogramBuffer, offset: 0, index: 8)
        stepEnc.setBuffer(projectedBinBuffer, offset: 0, index: 9)
        stepEnc.setBuffer(spikedBuffer, offset: 0, index: 10)
        stepEnc.setBuffer(aliveBuffer, offset: 0, index: 11)
        stepEnc.setBuffer(gainsBuffer, offset: 0, index: 12)

        let stepThreadsPerThreadgroup = MTLSize(width: max(1, stepTG), height: 1, depth: 1)
        let stepThreads = MTLSize(width: count, height: 1, depth: 1)
        for step in 0..<cfg.T {
            stepParams.step = UInt32(step)
            var paramsCopy = stepParams
            stepEnc.setBytes(&paramsCopy, length: MemoryLayout<FlowMetalParams>.stride, index: 13)
            stepEnc.dispatchThreads(stepThreads, threadsPerThreadgroup: stepThreadsPerThreadgroup)
        }
        stepEnc.endEncoding()

        let finalParams = FlowMetalParams(
            count: UInt32(count),
            bins: UInt32(cfg.bins),
            step: UInt32(cfg.T),
            baseSeed: 0,
            radius: cfg.radius,
            lifDecay: 0,
            lifThreshold: 0,
            lifReset: 0,
            radialBias: 0,
            spikeKick: 0,
            gainSpikeKickScale: 0,
            noiseStdPos: 0,
            noiseStdDir: 0,
            maxSpeed: 0,
            energyAlpha: 0,
            energyFloor: 0,
            energySpikeGain: 0,
            energyGainBias: 0,
            energyCap: 0,
            finalWeightPower: cfg.finalWeightPower,
            gainsCount: gainsCount,
            threadsPerGroup: UInt32(finalThreadsPerGroup),
            groupCount: UInt32(finalGroupCount),
            aggEnabled: 0,
            aggSigmaR: 1,
            aggSigmaE: 1,
            aggAlpha: 1,
            aggBeta: 1,
            aggGamma: 1,
            aggTau: 1,
            recordCompletions: 0,
            recordHistogram: 0
        )

        guard let finalEnc = cmd.makeComputeCommandEncoder() else {
            LoggingHub.endSignpost("flow.run", token: token)
            return readArray(from: histogramBuffer!, count: cfg.bins) as [Float]
        }

        finalEnc.setComputePipelineState(finalPipeline)
        finalEnc.setBuffer(posXBuffer, offset: 0, index: 0)
        finalEnc.setBuffer(posYBuffer, offset: 0, index: 1)
        finalEnc.setBuffer(energyBuffer, offset: 0, index: 2)
        finalEnc.setBuffer(histogramBuffer, offset: 0, index: 3)
        finalEnc.setBuffer(groupHistogramBuffer, offset: 0, index: 4)
        finalEnc.setBuffer(aliveBuffer, offset: 0, index: 5)
        finalEnc.setBuffer(gainsBuffer, offset: 0, index: 6)
        var finalParamsCopy = finalParams
        finalEnc.setBytes(&finalParamsCopy, length: MemoryLayout<FlowMetalParams>.stride, index: 7)
        let threadsPerThreadgroup = MTLSize(width: max(1, finalTG), height: 1, depth: 1)
        let threads = MTLSize(width: count, height: 1, depth: 1)
        finalEnc.dispatchThreads(threads, threadsPerThreadgroup: threadsPerThreadgroup)
        finalEnc.endEncoding()
        if let reduceEnc = cmd.makeComputeCommandEncoder() {
            reduceEnc.setComputePipelineState(reducePipeline)
            reduceEnc.setBuffer(histogramBuffer, offset: 0, index: 0)
            reduceEnc.setBuffer(groupHistogramBuffer, offset: 0, index: 1)
            var reduceParams = finalParams
            reduceParams.groupCount = UInt32(maxGroupCount)
            reduceEnc.setBytes(&reduceParams, length: MemoryLayout<FlowMetalParams>.stride, index: 2)
            let reduceTG = min(reducePipeline.maxTotalThreadsPerThreadgroup, reducePipeline.threadExecutionWidth * 4)
            let reduceThreadsPerThreadgroup = MTLSize(width: max(1, reduceTG), height: 1, depth: 1)
            let reduceThreads = MTLSize(width: cfg.bins, height: 1, depth: 1)
            reduceEnc.dispatchThreads(reduceThreads, threadsPerThreadgroup: reduceThreadsPerThreadgroup)
            reduceEnc.endEncoding()
        }
        cmd.commit()
        cmd.waitUntilCompleted()

        let outputs: [Float] = readArray(from: histogramBuffer!, count: cfg.bins)
        LoggingHub.endSignpost("flow.run", token: token)
        return outputs
    }

    func simulateWithCompletions(
        initial particles: [FlowParticle],
        cfg: FlowConfig,
        baseSeed: UInt32,
        gains: [Float]?,
        steps: Int,
        initialBinsByIndex: [Int32]?,
        targetsRaw: [Float]? = nil,
        aggregator: AggregatorConfig? = nil,
        includeCompletions: Bool = true,
        includeHistogram: Bool = true
    ) -> FlowSimulationSummary {
        let token = LoggingHub.beginSignpost("flow.learn.run")
        let count = particles.count
        guard count > 0 else {
            LoggingHub.endSignpost("flow.learn.run", token: token)
            return FlowSimulationSummary(
                bins: [Float](repeating: 0, count: cfg.bins),
                spikeCount: 0,
                particleStepCount: 0,
                completionCount: 0,
                completions: []
            )
        }

        ensureParticleCapacity(count)
        ensureBinsCapacity(cfg.bins)

        var ids32: [Int32] = []
        var posX: [Float] = []
        var posY: [Float] = []
        var velX: [Float] = []
        var velY: [Float] = []
        var energy: [Float] = []
        var v: [Float] = []
        ids32.reserveCapacity(count)
        posX.reserveCapacity(count)
        posY.reserveCapacity(count)
        velX.reserveCapacity(count)
        velY.reserveCapacity(count)
        energy.reserveCapacity(count)
        v.reserveCapacity(count)

        for p in particles {
            ids32.append(Int32(p.id))
            posX.append(p.pos.x)
            posY.append(p.pos.y)
            velX.append(p.vel.x)
            velY.append(p.vel.y)
            energy.append(p.energy)
            v.append(p.V)
        }

        writeArray(ids32, to: idsBuffer!, count: count)
        writeArray(posX, to: posXBuffer!, count: count)
        writeArray(posY, to: posYBuffer!, count: count)
        writeArray(velX, to: velXBuffer!, count: count)
        writeArray(velY, to: velYBuffer!, count: count)
        writeArray(energy, to: energyBuffer!, count: count)
        writeArray(v, to: vBuffer!, count: count)

        if includeHistogram {
            clearBuffer(histogramBuffer!, length: cfg.bins * MemoryLayout<Float>.stride)
        }
        fillBuffer(aliveBuffer!, value: 1, length: count * MemoryLayout<UInt8>.stride)

        // Step threadgroup sizing (used for group id mapping in flow_step_train)
        let stepTG = min(trainStepPipeline.maxTotalThreadsPerThreadgroup, trainStepPipeline.threadExecutionWidth * 4)
        let stepThreadsPerGroup = max(1, stepTG)
        let stepGroupCount = (count + stepThreadsPerGroup - 1) / stepThreadsPerGroup
        ensureGroupCounterCapacity(stepGroupCount)
        ensureScalarMetricBuffers()
        fillBuffer(groupSpikeCountBuffer!, value: 0, length: stepGroupCount * MemoryLayout<UInt32>.stride)
        fillBuffer(groupStepCountBuffer!, value: 0, length: stepGroupCount * MemoryLayout<UInt32>.stride)
        fillBuffer(groupCompletionCountBuffer!, value: 0, length: stepGroupCount * MemoryLayout<UInt32>.stride)
        clearBuffer(groupRadialMissSumBuffer!, length: stepGroupCount * MemoryLayout<Float>.stride)
        clearBuffer(groupBoundaryLossSumBuffer!, length: stepGroupCount * MemoryLayout<Float>.stride)
        clearBuffer(radialMissSumBuffer!, length: MemoryLayout<Float>.stride)
        clearBuffer(boundaryLossSumBuffer!, length: MemoryLayout<Float>.stride)

        // Final threadgroup sizing (used only for final projection -> groupHistogram)
        let finalTG = min(finalPipeline.maxTotalThreadsPerThreadgroup, finalPipeline.threadExecutionWidth * 4)
        let finalThreadsPerGroup = max(1, finalTG)
        let finalGroupCount = (count + finalThreadsPerGroup - 1) / finalThreadsPerGroup
        let maxGroupCount = max(stepGroupCount, finalGroupCount)
        ensureGroupHistogramCapacity(groupCount: maxGroupCount, bins: cfg.bins)
        if includeHistogram {
            clearBuffer(groupHistogramBuffer!, length: maxGroupCount * cfg.bins * MemoryLayout<Float>.stride)
        }

        // Gains
        var gainsCount: UInt32 = 0
        if let gains, gains.count == cfg.bins {
            gainsCount = UInt32(gains.count)
            writeArray(gains, to: gainsBuffer!, count: gains.count)
        } else {
            let one: [Float] = [1.0]
            writeArray(one, to: gainsBuffer!, count: 1)
        }

        let wantsWeightedYHat =
            (targetsRaw != nil)
            && (aggregator != nil)
            && (targetsRaw!.count == cfg.bins)

        if wantsWeightedYHat {
            writeArray(targetsRaw!, to: targetsRawBuffer!, count: cfg.bins)
            clearBuffer(weightedSumBuffer!, length: cfg.bins * MemoryLayout<Float>.stride)
            clearBuffer(weightSumBuffer!, length: cfg.bins * MemoryLayout<Float>.stride)
            clearBuffer(weightedYHatBuffer!, length: cfg.bins * MemoryLayout<Float>.stride)
            clearBuffer(groupWeightedSumBuffer!, length: maxGroupCount * cfg.bins * MemoryLayout<Float>.stride)
            clearBuffer(groupWeightSumBuffer!, length: maxGroupCount * cfg.bins * MemoryLayout<Float>.stride)
        } else {
            // Still bind buffers; kernel checks aggEnabled.
            clearBuffer(targetsRawBuffer!, length: cfg.bins * MemoryLayout<Float>.stride)
        }

        // Initial bins (always provided; -1 when unknown)
        if let initialBinsByIndex, initialBinsByIndex.count == count {
            writeArray(initialBinsByIndex, to: initialBinByIndexBuffer!, count: count)
        } else {
            let fallback = [Int32](repeating: -1, count: count)
            writeArray(fallback, to: initialBinByIndexBuffer!, count: count)
        }

        // Completion buffers init
        // If includeCompletions=false, GPU also skips writing completion records (recordCompletions=0), so we avoid clears.
        if includeCompletions {
            fillBuffer(completionWrittenBuffer!, value: 0, length: count * MemoryLayout<UInt8>.stride)
            fillBuffer(completionSpikedBuffer!, value: 0, length: count * MemoryLayout<UInt8>.stride)
            fillBuffer(completionIDBuffer!, value: 0xFF, length: count * MemoryLayout<Int32>.stride)
            fillBuffer(completionBinBuffer!, value: 0xFF, length: count * MemoryLayout<Int32>.stride)
            fillBuffer(completionInitialBinBuffer!, value: 0xFF, length: count * MemoryLayout<Int32>.stride)
            clearBuffer(completionPosXBuffer!, length: count * MemoryLayout<Float>.stride)
            clearBuffer(completionPosYBuffer!, length: count * MemoryLayout<Float>.stride)
            clearBuffer(completionEnergyBuffer!, length: count * MemoryLayout<Float>.stride)
        }

        var stepParams = FlowMetalParams(
            count: UInt32(count),
            bins: UInt32(cfg.bins),
            step: 0,
            baseSeed: baseSeed,
            radius: cfg.radius,
            lifDecay: cfg.lif.decay,
            lifThreshold: cfg.lif.threshold,
            lifReset: cfg.lif.resetValue,
            radialBias: cfg.dynamics.radialBias,
            spikeKick: cfg.dynamics.spikeKick,
            gainSpikeKickScale: cfg.dynamics.gainSpikeKickScale,
            noiseStdPos: cfg.dynamics.noiseStdPos,
            noiseStdDir: cfg.dynamics.noiseStdDir,
            maxSpeed: cfg.dynamics.maxSpeed,
            energyAlpha: cfg.dynamics.energyAlpha,
            energyFloor: cfg.dynamics.energyFloor,
            energySpikeGain: cfg.dynamics.energySpikeGain,
            energyGainBias: cfg.dynamics.energyGainBias,
            energyCap: cfg.dynamics.energyCap,
            finalWeightPower: cfg.finalWeightPower,
            gainsCount: gainsCount,
            threadsPerGroup: UInt32(stepThreadsPerGroup),
            groupCount: UInt32(stepGroupCount),
            aggEnabled: wantsWeightedYHat ? 1 : 0,
            aggSigmaR: wantsWeightedYHat ? (aggregator!.sigmaR) : 1,
            aggSigmaE: wantsWeightedYHat ? (aggregator!.sigmaE) : 1,
            aggAlpha: wantsWeightedYHat ? (aggregator!.alpha) : 1,
            aggBeta: wantsWeightedYHat ? (aggregator!.beta) : 1,
            aggGamma: wantsWeightedYHat ? (aggregator!.gamma) : 1,
            aggTau: wantsWeightedYHat ? (aggregator!.tau) : 1,
            recordCompletions: includeCompletions ? 1 : 0,
            recordHistogram: includeHistogram ? 1 : 0
        )

        guard let cmd = queue.makeCommandBuffer(),
              let stepEnc = cmd.makeComputeCommandEncoder() else {
            LoggingHub.endSignpost("flow.learn.run", token: token)
            return FlowSimulationSummary(
                bins: [Float](repeating: 0, count: cfg.bins),
                spikeCount: 0,
                particleStepCount: 0,
                completionCount: 0,
                completions: []
            )
        }

        // Step phase
        stepEnc.setComputePipelineState(trainStepPipeline)
        stepEnc.setBuffer(idsBuffer, offset: 0, index: 0)
        stepEnc.setBuffer(posXBuffer, offset: 0, index: 1)
        stepEnc.setBuffer(posYBuffer, offset: 0, index: 2)
        stepEnc.setBuffer(velXBuffer, offset: 0, index: 3)
        stepEnc.setBuffer(velYBuffer, offset: 0, index: 4)
        stepEnc.setBuffer(energyBuffer, offset: 0, index: 5)
        stepEnc.setBuffer(vBuffer, offset: 0, index: 6)
        stepEnc.setBuffer(histogramBuffer, offset: 0, index: 7)
        stepEnc.setBuffer(groupHistogramBuffer, offset: 0, index: 8)
        stepEnc.setBuffer(aliveBuffer, offset: 0, index: 9)
        stepEnc.setBuffer(gainsBuffer, offset: 0, index: 10)
        stepEnc.setBuffer(initialBinByIndexBuffer, offset: 0, index: 11)
        stepEnc.setBuffer(completionWrittenBuffer, offset: 0, index: 12)
        stepEnc.setBuffer(completionIDBuffer, offset: 0, index: 13)
        stepEnc.setBuffer(completionBinBuffer, offset: 0, index: 14)
        stepEnc.setBuffer(completionPosXBuffer, offset: 0, index: 15)
        stepEnc.setBuffer(completionPosYBuffer, offset: 0, index: 16)
        stepEnc.setBuffer(completionEnergyBuffer, offset: 0, index: 17)
        stepEnc.setBuffer(completionSpikedBuffer, offset: 0, index: 18)
        stepEnc.setBuffer(completionInitialBinBuffer, offset: 0, index: 19)
        stepEnc.setBuffer(groupSpikeCountBuffer, offset: 0, index: 20)
        stepEnc.setBuffer(groupStepCountBuffer, offset: 0, index: 21)
        stepEnc.setBuffer(groupCompletionCountBuffer, offset: 0, index: 22)
        stepEnc.setBuffer(groupWeightedSumBuffer, offset: 0, index: 23)
        stepEnc.setBuffer(groupWeightSumBuffer, offset: 0, index: 24)
        stepEnc.setBuffer(targetsRawBuffer, offset: 0, index: 25)
        stepEnc.setBuffer(groupRadialMissSumBuffer, offset: 0, index: 26)
        stepEnc.setBuffer(groupBoundaryLossSumBuffer, offset: 0, index: 27)

        let threadsPerThreadgroup = MTLSize(width: max(1, stepTG), height: 1, depth: 1)
        let threads = MTLSize(width: count, height: 1, depth: 1)
        for s in 0..<max(0, steps) {
            stepParams.step = UInt32(s)
            var paramsCopy = stepParams
            stepEnc.setBytes(&paramsCopy, length: MemoryLayout<FlowMetalParams>.stride, index: 28)
            stepEnc.dispatchThreads(threads, threadsPerThreadgroup: threadsPerThreadgroup)
        }
        stepEnc.endEncoding()

        // Final projection phase (alive-only)
        if includeHistogram {
            let finalParams = FlowMetalParams(
            count: UInt32(count),
            bins: UInt32(cfg.bins),
            step: UInt32(steps),
            baseSeed: 0,
            radius: cfg.radius,
            lifDecay: 0,
            lifThreshold: 0,
            lifReset: 0,
            radialBias: 0,
            spikeKick: 0,
            gainSpikeKickScale: 0,
            noiseStdPos: 0,
            noiseStdDir: 0,
            maxSpeed: 0,
            energyAlpha: 0,
            energyFloor: 0,
            energySpikeGain: 0,
            energyGainBias: 0,
            energyCap: 0,
            finalWeightPower: cfg.finalWeightPower,
            gainsCount: gainsCount,
            threadsPerGroup: UInt32(finalThreadsPerGroup),
            groupCount: UInt32(finalGroupCount),
            aggEnabled: 0,
            aggSigmaR: 1,
            aggSigmaE: 1,
            aggAlpha: 1,
            aggBeta: 1,
            aggGamma: 1,
            aggTau: 1,
            recordCompletions: 0,
            recordHistogram: 1
        )

            if let finalEnc = cmd.makeComputeCommandEncoder() {
                finalEnc.setComputePipelineState(finalPipeline)
                finalEnc.setBuffer(posXBuffer, offset: 0, index: 0)
                finalEnc.setBuffer(posYBuffer, offset: 0, index: 1)
                finalEnc.setBuffer(energyBuffer, offset: 0, index: 2)
                finalEnc.setBuffer(histogramBuffer, offset: 0, index: 3)
                finalEnc.setBuffer(groupHistogramBuffer, offset: 0, index: 4)
                finalEnc.setBuffer(aliveBuffer, offset: 0, index: 5)
                finalEnc.setBuffer(gainsBuffer, offset: 0, index: 6)
                var finalCopy = finalParams
                finalEnc.setBytes(&finalCopy, length: MemoryLayout<FlowMetalParams>.stride, index: 7)
                let finalThreadsPerThreadgroup = MTLSize(width: max(1, finalTG), height: 1, depth: 1)
                finalEnc.dispatchThreads(threads, threadsPerThreadgroup: finalThreadsPerThreadgroup)
                finalEnc.endEncoding()
            }

            // Reduce histogram (sum across maxGroupCount)
            if let reduceEnc = cmd.makeComputeCommandEncoder() {
                reduceEnc.setComputePipelineState(reducePipeline)
                reduceEnc.setBuffer(histogramBuffer, offset: 0, index: 0)
                reduceEnc.setBuffer(groupHistogramBuffer, offset: 0, index: 1)
                var reduceParams = finalParams
                reduceParams.groupCount = UInt32(maxGroupCount)
                reduceEnc.setBytes(&reduceParams, length: MemoryLayout<FlowMetalParams>.stride, index: 2)
                let reduceTG = min(reducePipeline.maxTotalThreadsPerThreadgroup, reducePipeline.threadExecutionWidth * 4)
                let reduceThreadsPerThreadgroup = MTLSize(width: max(1, reduceTG), height: 1, depth: 1)
                let reduceThreads = MTLSize(width: cfg.bins, height: 1, depth: 1)
                reduceEnc.dispatchThreads(reduceThreads, threadsPerThreadgroup: reduceThreadsPerThreadgroup)
                reduceEnc.endEncoding()
            }
        }

        if wantsWeightedYHat, let weightedSumBuffer, let weightSumBuffer, let weightedYHatBuffer {
            // Reduce weighted sums across step-groupCount
            if let reduceEnc = cmd.makeComputeCommandEncoder() {
                reduceEnc.setComputePipelineState(reducePipeline)
                reduceEnc.setBuffer(weightedSumBuffer, offset: 0, index: 0)
                reduceEnc.setBuffer(groupWeightedSumBuffer, offset: 0, index: 1)
                var reduceParams = stepParams
                reduceParams.groupCount = UInt32(stepGroupCount)
                reduceEnc.setBytes(&reduceParams, length: MemoryLayout<FlowMetalParams>.stride, index: 2)
                let reduceTG = min(reducePipeline.maxTotalThreadsPerThreadgroup, reducePipeline.threadExecutionWidth * 4)
                let reduceThreadsPerThreadgroup = MTLSize(width: max(1, reduceTG), height: 1, depth: 1)
                let reduceThreads = MTLSize(width: cfg.bins, height: 1, depth: 1)
                reduceEnc.dispatchThreads(reduceThreads, threadsPerThreadgroup: reduceThreadsPerThreadgroup)
                reduceEnc.endEncoding()
            }
            if let reduceEnc = cmd.makeComputeCommandEncoder() {
                reduceEnc.setComputePipelineState(reducePipeline)
                reduceEnc.setBuffer(weightSumBuffer, offset: 0, index: 0)
                reduceEnc.setBuffer(groupWeightSumBuffer, offset: 0, index: 1)
                var reduceParams = stepParams
                reduceParams.groupCount = UInt32(stepGroupCount)
                reduceEnc.setBytes(&reduceParams, length: MemoryLayout<FlowMetalParams>.stride, index: 2)
                let reduceTG = min(reducePipeline.maxTotalThreadsPerThreadgroup, reducePipeline.threadExecutionWidth * 4)
                let reduceThreadsPerThreadgroup = MTLSize(width: max(1, reduceTG), height: 1, depth: 1)
                let reduceThreads = MTLSize(width: cfg.bins, height: 1, depth: 1)
                reduceEnc.dispatchThreads(reduceThreads, threadsPerThreadgroup: reduceThreadsPerThreadgroup)
                reduceEnc.endEncoding()
            }

            // Finalize yHat on GPU: yHat[b] = sumWE[b] / sumW[b]
            if let finalizeEnc = cmd.makeComputeCommandEncoder() {
                finalizeEnc.setComputePipelineState(finalizeWeightedYHatPipeline)
                finalizeEnc.setBuffer(weightedSumBuffer, offset: 0, index: 0)
                finalizeEnc.setBuffer(weightSumBuffer, offset: 0, index: 1)
                finalizeEnc.setBuffer(weightedYHatBuffer, offset: 0, index: 2)
                var p = stepParams
                finalizeEnc.setBytes(&p, length: MemoryLayout<FlowMetalParams>.stride, index: 3)
                let tg = min(finalizeWeightedYHatPipeline.maxTotalThreadsPerThreadgroup, finalizeWeightedYHatPipeline.threadExecutionWidth * 4)
                let threadsPerThreadgroup = MTLSize(width: max(1, tg), height: 1, depth: 1)
                let threads = MTLSize(width: cfg.bins, height: 1, depth: 1)
                finalizeEnc.dispatchThreads(threads, threadsPerThreadgroup: threadsPerThreadgroup)
                finalizeEnc.endEncoding()
            }
        }

        // Reduce scalar metrics (sum across stepGroupCount into 1 float each)
        if let reduceEnc = cmd.makeComputeCommandEncoder() {
            reduceEnc.setComputePipelineState(reducePipeline)
            reduceEnc.setBuffer(radialMissSumBuffer, offset: 0, index: 0)
            reduceEnc.setBuffer(groupRadialMissSumBuffer, offset: 0, index: 1)
            var reduceParams = stepParams
            reduceParams.bins = 1
            reduceParams.groupCount = UInt32(stepGroupCount)
            reduceEnc.setBytes(&reduceParams, length: MemoryLayout<FlowMetalParams>.stride, index: 2)
            let reduceTG = min(reducePipeline.maxTotalThreadsPerThreadgroup, reducePipeline.threadExecutionWidth * 4)
            let reduceThreadsPerThreadgroup = MTLSize(width: max(1, reduceTG), height: 1, depth: 1)
            let reduceThreads = MTLSize(width: 1, height: 1, depth: 1)
            reduceEnc.dispatchThreads(reduceThreads, threadsPerThreadgroup: reduceThreadsPerThreadgroup)
            reduceEnc.endEncoding()
        }
        if let reduceEnc = cmd.makeComputeCommandEncoder() {
            reduceEnc.setComputePipelineState(reducePipeline)
            reduceEnc.setBuffer(boundaryLossSumBuffer, offset: 0, index: 0)
            reduceEnc.setBuffer(groupBoundaryLossSumBuffer, offset: 0, index: 1)
            var reduceParams = stepParams
            reduceParams.bins = 1
            reduceParams.groupCount = UInt32(stepGroupCount)
            reduceEnc.setBytes(&reduceParams, length: MemoryLayout<FlowMetalParams>.stride, index: 2)
            let reduceTG = min(reducePipeline.maxTotalThreadsPerThreadgroup, reducePipeline.threadExecutionWidth * 4)
            let reduceThreadsPerThreadgroup = MTLSize(width: max(1, reduceTG), height: 1, depth: 1)
            let reduceThreads = MTLSize(width: 1, height: 1, depth: 1)
            reduceEnc.dispatchThreads(reduceThreads, threadsPerThreadgroup: reduceThreadsPerThreadgroup)
            reduceEnc.endEncoding()
        }

        cmd.commit()
        cmd.waitUntilCompleted()

        let bins: [Float]
        if includeHistogram {
            bins = readArray(from: histogramBuffer!, count: cfg.bins)
        } else {
            bins = []
        }

        let weightedYHat: [Float]?
        if wantsWeightedYHat {
            weightedYHat = readArray(from: weightedYHatBuffer!, count: cfg.bins)
        } else {
            weightedYHat = nil
        }

        let groupSpikes: [UInt32] = readArray(from: groupSpikeCountBuffer!, count: stepGroupCount)
        let groupSteps: [UInt32] = readArray(from: groupStepCountBuffer!, count: stepGroupCount)
        let groupCompletions: [UInt32] = readArray(from: groupCompletionCountBuffer!, count: stepGroupCount)
        let spikeCount = groupSpikes.reduce(0, &+)
        let particleStepCount = groupSteps.reduce(0, &+)
        let completionCount = groupCompletions.reduce(0, &+)

        let radialMissSumArr: [Float] = readArray(from: radialMissSumBuffer!, count: 1)
        let boundaryLossSumArr: [Float] = readArray(from: boundaryLossSumBuffer!, count: 1)
        let radialMissSum = radialMissSumArr.first ?? 0
        let boundaryLossSum = boundaryLossSumArr.first ?? 0

        let meanRadialMiss: Float
        let boundaryLoss: Float
        if completionCount > 0 {
            let denom = Float(completionCount)
            meanRadialMiss = radialMissSum / denom
            boundaryLoss = boundaryLossSum / denom
        } else {
            meanRadialMiss = 0
            boundaryLoss = 0
        }

        let completions: [GPUCompletion]
        if includeCompletions {
            let compID: [Int32] = readArray(from: completionIDBuffer!, count: count)
            let compBin: [Int32] = readArray(from: completionBinBuffer!, count: count)
            let compX: [Float] = readArray(from: completionPosXBuffer!, count: count)
            let compY: [Float] = readArray(from: completionPosYBuffer!, count: count)
            let compE: [Float] = readArray(from: completionEnergyBuffer!, count: count)
            let compS: [UInt8] = readArray(from: completionSpikedBuffer!, count: count)
            let compInit: [Int32] = readArray(from: completionInitialBinBuffer!, count: count)

            var tmp: [GPUCompletion] = []
            tmp.reserveCapacity(count)
            for i in 0..<count {
                tmp.append(
                    GPUCompletion(
                        particleID: compID[i],
                        bin: compBin[i],
                        x: compX[i],
                        y: compY[i],
                        energy: compE[i],
                        spiked: compS[i],
                        initialBin: compInit[i]
                    )
                )
            }
            completions = tmp
        } else {
            completions = []
        }

        LoggingHub.endSignpost("flow.learn.run", token: token)
        return FlowSimulationSummary(
            bins: bins,
            spikeCount: spikeCount,
            particleStepCount: particleStepCount,
            completionCount: completionCount,
            completions: completions,
            meanRadialMiss: meanRadialMiss,
            boundaryLoss: boundaryLoss,
            weightedYHat: weightedYHat
        )
    }

    func projectFinal(
        state: inout FlowState,
        cfg: FlowConfig,
        gains: [Float]?
    ) {
        let token = LoggingHub.beginSignpost("flow.project")
        let count = state.count
        guard count > 0 else {
            LoggingHub.endSignpost("flow.project", token: token)
            return
        }

        ensureParticleCapacity(count)
        ensureBinsCapacity(cfg.bins)

        writeArray(state.posX, to: posXBuffer!, count: count)
        writeArray(state.posY, to: posYBuffer!, count: count)
        writeArray(state.energy, to: energyBuffer!, count: count)
        writeArray(state.outputs, to: histogramBuffer!, count: cfg.bins)
        fillBuffer(aliveBuffer!, value: 1, length: count * MemoryLayout<UInt8>.stride)
        let finalTG = min(finalPipeline.maxTotalThreadsPerThreadgroup, finalPipeline.threadExecutionWidth * 4)
        let threadsPerGroup = max(1, finalTG)
        let groupCount = (count + threadsPerGroup - 1) / threadsPerGroup
        ensureGroupHistogramCapacity(groupCount: groupCount, bins: cfg.bins)

        var gainsCount: UInt32 = 0
        if let gains, gains.count == cfg.bins {
            gainsCount = UInt32(gains.count)
            writeArray(gains, to: gainsBuffer!, count: gains.count)
        } else {
            let one: [Float] = [1.0]
            writeArray(one, to: gainsBuffer!, count: 1)
        }

        let params = FlowMetalParams(
            count: UInt32(count),
            bins: UInt32(cfg.bins),
            step: UInt32(state.step),
            baseSeed: 0,
            radius: cfg.radius,
            lifDecay: 0,
            lifThreshold: 0,
            lifReset: 0,
            radialBias: 0,
            spikeKick: 0,
            gainSpikeKickScale: 0,
            noiseStdPos: 0,
            noiseStdDir: 0,
            maxSpeed: 0,
            energyAlpha: 0,
            energyFloor: 0,
            energySpikeGain: 0,
            energyGainBias: 0,
            energyCap: 0,
            finalWeightPower: cfg.finalWeightPower,
            gainsCount: gainsCount,
            threadsPerGroup: UInt32(threadsPerGroup),
            groupCount: UInt32(groupCount),
            aggEnabled: 0,
            aggSigmaR: 1,
            aggSigmaE: 1,
            aggAlpha: 1,
            aggBeta: 1,
            aggGamma: 1,
            aggTau: 1,
            recordCompletions: 0,
            recordHistogram: 0
        )

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return }
        clearBuffer(groupHistogramBuffer!, length: groupCount * cfg.bins * MemoryLayout<Float>.stride)
        enc.setComputePipelineState(finalPipeline)
        enc.setBuffer(posXBuffer, offset: 0, index: 0)
        enc.setBuffer(posYBuffer, offset: 0, index: 1)
        enc.setBuffer(energyBuffer, offset: 0, index: 2)
        enc.setBuffer(histogramBuffer, offset: 0, index: 3)
        enc.setBuffer(groupHistogramBuffer, offset: 0, index: 4)
        enc.setBuffer(aliveBuffer, offset: 0, index: 5)
        enc.setBuffer(gainsBuffer, offset: 0, index: 6)
        var paramsCopy = params
        enc.setBytes(&paramsCopy, length: MemoryLayout<FlowMetalParams>.stride, index: 7)
        let threadsPerThreadgroup = MTLSize(
            width: max(1, finalTG),
            height: 1,
            depth: 1
        )
        let threads = MTLSize(width: count, height: 1, depth: 1)
        enc.dispatchThreads(threads, threadsPerThreadgroup: threadsPerThreadgroup)
        enc.endEncoding()
        if let reduceEnc = cmd.makeComputeCommandEncoder() {
            reduceEnc.setComputePipelineState(reducePipeline)
            reduceEnc.setBuffer(histogramBuffer, offset: 0, index: 0)
            reduceEnc.setBuffer(groupHistogramBuffer, offset: 0, index: 1)
            var reduceParams = params
            reduceEnc.setBytes(&reduceParams, length: MemoryLayout<FlowMetalParams>.stride, index: 2)
            let reduceTG = min(reducePipeline.maxTotalThreadsPerThreadgroup, reducePipeline.threadExecutionWidth * 4)
            let reduceThreadsPerThreadgroup = MTLSize(width: max(1, reduceTG), height: 1, depth: 1)
            let reduceThreads = MTLSize(width: cfg.bins, height: 1, depth: 1)
            reduceEnc.dispatchThreads(reduceThreads, threadsPerThreadgroup: reduceThreadsPerThreadgroup)
            reduceEnc.endEncoding()
        }
        cmd.commit()
        cmd.waitUntilCompleted()

        state.outputs = readArray(from: histogramBuffer!, count: cfg.bins)
        state.truncate(to: 0)
    }

    private func ensureParticleCapacity(_ count: Int) {
        let needsResize = count > particleCapacity
        let needsAlloc = (idsBuffer == nil)
            || (posXBuffer == nil)
            || (posYBuffer == nil)
            || (velXBuffer == nil)
            || (velYBuffer == nil)
            || (energyBuffer == nil)
            || (vBuffer == nil)
            || (projectedBinBuffer == nil)
            || (spikedBuffer == nil)
            || (aliveBuffer == nil)
            || (initialBinByIndexBuffer == nil)
            || (completionWrittenBuffer == nil)
            || (completionIDBuffer == nil)
            || (completionBinBuffer == nil)
            || (completionPosXBuffer == nil)
            || (completionPosYBuffer == nil)
            || (completionEnergyBuffer == nil)
            || (completionSpikedBuffer == nil)
            || (completionInitialBinBuffer == nil)

        guard needsResize || needsAlloc else { return }

        if needsResize {
            particleCapacity = max(count, particleCapacity * 2, 64)
        } else {
            particleCapacity = max(particleCapacity, count, 64)
        }

        idsBuffer = device.makeBuffer(length: particleCapacity * MemoryLayout<Int32>.stride, options: .storageModeShared)
        posXBuffer = device.makeBuffer(length: particleCapacity * MemoryLayout<Float>.stride, options: .storageModeShared)
        posYBuffer = device.makeBuffer(length: particleCapacity * MemoryLayout<Float>.stride, options: .storageModeShared)
        velXBuffer = device.makeBuffer(length: particleCapacity * MemoryLayout<Float>.stride, options: .storageModeShared)
        velYBuffer = device.makeBuffer(length: particleCapacity * MemoryLayout<Float>.stride, options: .storageModeShared)
        energyBuffer = device.makeBuffer(length: particleCapacity * MemoryLayout<Float>.stride, options: .storageModeShared)
        vBuffer = device.makeBuffer(length: particleCapacity * MemoryLayout<Float>.stride, options: .storageModeShared)
        projectedBinBuffer = device.makeBuffer(length: particleCapacity * MemoryLayout<Int32>.stride, options: .storageModeShared)
        spikedBuffer = device.makeBuffer(length: particleCapacity * MemoryLayout<UInt8>.stride, options: .storageModeShared)
        aliveBuffer = device.makeBuffer(length: particleCapacity * MemoryLayout<UInt8>.stride, options: .storageModeShared)

        // simulateWithCompletions
        initialBinByIndexBuffer = device.makeBuffer(length: particleCapacity * MemoryLayout<Int32>.stride, options: .storageModeShared)
        completionWrittenBuffer = device.makeBuffer(length: particleCapacity * MemoryLayout<UInt8>.stride, options: .storageModeShared)
        completionIDBuffer = device.makeBuffer(length: particleCapacity * MemoryLayout<Int32>.stride, options: .storageModeShared)
        completionBinBuffer = device.makeBuffer(length: particleCapacity * MemoryLayout<Int32>.stride, options: .storageModeShared)
        completionPosXBuffer = device.makeBuffer(length: particleCapacity * MemoryLayout<Float>.stride, options: .storageModeShared)
        completionPosYBuffer = device.makeBuffer(length: particleCapacity * MemoryLayout<Float>.stride, options: .storageModeShared)
        completionEnergyBuffer = device.makeBuffer(length: particleCapacity * MemoryLayout<Float>.stride, options: .storageModeShared)
        completionSpikedBuffer = device.makeBuffer(length: particleCapacity * MemoryLayout<UInt8>.stride, options: .storageModeShared)
        completionInitialBinBuffer = device.makeBuffer(length: particleCapacity * MemoryLayout<Int32>.stride, options: .storageModeShared)
    }

    private func ensureBinsCapacity(_ bins: Int) {
        let needsResize = bins > binsCapacity
        let needsAlloc = (histogramBuffer == nil)
            || (gainsBuffer == nil)
            || (targetsRawBuffer == nil)
            || (weightedSumBuffer == nil)
            || (weightSumBuffer == nil)
            || (weightedYHatBuffer == nil)
        guard needsResize || needsAlloc else { return }

        if needsResize {
            binsCapacity = max(bins, binsCapacity * 2, 64)
        } else {
            binsCapacity = max(binsCapacity, bins, 64)
        }

        histogramBuffer = device.makeBuffer(length: binsCapacity * MemoryLayout<Float>.stride, options: .storageModeShared)
        gainsBuffer = device.makeBuffer(length: binsCapacity * MemoryLayout<Float>.stride, options: .storageModeShared)

        // simulateWithCompletions weighted yHat
        targetsRawBuffer = device.makeBuffer(length: binsCapacity * MemoryLayout<Float>.stride, options: .storageModeShared)
        weightedSumBuffer = device.makeBuffer(length: binsCapacity * MemoryLayout<Float>.stride, options: .storageModeShared)
        weightSumBuffer = device.makeBuffer(length: binsCapacity * MemoryLayout<Float>.stride, options: .storageModeShared)
        weightedYHatBuffer = device.makeBuffer(length: binsCapacity * MemoryLayout<Float>.stride, options: .storageModeShared)
    }

    private func ensureGroupHistogramCapacity(groupCount: Int, bins: Int) {
        let desiredBins = max(bins, binsCapacity)
        if groupHistogramBuffer == nil
            || groupWeightedSumBuffer == nil
            || groupWeightSumBuffer == nil
            || groupCount > groupHistogramCapacityGroups
            || desiredBins > groupHistogramCapacityBins {
            groupHistogramCapacityGroups = max(groupCount, groupHistogramCapacityGroups * 2, 1)
            groupHistogramCapacityBins = max(desiredBins, groupHistogramCapacityBins * 2, 1)
            let length = groupHistogramCapacityGroups * groupHistogramCapacityBins * MemoryLayout<Float>.stride
            groupHistogramBuffer = device.makeBuffer(length: length, options: .storageModeShared)

            // weighted yHat uses the same group layout as groupHistogram
            groupWeightedSumBuffer = device.makeBuffer(length: length, options: .storageModeShared)
            groupWeightSumBuffer = device.makeBuffer(length: length, options: .storageModeShared)
        }
    }

    private func ensureGroupCounterCapacity(_ groupCount: Int) {
        let needsResize = groupCount > groupCounterCapacity
        let needsAlloc = (groupSpikeCountBuffer == nil)
            || (groupStepCountBuffer == nil)
            || (groupCompletionCountBuffer == nil)
            || (groupRadialMissSumBuffer == nil)
            || (groupBoundaryLossSumBuffer == nil)

        guard needsResize || needsAlloc else { return }

        if needsResize {
            groupCounterCapacity = max(groupCount, groupCounterCapacity * 2, 1)
        } else {
            groupCounterCapacity = max(groupCounterCapacity, groupCount, 1)
        }

        groupSpikeCountBuffer = device.makeBuffer(length: groupCounterCapacity * MemoryLayout<UInt32>.stride, options: .storageModeShared)
        groupStepCountBuffer = device.makeBuffer(length: groupCounterCapacity * MemoryLayout<UInt32>.stride, options: .storageModeShared)
        groupCompletionCountBuffer = device.makeBuffer(length: groupCounterCapacity * MemoryLayout<UInt32>.stride, options: .storageModeShared)
        groupRadialMissSumBuffer = device.makeBuffer(length: groupCounterCapacity * MemoryLayout<Float>.stride, options: .storageModeShared)
        groupBoundaryLossSumBuffer = device.makeBuffer(length: groupCounterCapacity * MemoryLayout<Float>.stride, options: .storageModeShared)
    }

    private func ensureScalarMetricBuffers() {
        if radialMissSumBuffer == nil {
            radialMissSumBuffer = device.makeBuffer(length: MemoryLayout<Float>.stride, options: .storageModeShared)
        }
        if boundaryLossSumBuffer == nil {
            boundaryLossSumBuffer = device.makeBuffer(length: MemoryLayout<Float>.stride, options: .storageModeShared)
        }
    }

    private func writeArray<T>(_ array: [T], to buffer: MTLBuffer, count: Int) {
        let length = count * MemoryLayout<T>.stride
        array.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            memcpy(buffer.contents(), base, length)
        }
    }
    private func clearBuffer(_ buffer: MTLBuffer, length: Int) {
        memset(buffer.contents(), 0, length)
    }

    private func fillBuffer(_ buffer: MTLBuffer, value: UInt8, length: Int) {
        memset(buffer.contents(), Int32(value), length)
    }

    private func readArray<T>(from buffer: MTLBuffer, count: Int) -> [T] {
        let ptr = buffer.contents().bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: ptr, count: count))
    }
}
