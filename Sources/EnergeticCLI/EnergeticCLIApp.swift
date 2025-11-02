import EnergeticCore
import Foundation
import SharedInfrastructure

@main
struct EnergeticCLI {
    static func main() {
        let processID = (try? ProcessRegistry.resolve("cli.main")) ?? "cli.main"
        let env = ProcessInfo.processInfo.environment
        let configURL = env["SNN_CONFIG_PATH"].map { URL(fileURLWithPath: $0) }

        let snapshot: ConfigSnapshot
        do {
            snapshot = try ConfigCenter.load(url: configURL)
            ProcessRegistry.configure(from: snapshot)
            try LoggingHub.configure(from: snapshot)
        } catch {
            Diagnostics.fail("Failed to load config: \(error.localizedDescription)", processID: processID)
        }

        let routerConfig = snapshot.root.router
        LoggingHub.emit(
            process: "cli.main",
            level: .info,
            message: "Router config loaded from \(snapshot.sourceURL.path) · layers=\(routerConfig.layers), nodes_per_layer=\(routerConfig.nodesPerLayer), params=\(routerConfig.snn.parameterCount), surrogate=\(routerConfig.snn.surrogate)"
        )

        let router = EnergeticRouterPlaceholder()
        LoggingHub.emit(process: "router.step", level: .info, message: router.describe())

        if let exported: ConfigPipelineSnapshot = try? PipelineSnapshotExporter.export(snapshot: snapshot) {
            LoggingHub.emit(process: "cli.main", level: .debug, message: "Pipeline snapshot exported at \(exported.generatedAt)")
        }

        let hint = CLIRenderer.hint(for: snapshot.root)
        print(hint)
    }
}
