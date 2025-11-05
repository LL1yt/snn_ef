import Foundation
import XCTest
@testable import SharedInfrastructure

#if DEBUG
final class DiagnosticsTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        ProcessRegistry.reset()
    }

    func testFailForTestingThrowsWithCanonicalProcessID() throws {
        let alphabet = TestConstants.alphabet
        let paths = ConfigRoot.Paths(
            logsDir: "Logs",
            checkpointsDir: "Artifacts/Checkpoints",
            snapshotsDir: "Artifacts/Snapshots",
            pipelineSnapshot: "Artifacts/pipeline.json"
        )
        let logging = ConfigRoot.Logging(
            defaultLevel: .info,
            signposts: false,
            destinations: [.init(type: .stdout, path: nil)],
            levelsOverride: [:],
            timestampKind: .relative
        )
        let capsule = ConfigRoot.Capsule(
            enabled: true,
            maxInputBytes: 8,
            blockSize: 16,
            base: alphabet.count,
            alphabet: alphabet,
            prp: "feistel",
            feistelRounds: 2,
            keyHex: "00",
            normalization: "none",
            pipelineExampleText: "",
            crc: "crc32",
            gpuBatch: 64
        )
        let router = ConfigRoot.Router(
            backend: "flow",
            flow: .init(
                T: 2,
                radius: 5.0,
                seedLayout: "ring",
                seedRadius: 1.0,
                lif: .init(decay: 0.9, threshold: 0.8, resetValue: 0.0, surrogate: "fast_sigmoid"),
                dynamics: .init(
                    radialBias: 0.1,
                    noiseStdPos: 0.0,
                    noiseStdDir: 0.0,
                    maxSpeed: 1.0,
                    energyAlpha: 0.9,
                    energyFloor: 1.0e-5
                ),
                interactions: .init(enabled: false, type: "none", strength: 0.0),
                projection: .init(shape: "circle", bins: alphabet.count, binSmoothing: 0.0),
                learning: .init(
                    enabled: false,
                    epochs: 1,
                    stepsPerEpoch: 1,
                    targetSpikeRate: 0.15,
                    lr: .init(gain: 0.001, lif: 0.01, dynamics: 0.005),
                    weights: .init(spike: 0.1, boundary: 0.05),
                    bounds: .init(theta: [0.5, 1.0], radialBias: [0.0, 0.5], spikeKick: [0.0, 1.0], gain: [0.1, 2.0]),
                    aggregator: .init(sigmaR: 2.5, sigmaE: 10.0, alpha: 1.0, beta: 1.0, gamma: 0.5, tau: 1.0),
                    targets: .init(type: "capsule-digits", path: nil)
                )
            ),
            energyConstraints: .init(energyBase: alphabet.count)
        )
        let ui = ConfigRoot.UI(
            enabled: false,
            refreshHZ: 30,
            headlessOverride: true,
            showPipeline: false,
            showGraph: false,
            pipelineSnapshotPath: "Artifacts/pipeline.json",
            metricsPollMS: 100
        )
        let root = ConfigRoot(
            version: 1,
            profile: "test",
            seed: 1,
            logging: logging,
            processRegistry: ["capsule.encode": "capsule.encode"],
            paths: paths,
            capsule: capsule,
            router: router,
            ui: ui
        )
        ProcessRegistry.configure(from: ConfigSnapshot(root: root, sourceURL: URL(fileURLWithPath: "/tmp/config.yaml")))

        XCTAssertThrowsError(try Diagnostics.failForTesting("boom", processID: "capsule.encode")) { error in
            guard let diagError = error as? DiagnosticsTestError else {
                return XCTFail("Unexpected error type: \(error)")
            }
            XCTAssertEqual(diagError.message, "boom")
            XCTAssertEqual(diagError.processID, "capsule.encode")
        }
    }
}
#endif
