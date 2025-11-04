import Foundation

public enum CLIRenderer {
    public static func hint(for config: ConfigRoot) -> String {
        let uiEnabled = config.ui.enabled ? "enabled" : "disabled"
        let headlessNote = config.ui.headlessOverride ? "forced headless" : "toggleable"
        let pipelineSnippet = config.capsule.pipelineExampleText.isEmpty ? "n/a" : config.capsule.pipelineExampleText
        let surrogate = config.router.flow.lif.surrogate
        let logsDir = config.paths.logsDir

        let snapshotURL = (try? PipelineSnapshotExporter.resolvedURL(for: config.paths.pipelineSnapshot, fileManager: .default))
        let fm = FileManager.default
        var snapshotInfo = "Pipeline snapshot: not generated"
        if let url = snapshotURL, fm.fileExists(atPath: url.path) {
            if let attrs = try? fm.attributesOfItem(atPath: url.path), let date = attrs[.modificationDate] as? Date {
                snapshotInfo = "Pipeline snapshot updated: \(format(date: date))"
            }
        }

        var lastEventsLine = "Last events: n/a"
        let aliases = ["capsule.encode", "router.step", "router.spike", "ui.pipeline", "cli.main"]
        var parts: [String] = []
        for alias in aliases {
            if let date = LoggingHub.lastEventTimestamp(for: alias) {
                parts.append("\(alias)=\(format(date: date))")
            }
        }
        if !parts.isEmpty {
            lastEventsLine = "Last events: " + parts.joined(separator: ", ")
        }

        return """
        Profile: \(config.profile)
        UI: \(uiEnabled) (headless override: \(headlessNote))
        Router: backend=\(config.router.backend), T=\(config.router.flow.T), bins=\(config.router.flow.projection.bins), surrogate=\(surrogate)
        Logs directory: \(logsDir)
        Capsule example snippet: \(pipelineSnippet)
        \(snapshotInfo)
        \(lastEventsLine)
        """.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func format(date: Date) -> String {
        isoFormatter.string(from: date)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
