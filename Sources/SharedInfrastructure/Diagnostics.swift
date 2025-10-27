import Foundation

public enum Diagnostics {
    private static let queue = DispatchQueue(label: "Diagnostics.queue")
    private static var failureHandler: FailureHandler = .precondition

    public static func setFailureHandler(_ handler: @escaping (String) -> Void) {
        queue.sync { failureHandler = .custom(handler) }
    }

    public static func resetFailureHandler() {
        queue.sync { failureHandler = .precondition }
    }

    public static func fail(_ message: String, processID alias: String = "cli.main") -> Never {
        LoggingHub.emit(process: alias, level: .error, message: message)

        switch queue.sync(execute: { failureHandler }) {
        case .precondition:
            preconditionFailure(message)
        case let .custom(handler):
            handler(message)
            preconditionFailure(message)
        }
    }

    private enum FailureHandler {
        case precondition
        case custom((String) -> Void)
    }
}

#if DEBUG
public struct DiagnosticsTestError: Error, Equatable {
    public let message: String
    public let processID: String
}

public extension Diagnostics {
    @discardableResult
    static func failForTesting(_ message: String, processID alias: String = "cli.main") throws -> Never {
        let canonical = (try? ProcessRegistry.resolve(alias)) ?? alias
        LoggingHub.emit(process: alias, level: .error, message: message)
        throw DiagnosticsTestError(message: message, processID: canonical)
    }
}
#endif
