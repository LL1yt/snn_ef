import SwiftUI
import CapsuleUI
import SharedInfrastructure

/// Demo macOS app for CapsulePipelineView
@main
struct CapsulePipelineDemoApp: App {
    private let snapshot: ConfigSnapshot?
    private let loadError: Error?

    init() {
        do {
            let env = ProcessInfo.processInfo.environment
            let configURL = env["SNN_CONFIG_PATH"].map { URL(fileURLWithPath: $0) }

            let loadedSnapshot = try ConfigCenter.load(url: configURL)
            snapshot = loadedSnapshot
            loadError = nil

            try LoggingHub.configure(from: loadedSnapshot)
            ProcessRegistry.configure(from: loadedSnapshot)

            LoggingHub.emit(
                process: "ui.pipeline.app",
                level: .info,
                message: "CapsulePipeline demo launched with config: \(loadedSnapshot.sourceURL.path)"
            )
        } catch {
            snapshot = nil
            loadError = error
            print("Failed to load config: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            if let snapshot {
                CapsulePipelineView(config: snapshot.root.capsule)
                    .frame(minWidth: 900, minHeight: 600)
            } else {
                FailureView(error: loadError)
            }
        }
    }
}

private struct FailureView: View {
    let error: Error?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(.red)
            Text("Failed to load configuration")
                .font(.headline)
            if let error {
                Text(error.localizedDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text("Set SNN_CONFIG_PATH or run from repo root so Configs/baseline.yaml is discoverable.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 480, minHeight: 240)
    }
}
