import SwiftUI
import EnergeticUI
import SharedInfrastructure

@main
struct EnergeticVisualizationDemoApp: App {
    private let snapshot: ConfigSnapshot?
    private let loadError: Error?

    init() {
        var resolvedSnapshot: ConfigSnapshot?
        var resolvedError: Error?

        do {
            let env = ProcessInfo.processInfo.environment
            let configURL = env["SNN_CONFIG_PATH"].map { URL(fileURLWithPath: $0) }

            let loadedSnapshot = try ConfigCenter.load(url: configURL)
            try LoggingHub.configure(from: loadedSnapshot)
            ProcessRegistry.configure(from: loadedSnapshot)

            resolvedSnapshot = loadedSnapshot
            resolvedError = nil

            LoggingHub.emit(
                process: "ui.pipeline.app",
                level: .info,
                message: "EnergeticVisualization demo launched with config: \(loadedSnapshot.sourceURL.path)"
            )
        } catch {
            resolvedSnapshot = nil
            resolvedError = error
            print("Failed to load config: \(error)")
        }

        snapshot = resolvedSnapshot
        loadError = resolvedError
    }

    var body: some Scene {
        WindowGroup {
            if loadError == nil || snapshot != nil {
                if let cfgSnap = snapshot {
                    VStack(spacing: 16) {
                        LearningMetricsView(logFileURL: LearningLogSource.resolveLogFileURL(from: cfgSnap))
                            .frame(minWidth: 1100, minHeight: 520)
                            .padding(.horizontal)
                    }
                } else {
                    FailureView(error: loadError)
                }
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
