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
            layers: 1,
            nodesPerLayer: 4,
            snn: .init(
                parameterCount: 128,
                decay: 0.9,
                threshold: 0.8,
                resetValue: 0.0,
                deltaXRange: .init(min: 1, max: 1),
                deltaYRange: .init(min: -2, max: 2),
                surrogate: "fast_sigmoid",
                dt: 1
            ),
            alpha: 0.9,
            energyFloor: 1.0e-5,
            energyConstraints: .init(energyBase: alphabet.count),
            training: .init(
                optimizer: .init(type: "adam", lr: 1e-3, beta1: 0.9, beta2: 0.999, eps: 1e-8),
                losses: .init(energyBalanceWeight: 1.0, jumpPenaltyWeight: 1.0e-2, spikeRateTarget: 0.1)
            )
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
