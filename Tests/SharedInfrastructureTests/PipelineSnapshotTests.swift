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
        XCTAssertEqual(loaded?.router.backend, snapshot.root.router.backend)
        XCTAssertEqual(loaded?.router.bins, snapshot.root.router.flow.projection.bins)
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
            backend: "flow",
            flow: .init(
                T: 3,
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
