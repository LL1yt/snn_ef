import Foundation

public enum ByteDigitsConverter {
    // Converts bytes (big-endian base-256 digits) to base-B digits (MSD-first) with fixed length.
    public static func toDigits(bytes: [UInt8], baseB: Int) -> [Int] {
        precondition(baseB >= 2)
        let nDigits = requiredDigitsCount(byteCount: bytes.count, baseB: baseB)
        let converted = convertBase(input: bytes.map { Int($0) }, fromBase: 256, toBase: baseB)
        // converted is MSD-first; pad with leading zeros to fixed length
        if converted.count >= nDigits { return converted.suffix(nDigits).map { $0 } }
        let padding = Array(repeating: 0, count: nDigits - converted.count)
        return padding + converted
    }

    // Converts base-B digits (MSD-first) back to exact byteCount bytes.
    public static func toBytes(digitsMSDFirst: [Int], baseB: Int, byteCount: Int) -> [UInt8] {
        precondition(baseB >= 2)
        let trimmed = dropLeadingZeros(digitsMSDFirst)
        let bytesInt = convertBase(input: trimmed, fromBase: baseB, toBase: 256)
        // bytesInt is MSD-first; pad with leading zeros to reach exact byteCount
        let padded: [Int]
        if bytesInt.count >= byteCount {
            padded = Array(bytesInt.suffix(byteCount))
        } else {
            padded = Array(repeating: 0, count: byteCount - bytesInt.count) + bytesInt
        }
        return padded.map { UInt8(truncatingIfNeeded: $0) }
    }

    public static func requiredDigitsCount(byteCount: Int, baseB: Int) -> Int {
        guard byteCount > 0 else { return 1 }
        // ceil(byteCount * log256 / logB)
        let x = Double(byteCount) * log(256.0) / log(Double(baseB))
        return Int(ceil(x))
    }

    // Generic base conversion using long division; input and output are MSD-first.
    private static func convertBase(input: [Int], fromBase: Int, toBase: Int) -> [Int] {
        var src = dropLeadingZeros(input)
        if src.isEmpty { return [0] }
        var out: [Int] = []
        while !(src.count == 1 && src[0] == 0) {
            var quotient: [Int] = []
            quotient.reserveCapacity(src.count)
            var rem = 0
            for v in src {
                let acc = rem * fromBase + v
                let q = acc / toBase
                rem = acc % toBase
                if !quotient.isEmpty || q != 0 { quotient.append(q) }
            }
            out.append(rem) // remainder is LSD
            src = quotient
            if src.isEmpty { src = [0] }
        }
        // out currently LSD-first; reverse to MSD-first
        if out.isEmpty { return [0] }
        return out.reversed()
    }

    private static func dropLeadingZeros(_ arr: [Int]) -> [Int] {
        var i = 0
        while i < arr.count && arr[i] == 0 { i += 1 }
        return i == 0 ? arr : Array(arr[i...])
    }
}
