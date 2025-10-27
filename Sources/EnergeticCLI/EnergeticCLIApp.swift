import EnergeticCore
import Foundation
import SharedInfrastructure

@main
struct EnergeticCLI {
    static func main() {
        let processID = (try? ProcessRegistry.resolve("cli.main")) ?? "cli.main"

        let snapshot: ConfigSnapshot
        do {
            snapshot = try ConfigCenter.load()
            ProcessRegistry.configure(from: snapshot)
            try LoggingHub.configure(from: snapshot)
        } catch {
            Diagnostics.fail("Failed to load config: \(error.localizedDescription)", processID: processID)
        }

        let routerConfig = snapshot.root.router
        LoggingHub.emit(
            LogEvent(
                processID: processID,
                level: .info,
                message: "Router config loaded from \(snapshot.sourceURL.path) · layers=\(routerConfig.layers), nodes_per_layer=\(routerConfig.nodesPerLayer)"
            )
        )

        let router = EnergeticRouterPlaceholder()
        LoggingHub.emit(LogEvent(processID: processID, level: .info, message: router.describe()))
    }
}
