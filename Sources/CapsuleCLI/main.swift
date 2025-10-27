import CapsuleCore
import SharedInfrastructure

@main
struct CapsuleCLI {
    static func main() {
        let capsule = CapsulePlaceholder()
        let processID = ProcessRegistry.resolve("cli.main")
        LoggingHub.emit(LogEvent(processID: processID, level: .info, message: capsule.describe()))
    }
}
