import Foundation

// MARK: - Checkpoint Manager

/// Manages saving and loading of learning checkpoints
public enum CheckpointManager {
    /// Saves a learning checkpoint to disk
    public static func save(
        state: RouterLearningState,
        to directory: URL,
        filename: String? = nil
    ) throws {
        let fm = FileManager.default

        // Ensure directory exists
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        // Generate filename if not provided
        let name = filename ?? "learning_epoch_\(String(format: "%04d", state.epoch)).json"
        let fileURL = directory.appendingPathComponent(name)

        // Encode to JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(state)
        try data.write(to: fileURL)
    }

    /// Loads a learning checkpoint from disk
    public static func load(from url: URL) throws -> RouterLearningState {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RouterLearningState.self, from: data)
    }

    /// Finds the latest checkpoint in a directory
    public static func findLatestCheckpoint(in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey]) else {
            return nil
        }

        let checkpoints = files.filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("learning_epoch_") }
        guard !checkpoints.isEmpty else { return nil }

        // Sort by creation date descending
        let sorted = checkpoints.sorted { url1, url2 in
            let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
            let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
            return date1 > date2
        }

        return sorted.first
    }

    /// Saves a snapshot summary for all epochs
    public static func saveSummary(
        metrics: [LearningMetrics],
        to directory: URL,
        filename: String = "learning_summary.json"
    ) throws {
        let fm = FileManager.default

        // Ensure directory exists
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let fileURL = directory.appendingPathComponent(filename)

        // Encode to JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(metrics)
        try data.write(to: fileURL)
    }
}

// MARK: - Target Loader

/// Loads target bin distributions from various sources
public enum TargetLoader {
    /// Creates target from capsule energies (digits + 1)
    public static func fromCapsuleDigits(energies: [Float], bins: Int) -> [Float] {
        var targets = [Float](repeating: 0, count: bins)

        // Distribute energies across bins based on their values
        // Simple strategy: energy E maps to bin floor(E) % bins, contributing E
        for energy in energies {
            let binIdx = Int(floor(energy)) % bins
            targets[binIdx] += energy
        }

        return targets
    }

    /// Loads target from a JSON file: array of floats [T[0], T[1], ..., T[B-1]]
    public static func fromJSONFile(path: String, bins: Int) throws -> [Float] {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let values = try decoder.decode([Float].self, from: data)

        guard values.count == bins else {
            throw TargetLoaderError.binCountMismatch(expected: bins, actual: values.count)
        }

        return values
    }

    /// Loads target from a CSV file: one value per line
    public static func fromCSVFile(path: String, bins: Int) throws -> [Float] {
        let url = URL(fileURLWithPath: path)
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }

        guard lines.count == bins else {
            throw TargetLoaderError.binCountMismatch(expected: bins, actual: lines.count)
        }

        var targets: [Float] = []
        for (idx, line) in lines.enumerated() {
            guard let value = Float(line.trimmingCharacters(in: .whitespaces)) else {
                throw TargetLoaderError.parseError(line: idx, content: line)
            }
            targets.append(value)
        }

        return targets
    }

    public enum TargetLoaderError: LocalizedError {
        case binCountMismatch(expected: Int, actual: Int)
        case parseError(line: Int, content: String)

        public var errorDescription: String? {
            switch self {
            case let .binCountMismatch(expected, actual):
                return "Target bin count mismatch: expected \(expected), got \(actual)"
            case let .parseError(line, content):
                return "Failed to parse line \(line): \(content)"
            }
        }
    }
}
