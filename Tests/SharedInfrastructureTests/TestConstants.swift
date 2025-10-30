enum TestConstants {
    static let alphabet: String = {
        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(256)
        for codePoint in 0x0100...0x01FF {
            guard let scalar = UnicodeScalar(codePoint) else { continue }
            scalars.append(scalar)
        }
        return String(String.UnicodeScalarView(scalars))
    }()
}
