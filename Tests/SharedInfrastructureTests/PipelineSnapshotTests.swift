import Foundation
import XCTest
@testable import SharedInfrastructure

final class PipelineSnapshotTests: XCTestCase {
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        LoggingHub.reset()
        ProcessRegistry.reset()
    }

    override func tearDownWithError() throws {
        LoggingHub.reset()
        ProcessRegistry.reset()
        try super.tearDownWithError()
    }

    func testExportAndLoad() throws {
        let baseDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? self.fm.removeItem(at: baseDir)
        }

        let snapshot = makeSnapshot(baseDir: baseDir)
        ProcessRegistry.configure(from: snapshot)
        try LoggingHub.configure(from: snapshot, fileManager: fm)

        LoggingHub.emit(process: "capsule.encode", level: .info, message: "capsule event")
        LoggingHub.emit(process: "router.step", level: .info, message: "router event")
        LoggingHub.waitForDrain()

        let exported: ConfigPipelineSnapshot = try PipelineSnapshotExporter.export(snapshot: snapshot, fileManager: fm)
        XCTAssertEqual(exported.profile, snapshot.root.profile)
        XCTAssertEqual(exported.capsule.base, snapshot.root.capsule.base)

        let loaded: ConfigPipelineSnapshot? = PipelineSnapshotExporter.load(from: snapshot.root, fileManager: fm)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.router.layers, snapshot.root.router.layers)
        XCTAssertFalse(loaded?.lastEvents.isEmpty ?? true)
    }

    private func makeSnapshot(baseDir: URL) -> ConfigSnapshot {
        let alphabet = TestConstants.alphabet
        let logging = ConfigRoot.Logging(
            defaultLevel: .info,
            signposts: false,
            destinations: [.init(type: .stdout, path: nil)],
            levelsOverride: [:],
            timestampKind: .relative
        )
        let paths = ConfigRoot.Paths(
            logsDir: baseDir.appendingPathComponent("Logs").path,
            checkpointsDir: baseDir.appendingPathComponent("Artifacts/Checkpoints").path,
            snapshotsDir: baseDir.appendingPathComponent("Artifacts/Snapshots").path,
            pipelineSnapshot: baseDir.appendingPathComponent("Artifacts/pipeline.json").path
        )
        let capsule = ConfigRoot.Capsule(
            enabled: true,
            maxInputBytes: 8,
            blockSize: 32,
            base: alphabet.count,
            alphabet: alphabet,
            prp: "feistel",
            feistelRounds: 2,
            keyHex: "000102",
            normalization: "none",
            pipelineExampleText: "capsule",
            crc: "crc32",
            gpuBatch: 16
        )
        let router = ConfigRoot.Router(
            layers: 2,
            nodesPerLayer: 4,
            snn: .init(
                parameterCount: 256,
                decay: 0.9,
                threshold: 0.8,
                resetValue: 0.0,
                deltaXRange: .init(min: 1, max: 2),
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
            pipelineSnapshotPath: paths.pipelineSnapshot,
            metricsPollMS: 100
        )
        let root = ConfigRoot(
            version: 1,
            profile: "snapshot-test",
            seed: 1,
            logging: logging,
            processRegistry: [
                "capsule.encode": "capsule.encode",
                "router.step": "router.step",
                "cli.main": "cli.main"
            ],
            paths: paths,
            capsule: capsule,
            router: router,
            ui: ui
        )
        return ConfigSnapshot(root: root, sourceURL: baseDir.appendingPathComponent("config.yaml"))
    }
}
