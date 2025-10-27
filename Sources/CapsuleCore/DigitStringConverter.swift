import Foundation

public enum DigitStringConverter {
    public static func digitsToString(_ digits: [Int], alphabet: String) -> String {
        precondition(!alphabet.isEmpty)
        let chars = Array(alphabet)
        let base = chars.count
        var scalars: [Character] = []
        scalars.reserveCapacity(digits.count)
        for d in digits {
            precondition(d >= 0 && d < base, "digit out of range")
            scalars.append(chars[d])
        }
        return String(scalars)
    }

    public static func stringToDigits(_ string: String, alphabet: String) -> [Int] {
        let map: [Character: Int] = {
            var dict: [Character: Int] = [:]
            var i = 0
            for ch in alphabet { dict[ch] = i; i += 1 }
            return dict
        }()
        var out: [Int] = []
        out.reserveCapacity(string.count)
        for ch in string {
            guard let idx = map[ch] else { preconditionFailure("character not in alphabet: \(ch)") }
            out.append(idx)
        }
        return out
    }
}
