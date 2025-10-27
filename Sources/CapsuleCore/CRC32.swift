import Foundation

public enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    public static func compute(_ bytes: [UInt8], seed: UInt32 = 0xFFFF_FFFF) -> UInt32 {
        var c = seed ^ 0xFFFF_FFFF
        for b in bytes {
            let idx = Int((c ^ UInt32(b)) & 0xFF)
            c = table[idx] ^ (c >> 8)
        }
        return c ^ 0xFFFF_FFFF
    }
}
