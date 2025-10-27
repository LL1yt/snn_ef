import Foundation

public enum CLIRenderer {
    public static func hint(for config: ConfigRoot) -> String {
        let uiEnabled = config.ui.enabled ? "enabled" : "disabled"
        let headlessNote = config.ui.headlessOverride ? "forced headless" : "toggleable"
        let pipelineSnippet = config.capsule.pipelineExampleText.isEmpty ? "n/a" : config.capsule.pipelineExampleText
        let backend = config.router.backend
        let logsDir = config.paths.logsDir

        return """
        Profile: \(config.profile)
        UI: \(uiEnabled) (headless override: \(headlessNote))
        Router backend: \(backend)
        Logs directory: \(logsDir)
        Capsule example snippet: \(pipelineSnippet)
        """.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
