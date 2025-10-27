import CapsuleCore
import Foundation
import SharedInfrastructure

@main
struct CapsuleCLI {
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

        let capsuleConfig = snapshot.root.capsule
        LoggingHub.emit(
            LogEvent(
                processID: processID,
                level: .info,
                message: "Capsule config loaded from \(snapshot.sourceURL.path) · base=\(capsuleConfig.base), block_size=\(capsuleConfig.blockSize)"
            )
        )

        let capsule = CapsulePlaceholder()
        LoggingHub.emit(LogEvent(processID: processID, level: .info, message: capsule.describe()))
    }
}
