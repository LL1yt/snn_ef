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
        let alphabet = TestConstants.alphabet

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
          router.step: "router.step"
          router.spike: "router.spike"
          router.output: "router.output"
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
          base: 256
          alphabet: "\(alphabet)"
          prp: "feistel"
          feistel_rounds: 10
          key_hex: "000102030405"
          normalization: "none"
          pipeline_example_text: "hello capsule"
          crc: "crc32"
          gpu_batch: 128
        router:
          backend: "flow"
          flow:
            T: 3
            radius: 5.0
            seed_layout: "ring"
            seed_radius: 1.0
            lif:
              decay: 0.9
              threshold: 0.7
              reset_value: 0.0
              surrogate: "fast_sigmoid"
            dynamics:
              radial_bias: 0.1
              noise_std_pos: 0.0
              noise_std_dir: 0.0
              max_speed: 1.0
              energy_alpha: 0.9
              energy_floor: 1.0e-5
            interactions:
              enabled: false
              type: "none"
              strength: 0.0
            projection:
              shape: "circle"
              bins: 256
              bin_smoothing: 0.0
            learning:
              enabled: false
              epochs: 1
              steps_per_epoch: 1
              target_spike_rate: 0.15
              lr:
                gain: 0.001
                lif: 0.01
                dynamics: 0.005
              weights:
                spike: 0.1
                boundary: 0.05
              bounds:
                theta: [0.5, 1.0]
                radial_bias: [0.0, 0.5]
                spike_kick: [0.0, 1.0]
                gain: [0.1, 2.0]
              aggregator:
                sigma_r: 2.5
                sigma_e: 10.0
                alpha: 1.0
                beta: 1.0
                gamma: 0.5
                tau: 1.0
              targets:
                type: "capsule-digits"
                path: null
          energy_constraints:
            energy_base: 256
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
