import Foundation

public enum ProcessRegistry {
    private static var registry: [String: String] = [
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

    public static func resolve(_ alias: String) -> String {
        registry[alias, default: alias]
    }
}
