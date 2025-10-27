import EnergeticCore
import Foundation
import SharedInfrastructure

@main
struct EnergeticCLI {
    static func main() {
        let processID = ProcessRegistry.resolve("cli.main")

        do {
            let snapshot = try ConfigCenter.load()
            let routerConfig = snapshot.root.router
            LoggingHub.emit(
                LogEvent(
                    processID: processID,
                    level: .info,
                    message: "Router config loaded from \(snapshot.sourceURL.path) · layers=\(routerConfig.layers), nodes_per_layer=\(routerConfig.nodesPerLayer)"
                )
            )
        } catch {
            Diagnostics.fail("Failed to load config: \(error.localizedDescription)", processID: processID)
        }

        let router = EnergeticRouterPlaceholder()
        LoggingHub.emit(LogEvent(processID: processID, level: .info, message: router.describe()))
    }
}
