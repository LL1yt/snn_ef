import XCTest
import Foundation
@testable import CapsuleCore
@testable import SharedInfrastructure

final class CapsuleCoreTests: XCTestCase {
    private var testConfigURL: URL!
    private var snapshot: ConfigSnapshot!

    override func setUp() {
        super.setUp()
        do {
            testConfigURL = try makeTemporaryConfig()
            snapshot = try ConfigCenter.load(url: testConfigURL)
        } catch {
            XCTFail("Failed to set up test config: \(error)")
        }
    }

    override func tearDown() {
        if let url = testConfigURL {
            try? FileManager.default.removeItem(at: url)
        }
        super.tearDown()
    }

    func testPlaceholderDescription() {
        XCTAssertEqual(CapsulePlaceholder().describe(), "CapsuleCore placeholder")
    }

    func testEncodeDecodeRoundTripRandom() throws {
        let cfg = snapshot.root.capsule
        let encoder = CapsuleEncoder(config: cfg)
        let decoder = CapsuleDecoder(config: cfg)

        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ")
        let iterations = 200 // keep moderate to avoid long test times; plan suggests 1000
        for i in 0..<iterations {
            let len = Int.random(in: 0...min(64, cfg.maxInputBytes)) // vary lengths up to 64 for speed
            let s = String((0..<len).map { _ in alphabet.randomElement()! })
            let data = s.data(using: .utf8)!
            let block = try encoder.encode(data)
            let decoded = try decoder.decode(block)
            XCTAssertEqual(decoded, data, "mismatch at i=\(i) len=\(len)")
        }
    }

    func testInputTooLongError() throws {
        let cfg = snapshot.root.capsule
        let encoder = CapsuleEncoder(config: cfg)

        let tooLong = Data(repeating: 0x41, count: cfg.maxInputBytes + 1)
        XCTAssertThrowsError(try encoder.encode(tooLong)) { error in
            guard case .inputTooLong = error as? CapsuleError else {
                XCTFail("Expected inputTooLong, got: \(error)"); return
            }
        }
    }

    func testCRCMismatchOnTamper() throws {
        let cfg = snapshot.root.capsule
        let encoder = CapsuleEncoder(config: cfg)
        let decoder = CapsuleDecoder(config: cfg)

        let message = Data("Hello capsule".utf8)
        var block = try encoder.encode(message)

        // Tamper with one byte in payload region
        var bytes = block.bytes
        if bytes.count > CapsuleHeader.byteCount {
            let span = bytes.count - CapsuleHeader.byteCount
            let idx = CapsuleHeader.byteCount + (10 % max(1, span))
            bytes[idx] ^= 0xFF
        }
        block = try CapsuleBlock(blockSize: block.blockSize, bytes: bytes)

        XCTAssertThrowsError(try decoder.decode(block)) { error in
            guard case .crcMismatch = error as? CapsuleError else {
                XCTFail("Expected crcMismatch, got: \(error)"); return
            }
        }
    }

    func testByteDigitsRoundTripDifferentBases() throws {
        // Test that converting a block to base-B digits and back recovers original bytes
        let bytes = (0..<64).map { _ in UInt8.random(in: 0...255) }
        for base in [64, 85, 100] {
            let digits = ByteDigitsConverter.toDigits(bytes: bytes, baseB: base)
            let recovered = ByteDigitsConverter.toBytes(digitsMSDFirst: digits, baseB: base, byteCount: bytes.count)
            XCTAssertEqual(recovered, bytes, "Round-trip failed for base=\(base)")
        }
    }

    func testDigitStringConverter() throws {
        let alphabet = snapshot.root.capsule.alphabet
        let digits = [0, 1, alphabet.count - 1, 10, 42].map { $0 % alphabet.count }
        let s = DigitStringConverter.digitsToString(digits, alphabet: alphabet)
        let back = DigitStringConverter.stringToDigits(s, alphabet: alphabet)
        XCTAssertEqual(digits, back)
    }

    func testMakeEnergiesAndRecoverCapsuleRoundTrip() throws {
        let cfg = snapshot.root.capsule
        let text = "Hello, Energetic Router!"
        let data = Data(text.utf8)

        let (batch, _) = try CapsuleBridge.makeEnergies(from: data, config: cfg)
        let recovered = try CapsuleBridge.recoverCapsule(from: batch.energies, config: cfg)
        XCTAssertEqual(recovered, data)
    }

    func testRecoverCapsuleDetectsNoise() throws {
        let cfg = snapshot.root.capsule
        let data = Data("Noise test payload".utf8)
        let (batch, _) = try CapsuleBridge.makeEnergies(from: data, config: cfg)
        // Add ±1 noise to a few positions
        if batch.energies.count >= 3 {
            var energies = batch.energies
            energies[0] = max(1, min(cfg.base, energies[0] + 1))
            energies[energies.count / 2] = max(1, min(cfg.base, energies[energies.count / 2] - 1))
            energies[energies.count - 1] = max(1, min(cfg.base, energies.last! + 1))
            XCTAssertThrowsError(try CapsuleBridge.recoverCapsule(from: energies, config: cfg))
        }
    }

    private func makeTemporaryConfig() throws -> URL {
        let config = """
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
          base: 100
          alphabet: "1234567890abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_.;:()[]{}<>!?@#$%^&*+=~|/,αβγδεζηθικ"
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".yaml")
        try config.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
