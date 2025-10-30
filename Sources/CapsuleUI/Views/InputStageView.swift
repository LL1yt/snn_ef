import SwiftUI

/// Detailed view for the input text stage
public struct InputStageView: View {
    let stage: PipelineStage

    public init(stage: PipelineStage) {
        self.stage = stage
    }

    public var body: some View {
        if case let .text(input) = stage.data {
            VStack(alignment: .leading, spacing: 12) {
                Text("Original Input Text")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                // Input text display
                ScrollView {
                    Text(input)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(VisualizationColorScheme.codeBackground)
                        .cornerRadius(6)
                }
                .frame(maxHeight: 200)

                // Metrics
                GroupBox("Metrics") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Length (characters)", value: "\(input.count)")
                        LabeledContent("Length (bytes)", value: "\(stage.metrics.inputSize)")
                        LabeledContent("Encoding", value: "UTF-8")
                    }
                }

                // Sample character → UTF-8 byte mapping
                let samples = characterSamples(input: input, limit: 8)
                if !samples.isEmpty {
                    GroupBox("Sample UTF-8 Bytes") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(samples) { sample in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(sample.characterDescription)
                                        .font(.system(.caption, design: .monospaced))
                                        .frame(width: 60, alignment: .leading)
                                    Text("→")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.secondary)
                                    Text(sample.bytesDescription)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                            if input.count > samples.count {
                                Text("…")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func characterSamples(input: String, limit: Int) -> [CharacterSample] {
        guard limit > 0 else { return [] }
        var samples: [CharacterSample] = []
        samples.reserveCapacity(limit)
        for (index, character) in input.enumerated() {
            guard index < limit else { break }
            let utf8Bytes = Array(String(character).utf8)
            samples.append(
                CharacterSample(
                    id: index,
                    character: character,
                    utf8Bytes: utf8Bytes
                )
            )
        }
        return samples
    }
}

private struct CharacterSample: Identifiable {
    let id: Int
    let character: Character
    let utf8Bytes: [UInt8]

    var characterDescription: String {
        if character.isWhitespace {
            switch character {
            case " ": return "'␠'"
            case "\n": return "'␤'"
            case "\t": return "'⇥'"
            default:
                let scalar = character.unicodeScalars.first?.value ?? 0
                return String(format: "'U+%04X'", scalar)
            }
        }
        return "'\(character)'"
    }

    var bytesDescription: String {
        utf8Bytes.map { String(format: "0x%02X", $0) }.joined(separator: " ")
    }
}
