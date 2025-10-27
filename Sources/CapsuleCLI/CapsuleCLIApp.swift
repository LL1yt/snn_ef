import CapsuleCore
import Foundation
import SharedInfrastructure

@main
struct CapsuleCLI {
    static func main() {
        let processID = (try? ProcessRegistry.resolve("cli.main")) ?? "cli.main"
        let env = ProcessInfo.processInfo.environment
        let configURL = env["SNN_CONFIG_PATH"].map { URL(fileURLWithPath: $0) }

        let snapshot: ConfigSnapshot
        do {
            snapshot = try ConfigCenter.load(url: configURL)
            ProcessRegistry.configure(from: snapshot)
            try LoggingHub.configure(from: snapshot)
        } catch {
            Diagnostics.fail("Failed to load config: \(error.localizedDescription)", processID: processID)
        }

        let cfg = snapshot.root.capsule
        LoggingHub.emit(
            process: "cli.main",
            level: .info,
            message: "Capsule config loaded from \(snapshot.sourceURL.path) · base=\(cfg.base), block_size=\(cfg.blockSize)"
        )

        let args = Array(CommandLine.arguments.dropFirst())
        if args.isEmpty {
            printUsage(snapshot: snapshot)
            return
        }

        switch args[0] {
        case "encode":
            let input = args.dropFirst().joined(separator: " ")
            do {
                let data = Data(input.utf8)
                let encoder = CapsuleEncoder(config: cfg)
                let block = try encoder.encode(data)
                let digits = ByteDigitsConverter.toDigits(bytes: block.bytes, baseB: cfg.base)
                let printable = DigitStringConverter.digitsToString(digits, alphabet: cfg.alphabet)
                LoggingHub.emit(process: "capsule.encode", level: .info, message: "encoded bytes=\(data.count) digits=\(digits.count)")
                print(printable)
            } catch {
                Diagnostics.fail("encode failed: \(error.localizedDescription)", processID: processID)
            }

        case "decode":
            let printable = args.dropFirst().joined(separator: " ")
            do {
                let digits = DigitStringConverter.stringToDigits(printable, alphabet: cfg.alphabet)
                let bytes = ByteDigitsConverter.toBytes(digitsMSDFirst: digits, baseB: cfg.base, byteCount: cfg.blockSize)
                let block = try CapsuleBlock(blockSize: cfg.blockSize, bytes: bytes)
                let decoder = CapsuleDecoder(config: cfg)
                let data = try decoder.decode(block)
                let text = String(decoding: data, as: UTF8.self)
                LoggingHub.emit(process: "capsule.decode", level: .info, message: "decoded bytes=\(data.count)")
                print(text)
            } catch {
                Diagnostics.fail("decode failed: \(error.localizedDescription)", processID: processID)
            }

        default:
            printUsage(snapshot: snapshot)
        }

        if let exported = try? PipelineSnapshotExporter.export(snapshot: snapshot) {
            LoggingHub.emit(process: "cli.main", level: .debug, message: "Pipeline snapshot exported at \(exported.generatedAt)")
        }

        let hint = CLIRenderer.hint(for: snapshot.root)
        print(hint)
    }

    private static func printUsage(snapshot: ConfigSnapshot) {
        let cfg = snapshot.root.capsule
        let usage = """
        Usage:
          capsule-cli encode <text>   # encodes UTF-8 text into base-\(cfg.base) printable string (fixed length)
          capsule-cli decode <digits> # decodes printable base-\(cfg.base) string back to UTF-8 text
        """.trimmingCharacters(in: .whitespacesAndNewlines)
        print(usage)
    }
}
