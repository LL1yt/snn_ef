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
    var noiseStdPos: Float
    var noiseStdDir: Float
    var maxSpeed: Float
    var energyAlpha: Float
    var energyFloor: Float
    var finalWeightPower: Float
    var gainsCount: UInt32
    var threadsPerGroup: UInt32
    var groupCount: UInt32
}

final class FlowMetalContext {
    static var lastInitError: String?
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let stepPipeline: MTLComputePipelineState
    private let finalPipeline: MTLComputePipelineState
    private let reducePipeline: MTLComputePipelineState

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
              let finalFunction = library.makeFunction(name: "flow_project_final"),
              let reduceFunction = library.makeFunction(name: "flow_reduce_hist") else {
            FlowMetalContext.lastInitError = "Missing Metal functions flow_step/flow_project_final/flow_reduce_hist in library"
            return nil
        }
        do {
            self.stepPipeline = try device.makeComputePipelineState(function: stepFunction)
            self.finalPipeline = try device.makeComputePipelineState(function: finalFunction)
            self.reducePipeline = try device.makeComputePipelineState(function: reduceFunction)
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
            noiseStdPos: cfg.dynamics.noiseStdPos,
            noiseStdDir: cfg.dynamics.noiseStdDir,
            maxSpeed: cfg.dynamics.maxSpeed,
            energyAlpha: cfg.dynamics.energyAlpha,
            energyFloor: cfg.dynamics.energyFloor,
            finalWeightPower: cfg.finalWeightPower,
            gainsCount: gainsCount,
            threadsPerGroup: UInt32(threadsPerGroup),
            groupCount: UInt32(groupCount)
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

        for step in 0..<cfg.T {
            let params = FlowMetalParams(
                count: UInt32(count),
                bins: UInt32(cfg.bins),
                step: UInt32(step),
                baseSeed: baseSeed,
                radius: cfg.radius,
                lifDecay: cfg.lif.decay,
                lifThreshold: cfg.lif.threshold,
                lifReset: cfg.lif.resetValue,
                radialBias: cfg.dynamics.radialBias,
                spikeKick: cfg.dynamics.spikeKick,
                noiseStdPos: cfg.dynamics.noiseStdPos,
                noiseStdDir: cfg.dynamics.noiseStdDir,
                maxSpeed: cfg.dynamics.maxSpeed,
                energyAlpha: cfg.dynamics.energyAlpha,
                energyFloor: cfg.dynamics.energyFloor,
                finalWeightPower: cfg.finalWeightPower,
                gainsCount: gainsCount,
                threadsPerGroup: UInt32(stepThreadsPerGroup),
                groupCount: UInt32(stepGroupCount)
            )

            guard let cmd = queue.makeCommandBuffer(),
                  let enc = cmd.makeComputeCommandEncoder() else { break }
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

            let threadsPerThreadgroup = MTLSize(width: max(1, stepTG), height: 1, depth: 1)
            let threads = MTLSize(width: count, height: 1, depth: 1)
            enc.dispatchThreads(threads, threadsPerThreadgroup: threadsPerThreadgroup)
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
        }

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
            noiseStdPos: 0,
            noiseStdDir: 0,
            maxSpeed: 0,
            energyAlpha: 0,
            energyFloor: 0,
            finalWeightPower: cfg.finalWeightPower,
            gainsCount: gainsCount,
            threadsPerGroup: UInt32(finalThreadsPerGroup),
            groupCount: UInt32(finalGroupCount)
        )

        guard let finalCmd = queue.makeCommandBuffer(),
              let finalEnc = finalCmd.makeComputeCommandEncoder() else {
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
        if let reduceEnc = finalCmd.makeComputeCommandEncoder() {
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
        finalCmd.commit()
        finalCmd.waitUntilCompleted()

        let outputs: [Float] = readArray(from: histogramBuffer!, count: cfg.bins)
        LoggingHub.endSignpost("flow.run", token: token)
        return outputs
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
            noiseStdPos: 0,
            noiseStdDir: 0,
            maxSpeed: 0,
            energyAlpha: 0,
            energyFloor: 0,
            finalWeightPower: cfg.finalWeightPower,
            gainsCount: gainsCount,
            threadsPerGroup: UInt32(threadsPerGroup),
            groupCount: UInt32(groupCount)
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
        guard count > particleCapacity else { return }
        particleCapacity = max(count, particleCapacity * 2, 64)

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
    }

    private func ensureBinsCapacity(_ bins: Int) {
        guard bins > binsCapacity else { return }
        binsCapacity = max(bins, binsCapacity * 2, 64)
        histogramBuffer = device.makeBuffer(length: binsCapacity * MemoryLayout<Float>.stride, options: .storageModeShared)
        gainsBuffer = device.makeBuffer(length: binsCapacity * MemoryLayout<Float>.stride, options: .storageModeShared)
    }

    private func ensureGroupHistogramCapacity(groupCount: Int, bins: Int) {
        let desiredBins = max(bins, binsCapacity)
        if groupHistogramBuffer == nil
            || groupCount > groupHistogramCapacityGroups
            || desiredBins > groupHistogramCapacityBins {
            groupHistogramCapacityGroups = max(groupCount, groupHistogramCapacityGroups * 2, 1)
            groupHistogramCapacityBins = max(desiredBins, groupHistogramCapacityBins * 2, 1)
            let length = groupHistogramCapacityGroups * groupHistogramCapacityBins * MemoryLayout<Float>.stride
            groupHistogramBuffer = device.makeBuffer(length: length, options: .storageModeShared)
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
