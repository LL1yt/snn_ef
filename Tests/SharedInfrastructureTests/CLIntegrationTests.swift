import Foundation
import XCTest

final class CLIntegrationTests: XCTestCase {
    func testCapsuleCLIProducesHint() throws {
        let configURL = try makeTemporaryConfig()
        let output = try runCLI(named: "capsule-cli", configURL: configURL)
        XCTAssertTrue(output.contains("Profile:"))
        XCTAssertTrue(output.contains("UI:"))
    }

    func testEnergeticCLIProducesHint() throws {
        let configURL = try makeTemporaryConfig()
        let output = try runCLI(named: "energetic-cli", configURL: configURL)
        XCTAssertTrue(output.contains("Router backend"))
    }

    // MARK: - Helpers

    private func makeTemporaryConfig() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let config = CLIntegrationTests.sampleConfig(replacingPathsWith: tempDir)
        let url = tempDir.appendingPathComponent("config.yaml")
        try config.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempDir)
        }
        return url
    }

    private func runCLI(named executableName: String, configURL: URL) throws -> String {
        let executableURL = CLIntegrationTests.executableURL(for: executableName)
        if !FileManager.default.fileExists(atPath: executableURL.path) {
            throw XCTSkip("Executable not found at \(executableURL.path). Build the target before running tests.")
        }

        let process = Process()
        process.executableURL = executableURL
        process.environment = ProcessInfo.processInfo.environment.merging(["SNN_CONFIG_PATH": configURL.path]) { _, new in new }
        process.currentDirectoryURL = CLIntegrationTests.packageRoot

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let stderrMessage = String(data: stderrData, encoding: .utf8) ?? ""
            XCTFail("\(executableName) exited with status \(process.terminationStatus). stderr: \(stderrMessage)")
        }

        return String(data: stdoutData, encoding: .utf8) ?? ""
    }

    private static func executableURL(for name: String) -> URL {
        #if DEBUG
        let buildConfig = "debug"
        #else
        let buildConfig = "release"
        #endif
        return packageRoot.appendingPathComponent(".build").appendingPathComponent(buildConfig).appendingPathComponent(name)
    }

    private static let packageRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "Tests" {
            url.deleteLastPathComponent()
        }
        url.deleteLastPathComponent()
        return url
    }()

    private static func sampleConfig(replacingPathsWith base: URL) -> String {
        let logsDir = base.appendingPathComponent("Logs").path
        let checkpointsDir = base.appendingPathComponent("Artifacts/Checkpoints").path
        let snapshotsDir = base.appendingPathComponent("Artifacts/Snapshots").path
        let pipelineSnapshot = base.appendingPathComponent("Artifacts/pipeline.json").path
        let alphabet = "1234567890abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_.;:()[]{}<>!?@#$%^&*+=~|/,αβγδεζηθικ"

        return """
        version: 1
        profile: "integration"
        seed: 1
        logging:
          default_level: "info"
          signposts: false
          destinations:
            - type: "stdout"
          levels_override:
            capsule.encode: "debug"
          timestamp_kind: "relative"
        process_registry:
          capsule.encode: "capsule.encode"
          router.forward: "router.forward"
          cli.main: "cli.main"
        paths:
          logs_dir: "\(logsDir)"
          checkpoints_dir: "\(checkpointsDir)"
          snapshots_dir: "\(snapshotsDir)"
          pipeline_snapshot: "\(pipelineSnapshot)"
        capsule:
          enabled: true
          max_input_bytes: 16
          block_size: 48
          base: 100
          alphabet: "\(alphabet)"
          prp: "feistel"
          feistel_rounds: 10
          key_hex: "000102030405"
          normalization: "none"
          pipeline_example_text: "hello capsule"
          crc: "crc32"
          gpu_batch: 128
        router:
          layers: 4
          nodes_per_layer: 64
          prototypes:
            count: 8
            hidden_dim: 8
          neighbors:
            local: 8
            jump: 2
          alpha: 0.9
          tau: 2.0
          top_k: 4
          energy_constraints:
            max_dx: 10
            min_dx: 1
            max_dy: 32
            energy_base: 100
          optimizer:
            type: "adam"
            lr: 1.0e-3
            beta1: 0.9
            beta2: 0.999
            eps: 1.0e-8
          entropy_reg: 0.01
          batch_size: 32
          epochs: 1
          backend: "cpu"
          task: "integration"
          headless: false
          checkpoints:
            every_steps: 100
            keep: 2
          local_learning:
            enabled: false
            rho: 0.9
            lr: 0.0
            baseline_beta: 0.95
        ui:
          enabled: true
          refresh_hz: 30
          headless_override: false
          show_pipeline: true
          show_graph: true
          pipeline_snapshot_path: "\(pipelineSnapshot)"
          metrics_poll_ms: 200
        """
    }
}
