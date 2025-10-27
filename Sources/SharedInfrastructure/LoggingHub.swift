import Foundation

public enum LogLevel: String, Sendable {
    case trace, debug, info, warn, error
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
    public static func emit(_ event: LogEvent) {
        // TODO: route to destinations defined in ConfigCenter
        print("[\(event.level.rawValue.uppercased())][\(event.processID)] \(event.message)")
    }
}
