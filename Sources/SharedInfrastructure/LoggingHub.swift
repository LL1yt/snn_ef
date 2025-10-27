import Foundation

public enum LogLevel: String, Sendable, Decodable {
    case trace, debug, info, warn, error

    var priority: Int {
        switch self {
        case .trace: return 0
        case .debug: return 1
        case .info: return 2
        case .warn: return 3
        case .error: return 4
        }
    }
}

public struct LogEvent: Sendable {
    public let timestamp: Date
    public let processID: String
    public let level: LogLevel
    public let message: String

    public init(timestamp: Date = .init(), processID: String, level: LogLevel, message: String) {
        self.timestamp = timestamp
        self.processID = processID
        self.level = level
        self.message = message
    }
}

public enum LoggingHub {
    private static let queue = DispatchQueue(label: "LoggingHub.queue")
    private static var state = State()
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public static func configure(from snapshot: ConfigSnapshot, fileManager: FileManager = .default) throws {
        var thrownError: Error?
        queue.sync {
            do {
                try reconfigure(snapshot: snapshot, fileManager: fileManager)
            } catch {
                thrownError = error
            }
        }
        if let thrownError {
            throw thrownError
        }
    }

    public static func emit(_ event: LogEvent) {
        queue.async {
            write(event)
        }
    }

    public static func reset() {
        queue.sync {
            closeDestinations(state.destinations)
            state = State()
        }
    }

    public static func waitForDrain() {
        queue.sync { }
    }

    // MARK: - Internal helpers

    private static func reconfigure(snapshot: ConfigSnapshot, fileManager: FileManager) throws {
        closeDestinations(state.destinations)

        let logging = snapshot.root.logging
        let paths = snapshot.root.paths
        var newState = State()
        newState.configured = true
        newState.minLevel = logging.defaultLevel
        newState.overrides = logging.levelsOverride
        newState.timestampKind = logging.timestampKind
        newState.startDate = Date()

        newState.destinations = try prepareDestinations(
            logging.destinations,
            paths: paths,
            fileManager: fileManager
        )

        state = newState
    }

    private static func write(_ event: LogEvent) {
        let minLevel = state.overrides[event.processID] ?? state.minLevel
        guard event.level.priority >= minLevel.priority else { return }

        let timestamp: String
        switch state.timestampKind {
        case .relative:
            let delta = event.timestamp.timeIntervalSince(state.startDate)
            timestamp = String(format: "%.6f", max(delta, 0))
        case .absolute:
            timestamp = isoFormatter.string(from: event.timestamp)
        }

        let formatted = "[\(timestamp)][\(event.level.rawValue.uppercased())][\(event.processID)] \(event.message)\n"
        guard let data = formatted.data(using: .utf8) else { return }

        for destination in state.destinations {
            switch destination {
            case .stdout:
                FileHandle.standardOutput.write(data)
            case let .file(_, handle):
                do {
                    try handle.seekToEnd()
                    handle.write(data)
                    if #available(macOS 13.0, *) {
                        try handle.synchronize()
                    } else {
                        handle.synchronizeFile()
                    }
                } catch {
                    // swallow write errors for now; future work: surface diagnostics
                }
            }
        }
    }

    private static func prepareDestinations(
        _ destinations: [ConfigRoot.Logging.Destination],
        paths: ConfigRoot.Paths,
        fileManager: FileManager
    ) throws -> [Destination] {
        var prepared: [Destination] = []
        let baseDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let logsDirURL = resolvePath(paths.logsDir, baseDirectory: baseDirectory)
        try fileManager.createDirectory(at: logsDirURL, withIntermediateDirectories: true)

        for destination in destinations {
            switch destination.type {
            case .stdout:
                prepared.append(.stdout)
            case .file:
                guard let path = destination.path, !path.isEmpty else {
                    throw ConfigError.missingLogFilePath
                }
                let fileURL = resolvePath(path, baseDirectory: baseDirectory)
                let directoryURL = fileURL.deletingLastPathComponent()
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                if !fileManager.fileExists(atPath: fileURL.path) {
                    let created = fileManager.createFile(atPath: fileURL.path, contents: nil)
                    if !created {
                        throw ConfigError.failedToCreateLogFile(fileURL)
                    }
                }
                let handle: FileHandle
                do {
                    handle = try FileHandle(forWritingTo: fileURL)
                } catch {
                    throw ConfigError.failedToOpenLogFile(fileURL)
                }
                prepared.append(.file(fileURL, handle))
            }
        }

        if prepared.isEmpty {
            prepared.append(.stdout)
        }

        return prepared
    }

    private static func resolvePath(_ path: String, baseDirectory: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        } else {
            return baseDirectory.appendingPathComponent(path)
        }
    }

    private static func closeDestinations(_ destinations: [Destination]) {
        for destination in destinations {
            if case let .file(_, handle) = destination {
                try? handle.close()
            }
        }
    }

    private struct State {
        var configured = false
        var minLevel: LogLevel = .info
        var overrides: [String: LogLevel] = [:]
        var destinations: [Destination] = [.stdout]
        var timestampKind: ConfigRoot.Logging.TimestampKind = .relative
        var startDate: Date = Date()
    }

    private enum Destination {
        case stdout
        case file(URL, FileHandle)
    }
}
