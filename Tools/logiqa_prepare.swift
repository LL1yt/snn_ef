#!/usr/bin/env swift
import Foundation

struct Record: Decodable {
    let context: String
    let query: String
    let answers: [String]
    let correct_option: Int
    let split: String?
}

struct Prepared: Encodable {
    let id: String
    let split: String
    let input_text: String
    let answer_text: String
    let wrong_answers: [String]
}

struct Options {
    var inputPath: String = ""
    var outputDir: String = ""
    var trainLimit: Int = 0
    var validLimit: Int = 0
    var shuffle: Bool = true
    var seed: UInt64 = 42
}

let urls: [String: String] = [
    "train": "https://raw.githubusercontent.com/lgw863/LogiQA-dataset/master/Train.txt",
    "validation": "https://raw.githubusercontent.com/lgw863/LogiQA-dataset/master/Eval.txt",
    "test": "https://raw.githubusercontent.com/lgw863/LogiQA-dataset/master/Test.txt"
]

struct LCG {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1
        return state
    }
    mutating func nextInt(upperBound: Int) -> Int {
        return Int(next() % UInt64(upperBound))
    }
}

func parseArgs() -> Options {
    var opts = Options()
    var i = 1
    let args = CommandLine.arguments
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--input":
            if i + 1 < args.count { opts.inputPath = args[i + 1]; i += 1 }
        case "--output":
            if i + 1 < args.count { opts.outputDir = args[i + 1]; i += 1 }
        case "--train-limit":
            if i + 1 < args.count { opts.trainLimit = Int(args[i + 1]) ?? 0; i += 1 }
        case "--valid-limit":
            if i + 1 < args.count { opts.validLimit = Int(args[i + 1]) ?? 0; i += 1 }
        case "--no-shuffle":
            opts.shuffle = false
        case "--seed":
            if i + 1 < args.count { opts.seed = UInt64(args[i + 1]) ?? 42; i += 1 }
        default:
            break
        }
        i += 1
    }
    return opts
}

func readLines(from url: URL) throws -> [String] {
    let data = try Data(contentsOf: url)
    guard let text = String(data: data, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").map { String($0) }
}

func downloadIfMissing(_ urlString: String, to destURL: URL) {
    if FileManager.default.fileExists(atPath: destURL.path) { return }
    guard let url = URL(string: urlString) else { return }
    let sema = DispatchSemaphore(value: 0)
    let task = URLSession.shared.downloadTask(with: url) { tmp, _, _ in
        defer { sema.signal() }
        guard let tmp else { return }
        do {
            try FileManager.default.moveItem(at: tmp, to: destURL)
        } catch {
            _ = try? FileManager.default.removeItem(at: destURL)
            try? FileManager.default.copyItem(at: tmp, to: destURL)
        }
    }
    task.resume()
    sema.wait()
}

func decodeRecords(lines: [String]) -> [Record] {
    let decoder = JSONDecoder()
    var out: [Record] = []
    out.reserveCapacity(lines.count)
    for line in lines {
        guard let data = line.data(using: .utf8) else { continue }
        if let rec = try? decoder.decode(Record.self, from: data) {
            out.append(rec)
        }
    }
    return out
}

func makePrepared(records: [Record], splitName: String) -> [Prepared] {
    var result: [Prepared] = []
    result.reserveCapacity(records.count)
    for (idx, rec) in records.enumerated() {
        let input = rec.context + "\nQuestion: " + rec.query
        let correct = rec.correct_option
        if correct < 0 || correct >= rec.answers.count { continue }
        let answer = rec.answers[correct]
        let wrong = rec.answers.enumerated().filter { $0.offset != correct }.map { $0.element }
        let id = "\(splitName)-\(idx)"
        result.append(Prepared(id: id, split: splitName, input_text: input, answer_text: answer, wrong_answers: wrong))
    }
    return result
}

func processAnswer(_ answer: String) -> String {
    let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = trimmed.first else { return trimmed }
    if "ABCD".contains(first), trimmed.count >= 3 {
        let idx = trimmed.index(trimmed.startIndex, offsetBy: 3)
        return String(trimmed[idx...]).trimmingCharacters(in: .whitespaces)
    }
    return trimmed
}

func processSentences(_ text: String) -> String {
    var t = text.replacingOccurrences(of: "\n", with: "")
    let parts = t.split(separator: ".")
    var out = ""
    for part in parts {
        if part.isEmpty { continue }
        let s = String(part)
        if out.isEmpty {
            out += s
        } else if let first = s.first, first.isNumber {
            out += "." + s
        } else {
            out += ". " + s
        }
    }
    out = out.replacingOccurrences(of: "  ", with: " ")
    out = out.replacingOccurrences(of: "\\'", with: "'")
    while out.hasSuffix(" ") { out.removeLast() }
    if let last = out.last, last != "?" && last != "!" && last != "." {
        out += "."
    }
    out = out.replacingOccurrences(of: "?.", with: "?")
    out = out.replacingOccurrences(of: "!.", with: "!")
    out = out.replacingOccurrences(of: "..", with: ".")
    return out
}

func decodeTXTRecords(lines: [String]) -> [Record] {
    let cleaned = lines.map { processSentences($0) }
    let chunk = 8
    var out: [Record] = []
    let total = cleaned.count / chunk
    out.reserveCapacity(total)
    for i in 0..<total {
        let row = i * chunk
        let correctRaw = cleaned[row + 1].replacingOccurrences(of: ".", with: "").lowercased()
        let map = ["a": 0, "b": 1, "c": 2, "d": 3]
        let key = String(correctRaw.prefix(1))
        let correct = map[key] ?? 0
        let context = cleaned[row + 2]
        let query = cleaned[row + 3]
        let answers = Array(cleaned[(row + 4)..<(row + 8)]).map(processAnswer)
        let rec = Record(context: context, query: query, answers: answers, correct_option: correct, split: nil)
        out.append(rec)
    }
    return out
}

func shuffleInPlace<T>(_ array: inout [T], seed: UInt64) {
    var rng = LCG(seed: seed)
    if array.count < 2 { return }
    for i in stride(from: array.count - 1, through: 1, by: -1) {
        let j = rng.nextInt(upperBound: i + 1)
        if i != j { array.swapAt(i, j) }
    }
}

func writeJSONL(_ items: [Prepared], to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = []
    var lines: [String] = []
    lines.reserveCapacity(items.count)
    for item in items {
        let data = try encoder.encode(item)
        if let line = String(data: data, encoding: .utf8) {
            lines.append(line)
        }
    }
    let text = lines.joined(separator: "\n") + "\n"
    try text.write(to: url, atomically: true, encoding: .utf8)
}

let opts = parseArgs()
if opts.inputPath.isEmpty || opts.outputDir.isEmpty {
    print("Usage: logiqa_prepare.swift --input <file|dir> --output <dir> [--train-limit N] [--valid-limit N] [--no-shuffle] [--seed S]")
    exit(1)
}

let inputURL = URL(fileURLWithPath: opts.inputPath)
let outDirURL = URL(fileURLWithPath: opts.outputDir)
try? FileManager.default.createDirectory(at: outDirURL, withIntermediateDirectories: true)

func loadSplit(_ name: String) -> [Record] {
    let jsonURL = inputURL.appendingPathComponent("\(name).jsonl")
    if FileManager.default.fileExists(atPath: jsonURL.path),
       let lines = try? readLines(from: jsonURL) {
        return decodeRecords(lines: lines)
    }

    let txtName: String
    switch name {
    case "train": txtName = "Train.txt"
    case "validation": txtName = "Eval.txt"
    default: txtName = "Test.txt"
    }
    let txtURL = inputURL.appendingPathComponent(txtName)
    if FileManager.default.fileExists(atPath: txtURL.path),
       let lines = try? readLines(from: txtURL) {
        return decodeTXTRecords(lines: lines)
    }

    if let lines = try? readLines(from: inputURL) {
        let records = decodeRecords(lines: lines)
        return records.filter { ($0.split ?? "") == name }
    }

    return []
}

if inputURL.hasDirectoryPath {
    if !FileManager.default.fileExists(atPath: inputURL.path) {
        try? FileManager.default.createDirectory(at: inputURL, withIntermediateDirectories: true)
    }
    if let url = urls["train"] {
        downloadIfMissing(url, to: inputURL.appendingPathComponent("Train.txt"))
    }
    if let url = urls["validation"] {
        downloadIfMissing(url, to: inputURL.appendingPathComponent("Eval.txt"))
    }
    if let url = urls["test"] {
        downloadIfMissing(url, to: inputURL.appendingPathComponent("Test.txt"))
    }
}

var train = loadSplit("train")
var valid = loadSplit("validation")

if train.isEmpty && valid.isEmpty {
    print("No records found. Provide train.jsonl/validation.jsonl or a combined file with split field.")
    exit(2)
}

if opts.shuffle {
    shuffleInPlace(&train, seed: opts.seed)
    shuffleInPlace(&valid, seed: opts.seed &+ 1)
}

if opts.trainLimit > 0 && train.count > opts.trainLimit {
    train = Array(train.prefix(opts.trainLimit))
}
if opts.validLimit > 0 && valid.count > opts.validLimit {
    valid = Array(valid.prefix(opts.validLimit))
}

let preparedTrain = makePrepared(records: train, splitName: "train")
let preparedValid = makePrepared(records: valid, splitName: "validation")

let trainOut = outDirURL.appendingPathComponent("prepared_train.jsonl")
let validOut = outDirURL.appendingPathComponent("prepared_valid.jsonl")
try writeJSONL(preparedTrain, to: trainOut)
try writeJSONL(preparedValid, to: validOut)

print("Prepared train: \(preparedTrain.count) -> \(trainOut.path)")
print("Prepared valid: \(preparedValid.count) -> \(validOut.path)")
