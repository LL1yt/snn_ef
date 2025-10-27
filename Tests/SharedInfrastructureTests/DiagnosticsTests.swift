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
        let alphabet = "1234567890abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_.;:()[]{}<>!?@#$%^&*+=~|/,αβγδεζηθικ"
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
            layers: 1,
            nodesPerLayer: 4,
            prototypes: .init(count: 2, hiddenDim: 4),
            neighbors: .init(local: 2, jump: 1),
            alpha: 0.9,
            tau: 1.0,
            topK: 2,
            energyConstraints: .init(maxDX: 10, minDX: 1, maxDY: 10, energyBase: alphabet.count),
            optimizer: .init(type: "adam", lr: 1e-3, beta1: 0.9, beta2: 0.999, eps: 1e-8),
            entropyReg: 0.01,
            batchSize: 4,
            epochs: 1,
            backend: "cpu",
            task: "test",
            headless: true,
            checkpoints: .init(everySteps: 10, keep: 1),
            localLearning: .init(enabled: false, rho: 0.9, lr: 0.0, baselineBeta: 0.95)
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
