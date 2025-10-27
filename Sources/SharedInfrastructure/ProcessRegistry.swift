import Foundation

public enum ProcessRegistry {
    private static let queue = DispatchQueue(label: "ProcessRegistry.queue")
    private static let defaultMapping: [String: String] = [
        "capsule.encode": "capsule.encode",
        "capsule.base_b": "capsule.base_b",
        "capsule.to_energies": "capsule.to_energies",
        "capsule.from_energies": "capsule.from_energies",
        "router.forward": "router.forward",
        "router.backward": "router.backward",
        "router.local_hebb": "router.local_hebb",
        "router.checkpoint": "router.checkpoint",
        "trainer.loop": "trainer.loop",
        "trainer.eval": "trainer.eval",
        "ui.pipeline": "ui.pipeline",
        "ui.graph": "ui.graph",
        "cli.main": "cli.main"
    ]

    private static var mapping = defaultMapping

    public static func configure(from snapshot: ConfigSnapshot) {
        queue.sync {
            mapping = defaultMapping.merging(snapshot.root.processRegistry) { _, new in new }
        }
    }

    public static func resolve(_ alias: String) throws -> String {
        try queue.sync {
            guard let canonical = mapping[alias] else {
                throw ProcessRegistryError.unknownAlias(alias)
            }
            return canonical
        }
    }

    public static func reset() {
        queue.sync {
            mapping = defaultMapping
        }
    }
}

public enum ProcessRegistryError: Error, Equatable, LocalizedError {
    case unknownAlias(String)

    public var errorDescription: String? {
        switch self {
        case let .unknownAlias(alias):
            return "Unknown process alias \(alias)"
        }
    }
}
