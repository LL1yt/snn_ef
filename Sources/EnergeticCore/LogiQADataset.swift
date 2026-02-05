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
        return try loadJSONL(from: [path], limit: limit, shuffle: shuffle, seed: seed)
    }

    public static func loadJSONL(from paths: [String], limit: Int = 0, shuffle: Bool = false, seed: UInt64 = 42) throws -> [LogiQASample] {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let decoder = JSONDecoder()

        // Fast paths
        if !shuffle {
            var items: [LogiQASample] = []
            items.reserveCapacity(limit > 0 ? limit : 256)
            do {
                try forEachJSONLLine(urls: urls) { lineData in
                    if let record = try? decoder.decode(LogiQASample.self, from: lineData) {
                        items.append(record)
                    }
                    if limit > 0 && items.count >= limit {
                        throw StopIteration()
                    }
                }
            } catch is StopIteration {
                // Expected early stop.
            }
            return items
        }

        // shuffle == true
        var rng = LCG(seed: seed)
        if limit > 0 {
            // Reservoir sample `limit` items without holding the full dataset in memory.
            var reservoir: [LogiQASample] = []
            reservoir.reserveCapacity(limit)
            var seen = 0

            try forEachJSONLLine(urls: urls) { lineData in
                if let record = try? decoder.decode(LogiQASample.self, from: lineData) {
                    if reservoir.count < limit {
                        reservoir.append(record)
                    } else {
                        let j = rng.nextInt(upperBound: seen + 1)
                        if j < limit {
                            reservoir[j] = record
                        }
                    }
                    seen += 1
                }
            }

            // Match previous semantics: shuffle then prefix.
            if reservoir.count > 1 {
                for i in stride(from: reservoir.count - 1, through: 1, by: -1) {
                    let j = rng.nextInt(upperBound: i + 1)
                    if i != j { reservoir.swapAt(i, j) }
                }
            }
            return reservoir
        } else {
            // Need full shuffle.
            var items: [LogiQASample] = []
            items.reserveCapacity(256)
            try forEachJSONLLine(urls: urls) { lineData in
                if let record = try? decoder.decode(LogiQASample.self, from: lineData) {
                    items.append(record)
                }
            }
            if items.count > 1 {
                for i in stride(from: items.count - 1, through: 1, by: -1) {
                    let j = rng.nextInt(upperBound: i + 1)
                    if i != j { items.swapAt(i, j) }
                }
            }
            return items
        }
    }

    private struct StopIteration: Error {}

    private static func forEachJSONLLine(urls: [URL], _ body: (Data) throws -> Void) throws {
        for url in urls {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            var buffer = Data()
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                buffer.append(chunk)

                while let nl = buffer.firstIndex(of: 0x0A) {
                    let lineSlice = buffer[..<nl]
                    buffer.removeSubrange(..<buffer.index(after: nl))

                    var line = Data(lineSlice)
                    if line.last == 0x0D { line.removeLast() } // handle CRLF
                    if line.isEmpty { continue }

                    do {
                        try body(line)
                    } catch is StopIteration {
                        throw StopIteration()
                    }
                }
            }

            if !buffer.isEmpty {
                var line = buffer
                if line.last == 0x0D { line.removeLast() }
                if !line.isEmpty {
                    do {
                        try body(line)
                    } catch is StopIteration {
                        throw StopIteration()
                    }
                }
            }
        }
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
