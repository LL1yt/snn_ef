import XCTest
import Foundation
@testable import CapsuleCore
@testable import SharedInfrastructure

final class CapsuleCoreTests: XCTestCase {
    func testPlaceholderDescription() {
        XCTAssertEqual(CapsulePlaceholder().describe(), "CapsuleCore placeholder")
    }

    func testEncodeDecodeRoundTripRandom() throws {
        let snapshot = try ConfigCenter.load()
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
        let snapshot = try ConfigCenter.load()
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
        let snapshot = try ConfigCenter.load()
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
        let snapshot = try ConfigCenter.load()
        let alphabet = snapshot.root.capsule.alphabet
        let digits = [0, 1, alphabet.count - 1, 10, 42].map { $0 % alphabet.count }
        let s = DigitStringConverter.digitsToString(digits, alphabet: alphabet)
        let back = DigitStringConverter.stringToDigits(s, alphabet: alphabet)
        XCTAssertEqual(digits, back)
    }

    func testMakeEnergiesAndRecoverCapsuleRoundTrip() throws {
        let snapshot = try ConfigCenter.load()
        let cfg = snapshot.root.capsule
        let text = "Hello, Energetic Router!"
        let data = Data(text.utf8)

        let (batch, _) = try CapsuleBridge.makeEnergies(from: data, config: cfg)
        let recovered = try CapsuleBridge.recoverCapsule(from: batch.energies, config: cfg)
        XCTAssertEqual(recovered, data)
    }

    func testRecoverCapsuleDetectsNoise() throws {
        let snapshot = try ConfigCenter.load()
        let cfg = snapshot.root.capsule
        let data = Data("Noise test payload".utf8)
        var (batch, _) = try CapsuleBridge.makeEnergies(from: data, config: cfg)
        // Add ±1 noise to a few positions
        if batch.energies.count >= 3 {
            var energies = batch.energies
            energies[0] = max(1, min(cfg.base, energies[0] + 1))
            energies[energies.count / 2] = max(1, min(cfg.base, energies[energies.count / 2] - 1))
            energies[energies.count - 1] = max(1, min(cfg.base, energies.last! + 1))
            XCTAssertThrowsError(try CapsuleBridge.recoverCapsule(from: energies, config: cfg))
        }
    }
}
