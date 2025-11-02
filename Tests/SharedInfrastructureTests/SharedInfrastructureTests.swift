import Foundation
import XCTest
@testable import SharedInfrastructure

final class SharedInfrastructureTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ProcessRegistry.reset()
    }

    func testProcessRegistryResolvesKnownID() throws {
        XCTAssertEqual(try ProcessRegistry.resolve("capsule.encode"), "capsule.encode")
    }

    func testProcessRegistryConfigureMergesAliases() throws {
        let config = Self.validConfig.replacingOccurrences(
            of: "  router.step: \"router.step\"",
            with: "  router.step: \"router.step\"\n  custom.alias: \"custom.canonical\""
        )
        let url = try makeTemporaryConfig(contents: config)
        let snapshot = try ConfigCenter.load(url: url)
        ProcessRegistry.configure(from: snapshot)

        XCTAssertEqual(try ProcessRegistry.resolve("custom.alias"), "custom.canonical")
    }

    func testProcessRegistryThrowsOnUnknownAlias() {
        XCTAssertThrowsError(try ProcessRegistry.resolve("unknown.alias")) { error in
            XCTAssertEqual(error as? ProcessRegistryError, .unknownAlias("unknown.alias"))
        }
    }

    func testConfigCenterLoadsBaselineConfig() throws {
        let url = try makeTemporaryConfig(contents: Self.validConfig)
        let snapshot = try ConfigCenter.load(url: url)

        XCTAssertEqual(snapshot.root.profile, "baseline")
        XCTAssertEqual(snapshot.root.capsule.base, 256)
        XCTAssertEqual(snapshot.root.router.energyConstraints.energyBase, 256)
        XCTAssertEqual(snapshot.root.logging.defaultLevel, LogLevel.info)
    }

    func testConfigCenterThrowsOnEnergyBaseMismatch() throws {
        let url = try makeTemporaryConfig(contents: Self.invalidEnergyConfig)
        XCTAssertThrowsError(try ConfigCenter.load(url: url)) { error in
            guard case let ConfigError.energyBaseMismatch(capsule, router) = error else {
                XCTFail("Expected energyBaseMismatch, got \(error)")
                return
            }
            XCTAssertEqual(capsule, 256)
            XCTAssertEqual(router, 257)
        }
    }

    func testConfigCenterThrowsOnUnknownLoggingOverride() throws {
        let url = try makeTemporaryConfig(contents: Self.invalidOverrideConfig)
        XCTAssertThrowsError(try ConfigCenter.load(url: url)) { error in
            guard case let ConfigError.overrideForUnknownProcess(key) = error else {
                XCTFail("Expected overrideForUnknownProcess, got \(error)")
                return
            }
            XCTAssertEqual(key, "unknown.process")
        }
    }

    private func makeTemporaryConfig(contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".yaml")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static let validConfig = """
    version: 1
    profile: "baseline"
    seed: 42
    logging:
      default_level: "info"
      signposts: true
      destinations:
        - type: "stdout"
      levels_override:
        capsule.encode: "debug"
        router.spike: "trace"
      timestamp_kind: "relative"
    process_registry:
      capsule.encode: "capsule.encode"
      router.step: "router.step"
      router.spike: "router.spike"
      router.output: "router.output"
    paths:
      logs_dir: "Logs"
      checkpoints_dir: "Artifacts/Checkpoints"
      snapshots_dir: "Artifacts/Snapshots"
      pipeline_snapshot: "Artifacts/pipeline_snapshot.json"
    capsule:
      enabled: true
      max_input_bytes: 256
      block_size: 320
      base: 256
      alphabet: "\(TestConstants.alphabet)"
      prp: "feistel"
      feistel_rounds: 10
      key_hex: "00"
      normalization: "e_over_bplus1"
      pipeline_example_text: ""
      crc: "crc32"
      gpu_batch: 512
    router:
      layers: 10
      nodes_per_layer: 1024
      snn:
        parameter_count: 512
        decay: 0.92
        threshold: 0.8
        reset_value: 0.0
        delta_x_range: [1, 4]
        delta_y_range: [-128, 128]
        surrogate: "fast_sigmoid"
        dt: 1
      alpha: 0.9
      energy_floor: 1.0e-5
      energy_constraints:
        energy_base: 100
      training:
        optimizer:
          type: "adam"
          lr: 1.0e-3
          beta1: 0.9
          beta2: 0.999
          eps: 1.0e-8
        losses:
          energy_balance_weight: 1.0
          jump_penalty_weight: 1.0e-2
          spike_rate_target: 0.1
    ui:
      enabled: true
      refresh_hz: 30
      headless_override: false
      show_pipeline: true
      show_graph: true
      pipeline_snapshot_path: "Artifacts/pipeline_snapshot.json"
      metrics_poll_ms: 200
    """

    private static let invalidEnergyConfig: String = {
        var lines = validConfig.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: { $0.contains("energy_base") }) {
            lines[index] = "        energy_base: 257"
        }
        return lines.joined(separator: "\n")
    }()

    private static let invalidOverrideConfig: String = {
        let nl = "\n"
        var lines = validConfig.components(separatedBy: nl)
        if let idx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "levels_override:" }) {
            let indentCount = lines[idx].prefix { $0 == " " }.count
            let childIndent = String(repeating: " ", count: indentCount + 2)
            lines.insert(childIndent + "unknown.process: \"debug\"", at: idx + 1)
        }
        return lines.joined(separator: nl)
    }()
}
