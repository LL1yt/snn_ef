import Foundation

public struct LogiQASample: Sendable, Decodable {
    public let id: String
    public let split: String
    public let input_text: String
    public let answer_text: String
    public let wrong_answers: [String]
}

public enum LogiQADatasetLoader {
    public static func loadJSONL(from path: String, limit: Int = 0, shuffle: Bool = false, seed: UInt64 = 42) throws -> [LogiQASample] {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        var items: [LogiQASample] = []
        items.reserveCapacity(256)
        for line in text.split(separator: "\n") {
            if line.isEmpty { continue }
            if let record = try? decoder.decode(LogiQASample.self, from: Data(line.utf8)) {
                items.append(record)
            }
        }
        if shuffle {
            var rng = LCG(seed: seed)
            for i in stride(from: items.count - 1, through: 1, by: -1) {
                let j = rng.nextInt(upperBound: i + 1)
                if i != j { items.swapAt(i, j) }
            }
        }
        if limit > 0 && items.count > limit {
            items = Array(items.prefix(limit))
        }
        return items
    }

    private struct LCG {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1
            return state
        }
        mutating func nextInt(upperBound: Int) -> Int {
            return Int(next() % UInt64(upperBound))
        }
    }
}
