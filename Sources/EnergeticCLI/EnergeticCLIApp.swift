import EnergeticCore
import Foundation
import SharedInfrastructure

@main
struct EnergeticCLI {
    static func main() {
        let processID = ProcessRegistry.resolve("cli.main")

        let snapshot: ConfigSnapshot
        do {
            snapshot = try ConfigCenter.load()
            try LoggingHub.configure(from: snapshot)
        } catch {
            Diagnostics.fail("Failed to load config: \(error.localizedDescription)", processID: processID)
        return
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
