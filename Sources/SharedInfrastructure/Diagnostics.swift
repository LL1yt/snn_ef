import Foundation

public enum Diagnostics {
    public static func fail(_ message: String, processID: String = ProcessRegistry.resolve("cli.main")) -> Never {
        LoggingHub.emit(LogEvent(processID: processID, level: .error, message: message))
        fatalError(message)
    }
}
