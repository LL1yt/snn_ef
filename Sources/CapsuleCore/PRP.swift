import Foundation
import CryptoKit
import SharedInfrastructure

public enum PRP {
    // Applies Feistel network over the payload (bytes after header), leaving header intact.
    public static func apply(inoutBytes bytes: inout [UInt8], config: ConfigRoot.Capsule) {
        let start = CapsuleHeader.byteCount
        guard bytes.count > start else { return }
        let key = deriveKey(fromHex: config.keyHex)

        let payloadLen = bytes.count - start
        if payloadLen <= 0 { return }
        let mid = payloadLen / 2
        var L = Array(bytes[start..<(start + mid)])
        var R = Array(bytes[(start + mid)..<bytes.count])

        let rounds = max(1, config.feistelRounds)
        for r in 0..<rounds {
            let f = prf(input: R, key: key, round: r)
            let newR = xor(L, f)
            L = R
            R = newR
        }

        // Write back (L,R)
        var out = [UInt8]()
        out.reserveCapacity(payloadLen)
        out.append(contentsOf: L)
        out.append(contentsOf: R)
        bytes.replaceSubrange(start..<bytes.count, with: out)
    }

    // Inverse Feistel over the payload; header remains intact.
    public static func inverse(inoutBytes bytes: inout [UInt8], config: ConfigRoot.Capsule) {
        let start = CapsuleHeader.byteCount
        guard bytes.count > start else { return }
        let key = deriveKey(fromHex: config.keyHex)

        let payloadLen = bytes.count - start
        if payloadLen <= 0 { return }
        let mid = payloadLen / 2
        var L = Array(bytes[start..<(start + mid)])
        var R = Array(bytes[(start + mid)..<bytes.count])

        let rounds = max(1, config.feistelRounds)
        for r in (0..<rounds).reversed() {
            let f = prf(input: L, key: key, round: r)
            let newL = xor(R, f)
            R = L
            L = newL
        }

        var out = [UInt8]()
        out.reserveCapacity(payloadLen)
        out.append(contentsOf: L)
        out.append(contentsOf: R)
        bytes.replaceSubrange(start..<bytes.count, with: out)
    }

    private static func xor(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        if a.isEmpty { return a }
        var out = [UInt8](repeating: 0, count: a.count)
        var i = 0
        while i < a.count {
            out[i] = a[i] ^ b[i % b.count]
            i += 1
        }
        return out
    }

    private static func prf(input: [UInt8], key: Data, round: Int) -> [UInt8] {
        // HMAC-SHA256 based stream expander producing |input| bytes
        let targetLen = max(1, input.count)
        var output = [UInt8]()
        output.reserveCapacity(targetLen)
        var counter: UInt32 = 0
        while output.count < targetLen {
            var ctx = Data()
            ctx.append(contentsOf: input)
            let rBE = withUnsafeBytes(of: UInt32(round).bigEndian, Array.init)
            ctx.append(contentsOf: rBE)
            let cBE = withUnsafeBytes(of: counter.bigEndian, Array.init)
            ctx.append(contentsOf: cBE)

            let mac = HMAC<SHA256>.authenticationCode(for: ctx, using: SymmetricKey(data: key))
            let chunk = Array(mac)
            let needed = min(chunk.count, targetLen - output.count)
            output.append(contentsOf: chunk.prefix(needed))
            counter &+= 1
        }
        return output
    }

    private static func deriveKey(fromHex hex: String) -> Data {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2, limitedBy: cleaned.endIndex) ?? cleaned.endIndex
            let byteStr = String(cleaned[index..<next])
            if let b = UInt8(byteStr, radix: 16) {
                bytes.append(b)
            }
            index = next
        }
        if bytes.isEmpty {
            // Fallback deterministic key if parsing failed
            return Data("default-feistel-key".utf8)
        }
        return Data(bytes)
    }
}
