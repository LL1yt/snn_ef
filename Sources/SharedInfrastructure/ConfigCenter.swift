import Foundation

public struct ConfigSnapshot: Sendable {
    public let raw: [String: Any]
    public init(raw: [String: Any] = [:]) {
        self.raw = raw
    }
}

public enum ConfigCenter {
    public static func load(path: URL) throws -> ConfigSnapshot {
        // TODO: implement YAML loading + validation per Docs/config_center_schema.md
        _ = path
        return ConfigSnapshot()
    }
}
