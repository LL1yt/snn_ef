import XCTest
@testable import EnergeticCore

final class LogiQADatasetLoaderTests: XCTestCase {
    func testLoadJSONLParsesRecords() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("sample.jsonl")
        let line = "{\"id\":\"train-0\",\"split\":\"train\",\"input_text\":\"ctx\",\"answer_text\":\"ans\",\"wrong_answers\":[\"w1\",\"w2\"]}"
        try (line + "\n").write(to: fileURL, atomically: true, encoding: .utf8)

        let items = try LogiQADatasetLoader.loadJSONL(from: fileURL.path, limit: 0, shuffle: false, seed: 1)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, "train-0")
        XCTAssertEqual(items[0].input_text, "ctx")
        XCTAssertEqual(items[0].answer_text, "ans")
        XCTAssertEqual(items[0].wrong_answers.count, 2)
    }

    func testLoadJSONLMissingFileThrows() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("missing.jsonl")
        XCTAssertThrowsError(try LogiQADatasetLoader.loadJSONL(from: missing.path, limit: 0, shuffle: false, seed: 1))
    }
}
