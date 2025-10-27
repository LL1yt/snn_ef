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
        try LoggingHub.configure(from: snapshot, fileManager: fileManager)

        LoggingHub.emit(LogEvent(processID: "capsule.encode", level: .info, message: "hello-world"))
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
        try LoggingHub.configure(from: snapshot, fileManager: fileManager)

        LoggingHub.emit(LogEvent(processID: "capsule.encode", level: .debug, message: "allowed-debug"))
        LoggingHub.emit(LogEvent(processID: "router.forward", level: .debug, message: "filtered-debug"))
        LoggingHub.waitForDrain()

        let contents = try String(contentsOf: logFileURL)
        XCTAssertTrue(contents.contains("allowed-debug"))
        XCTAssertFalse(contents.contains("filtered-debug"))
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

        let alphabet = "1234567890abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_.;:()[]{}<>!?@#$%^&*+=~|/\\'\"αβγδεζηθ"

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
            prototypes: .init(count: 2, hiddenDim: 4),
            neighbors: .init(local: 2, jump: 1),
            alpha: 0.9,
            tau: 1.0,
            topK: 2,
            energyConstraints: .init(maxDX: 10, minDX: 1, maxDY: 10, energyBase: alphabet.count),
            optimizer: .init(type: "adam", lr: 1e-3, beta1: 0.9, beta2: 0.999, eps: 1e-8),
            entropyReg: 0.01,
            batchSize: 8,
            epochs: 1,
            backend: "cpu",
            task: "test",
            headless: true,
            checkpoints: .init(everySteps: 10, keep: 2),
            localLearning: .init(enabled: false, rho: 0.9, lr: 0.0, baselineBeta: 0.95)
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
                "router.forward": "router.forward"
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
