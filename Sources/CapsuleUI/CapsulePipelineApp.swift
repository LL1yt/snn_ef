import SwiftUI
import SharedInfrastructure

/// Demo macOS app for CapsulePipelineView
@main
struct CapsulePipelineApp: App {
    init() {
        // Load configuration on app launch
        do {
            let snapshot = try ConfigCenter.load()
            try LoggingHub.configure(from: snapshot)
            ProcessRegistry.configure(from: snapshot)

            LoggingHub.emit(
                process: "ui.pipeline.app",
                level: .info,
                message: "CapsulePipeline app launched with config: \(snapshot.sourceURL.path)"
            )
        } catch {
            print("Failed to load config: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            if let snapshot = try? ConfigCenter.load() {
                CapsulePipelineView(config: snapshot.root.capsule)
                    .frame(minWidth: 900, minHeight: 600)
            } else {
                Text("Failed to load configuration")
                    .foregroundColor(.red)
            }
        }
    }
}
