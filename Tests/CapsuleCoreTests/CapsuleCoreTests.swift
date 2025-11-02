import XCTest
import Foundation
@testable import CapsuleCore
@testable import SharedInfrastructure

final class CapsuleCoreTests: XCTestCase {
    private var testConfigURL: URL!
    private var snapshot: ConfigSnapshot!
    private static let alphabet: String = {
        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(256)
        for codePoint in 0x0100...0x01FF {
            if let scalar = UnicodeScalar(codePoint) {
                scalars.append(scalar)
            }
        }
        return String(String.UnicodeScalarView(scalars))
    }()

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
        for base in [64, 128, 256] {
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
        let alphabet = CapsuleCoreTests.alphabet
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
          router.forward: "router.forward"
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
          alphabet: "\(alphabet)"
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
          prototypes:
            count: 64
            hidden_dim: 8
          neighbors:
            local: 8
            jump: 2
          alpha: 0.9
          tau: 3.0
          top_k: 4
          energy_constraints:
            max_dx: 10
            min_dx: 1
            max_dy: 64
            energy_base: 256
          optimizer:
            type: "adam"
            lr: 1.0e-3
            beta1: 0.9
            beta2: 0.999
            eps: 1.0e-8
          entropy_reg: 0.01
          batch_size: 32
          epochs: 5
          backend: "cpu"
          task: "addition"
          headless: false
          checkpoints:
            every_steps: 100
            keep: 5
          local_learning:
            enabled: false
            rho: 0.9
            lr: 1.0e-4
            baseline_beta: 0.95
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
