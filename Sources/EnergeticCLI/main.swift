import EnergeticCore
import SharedInfrastructure

@main
struct EnergeticCLI {
    static func main() {
        let router = EnergeticRouterPlaceholder()
        let processID = ProcessRegistry.resolve("cli.main")
        LoggingHub.emit(LogEvent(processID: processID, level: .info, message: router.describe()))
    }
}
