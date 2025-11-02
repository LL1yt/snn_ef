import Foundation
import XCTest
@testable import SharedInfrastructure

final class LoggingHubTests: XCTestCase {
    private var tempDir: URL!
    private var logFileURL: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        tempDir = base
        logFileURL = tempDir.appendingPathComponent("test.log", isDirectory: false)
        LoggingHub.reset()
        ProcessRegistry.reset()
    }

    override func tearDownWithError() throws {
        LoggingHub.reset()
        if let tempDir {
            try? fileManager.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    func testLoggingWritesToFileDestination() throws {
        let snapshot = makeSnapshot(
            defaultLevel: .info,
            overrides: [:],
            destinations: [.file(path: logFileURL.path)]
        )
        ProcessRegistry.configure(from: snapshot)
        try LoggingHub.configure(from: snapshot, fileManager: fileManager)

        LoggingHub.emit(process: "capsule.encode", level: .info, message: "hello-world")
        LoggingHub.waitForDrain()

        let contents = try String(contentsOf: logFileURL)
        XCTAssertTrue(contents.contains("INFO"))
        XCTAssertTrue(contents.contains("capsule.encode"))
        XCTAssertTrue(contents.contains("hello-world"))
    }

    func testLoggingHonorsLevelOverrides() throws {
        let snapshot = makeSnapshot(
            defaultLevel: .info,
            overrides: ["capsule.encode": .debug],
            destinations: [.file(path: logFileURL.path)]
        )
        ProcessRegistry.configure(from: snapshot)
        try LoggingHub.configure(from: snapshot, fileManager: fileManager)

        LoggingHub.emit(process: "capsule.encode", level: .debug, message: "allowed-debug")
        LoggingHub.emit(process: "router.step", level: .debug, message: "filtered-debug")
        LoggingHub.waitForDrain()

        let contents = try String(contentsOf: logFileURL)
        XCTAssertTrue(contents.contains("allowed-debug"))
        XCTAssertFalse(contents.contains("filtered-debug"))
        XCTAssertNotNil(LoggingHub.lastEventTimestamp(for: "capsule.encode"))
        XCTAssertNil(LoggingHub.lastEventTimestamp(for: "router.step"))
    }

    func testLastEventTimestampRecordsLatest() throws {
        let snapshot = makeSnapshot(
            defaultLevel: .trace,
            overrides: [:],
            destinations: [.stdout]
        )
        ProcessRegistry.configure(from: snapshot)
        try LoggingHub.configure(from: snapshot, fileManager: fileManager)

        LoggingHub.emit(process: "capsule.encode", level: .info, message: "first")
        LoggingHub.waitForDrain()
        let first = LoggingHub.lastEventTimestamp(for: "capsule.encode")
        XCTAssertNotNil(first)

        Thread.sleep(forTimeInterval: 0.01)
        LoggingHub.emit(process: "capsule.encode", level: .info, message: "second")
        LoggingHub.waitForDrain()
        let second = LoggingHub.lastEventTimestamp(for: "capsule.encode")
        XCTAssertNotNil(second)
        if let first, let second {
            XCTAssertTrue(second >= first)
        }
    }

    // MARK: - Helpers

    private func makeSnapshot(
        defaultLevel: LogLevel,
        overrides: [String: LogLevel],
        destinations: [DestinationSpec]
    ) -> ConfigSnapshot {
        let loggingDestinations = destinations.map { spec -> ConfigRoot.Logging.Destination in
            switch spec {
            case .stdout:
                return .init(type: .stdout, path: nil)
            case let .file(path):
                return .init(type: .file, path: path)
            }
        }

        let logging = ConfigRoot.Logging(
            defaultLevel: defaultLevel,
            signposts: false,
            destinations: loggingDestinations,
            levelsOverride: overrides,
            timestampKind: .relative
        )

        let paths = ConfigRoot.Paths(
            logsDir: tempDir.path,
            checkpointsDir: tempDir.appendingPathComponent("ckpt").path,
            snapshotsDir: tempDir.appendingPathComponent("snap").path,
            pipelineSnapshot: tempDir.appendingPathComponent("pipeline.json").path
        )

        let alphabet = TestConstants.alphabet

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
            pipelineExampleText: "",
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
            pipelineSnapshotPath: tempDir.appendingPathComponent("pipeline.json").path,
            metricsPollMS: 100
        )

        let root = ConfigRoot(
            version: 1,
            profile: "test",
            seed: 1,
            logging: logging,
            processRegistry: [
                "capsule.encode": "capsule.encode",
                "router.step": "router.step"
            ],
            paths: paths,
            capsule: capsule,
            router: router,
            ui: ui
        )

        let sourceURL = tempDir.appendingPathComponent("config.yaml")
        return ConfigSnapshot(root: root, sourceURL: sourceURL)
    }

    private enum DestinationSpec {
        case stdout
        case file(path: String)
    }
}
