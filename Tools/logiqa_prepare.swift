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
    var dataset: String = "auto"
    var ethicsSubsets: String = "commonsense,deontology,justice,virtue"
    var ethicsLabelMode: String = "label"
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
        case "--dataset":
            if i + 1 < args.count { opts.dataset = args[i + 1]; i += 1 }
        case "--ethics-subsets":
            if i + 1 < args.count { opts.ethicsSubsets = args[i + 1]; i += 1 }
        case "--ethics-label-mode":
            if i + 1 < args.count { opts.ethicsLabelMode = args[i + 1]; i += 1 }
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

func isDirectory(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
        return isDir.boolValue
    }
    return false
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

let ethicsPrefixes: [String: String] = [
    "commonsense": "cm",
    "deontology": "deontology",
    "justice": "justice",
    "virtue": "virtue",
    "utilitarianism": "util"
]

let ethicsSupportedSubsets: Set<String> = ["commonsense", "deontology", "justice", "virtue"]

func parseCSV(_ text: String) -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var inQuotes = false
    var i = text.startIndex
    while i < text.endIndex {
        let ch = text[i]
        if inQuotes {
            if ch == "\"" {
                let next = text.index(after: i)
                if next < text.endIndex, text[next] == "\"" {
                    field.append("\"")
                    i = next
                } else {
                    inQuotes = false
                }
            } else {
                field.append(ch)
            }
        } else {
            if ch == "\"" {
                inQuotes = true
            } else if ch == "," {
                row.append(field)
                field = ""
            } else if ch == "\n" || ch == "\r" {
                if ch == "\r" {
                    let next = text.index(after: i)
                    if next < text.endIndex, text[next] == "\n" {
                        i = next
                    }
                }
                row.append(field)
                field = ""
                if !(row.count == 1 && row[0].isEmpty) {
                    rows.append(row)
                }
                row = []
            } else {
                field.append(ch)
            }
        }
        i = text.index(after: i)
    }
    if !field.isEmpty || !row.isEmpty {
        row.append(field)
        rows.append(row)
    }
    return rows
}

func loadCSVRecords(from url: URL) -> [[String: String]] {
    guard let data = try? Data(contentsOf: url),
          let text = String(data: data, encoding: .utf8)
    else { return [] }
    let rows = parseCSV(text)
    guard let header = rows.first, !header.isEmpty else { return [] }
    var records: [[String: String]] = []
    records.reserveCapacity(rows.count > 1 ? rows.count - 1 : 0)
    for row in rows.dropFirst() {
        var record: [String: String] = [:]
        record.reserveCapacity(header.count)
        for (idx, key) in header.enumerated() {
            record[key] = idx < row.count ? row[idx] : ""
        }
        records.append(record)
    }
    return records
}

func labelText(_ label: Int, mode: String) -> String? {
    guard label == 0 || label == 1 else { return nil }
    switch mode.lowercased() {
    case "label":
        return "LABEL_\(label)"
    case "yesno":
        return label == 1 ? "YES" : "NO"
    default:
        return nil
    }
}

func resolveEthicsRoot(inputURL: URL) -> URL {
    if isDirectory(inputURL.appendingPathComponent("commonsense")) {
        return inputURL
    }
    let nested = inputURL.appendingPathComponent("ethics")
    if isDirectory(nested.appendingPathComponent("commonsense")) {
        return nested
    }
    return inputURL
}

func makeEthicsPrepared(
    subset: String,
    split: String,
    records: [[String: String]],
    labelMode: String
) -> [Prepared] {
    var out: [Prepared] = []
    out.reserveCapacity(records.count)
    for (idx, record) in records.enumerated() {
        guard let labelRaw = record["label"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let label = Int(labelRaw),
              let answer = labelText(label, mode: labelMode),
              let wrong = labelText(1 - label, mode: labelMode)
        else { continue }

        let inputText: String
        switch subset {
        case "commonsense":
            inputText = record["input", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        case "deontology":
            let scenario = record["scenario", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            let excuse = record["excuse", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            inputText = excuse.isEmpty ? scenario : "\(scenario)\nExcuse: \(excuse)"
        case "justice":
            inputText = record["scenario", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        case "virtue":
            let raw = record["scenario", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = raw.range(of: " [SEP] ") {
                let scenario = raw[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                let trait = raw[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                inputText = trait.isEmpty ? String(scenario) : "\(scenario)\nTrait: \(trait)"
            } else {
                inputText = raw
            }
        default:
            inputText = ""
        }

        if inputText.isEmpty { continue }
        out.append(
            Prepared(
                id: "\(subset)-\(split)-\(idx)",
                split: split,
                input_text: inputText,
                answer_text: answer,
                wrong_answers: [wrong]
            )
        )
    }
    return out
}

func loadEthicsSplit(rootURL: URL, subset: String, split: String) -> [[String: String]] {
    guard let prefix = ethicsPrefixes[subset] else { return [] }
    let name: String
    switch split {
    case "train": name = "\(prefix)_train.csv"
    case "valid": name = "\(prefix)_test.csv"
    default: name = "\(prefix)_test.csv"
    }
    let url = rootURL.appendingPathComponent(subset).appendingPathComponent(name)
    if !FileManager.default.fileExists(atPath: url.path) { return [] }
    return loadCSVRecords(from: url)
}

func detectDatasetKind(inputURL: URL, requested: String) -> String {
    let req = requested.lowercased()
    if req == "ethics" || req == "logiqa" { return req }
    if isDirectory(inputURL) {
        if isDirectory(inputURL.appendingPathComponent("commonsense")) { return "ethics" }
        let nested = inputURL.appendingPathComponent("ethics")
        if isDirectory(nested.appendingPathComponent("commonsense")) { return "ethics" }
    }
    return "logiqa"
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
    print("Usage: logiqa_prepare.swift --input <file|dir> --output <dir> [--dataset logiqa|ethics] [--train-limit N] [--valid-limit N] [--no-shuffle] [--seed S] [--ethics-subsets LIST] [--ethics-label-mode label|yesno]")
    exit(1)
}

let inputURL = URL(fileURLWithPath: opts.inputPath)
let outDirURL = URL(fileURLWithPath: opts.outputDir)
try? FileManager.default.createDirectory(at: outDirURL, withIntermediateDirectories: true)

let datasetKind = detectDatasetKind(inputURL: inputURL, requested: opts.dataset)
if datasetKind == "ethics" {
    let rootURL = resolveEthicsRoot(inputURL: inputURL)
    if labelText(0, mode: opts.ethicsLabelMode) == nil {
        print("Invalid ETHICS label mode: \(opts.ethicsLabelMode). Use label or yesno.")
        exit(2)
    }
    let subsetList = opts.ethicsSubsets
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .filter { !$0.isEmpty }
    if subsetList.isEmpty {
        print("No ETHICS subsets provided. Use --ethics-subsets commonsense,deontology,justice,virtue")
        exit(2)
    }
    for subset in subsetList {
        if subset == "utilitarianism" {
            print("ETHICS utilitarianism has no labels in raw form. Exclude it or preprocess separately.")
            exit(2)
        }
        if !ethicsSupportedSubsets.contains(subset) {
            print("Unsupported ETHICS subset: \(subset)")
            exit(2)
        }
    }

    var trainAll: [Prepared] = []
    var validAll: [Prepared] = []
    var subsetIndex: UInt64 = 0
    for subset in subsetList {
        let trainRecords = loadEthicsSplit(rootURL: rootURL, subset: subset, split: "train")
        let validRecords = loadEthicsSplit(rootURL: rootURL, subset: subset, split: "valid")
        var trainPrepared = makeEthicsPrepared(subset: subset, split: "train", records: trainRecords, labelMode: opts.ethicsLabelMode)
        var validPrepared = makeEthicsPrepared(subset: subset, split: "valid", records: validRecords, labelMode: opts.ethicsLabelMode)

        if opts.shuffle {
            shuffleInPlace(&trainPrepared, seed: opts.seed &+ (subsetIndex &* 0x9E3779B97F4A7C15))
            shuffleInPlace(&validPrepared, seed: (opts.seed &+ 1) &+ (subsetIndex &* 0xBF58476D1CE4E5B9))
        }
        if opts.trainLimit > 0 && trainPrepared.count > opts.trainLimit {
            trainPrepared = Array(trainPrepared.prefix(opts.trainLimit))
        }
        if opts.validLimit > 0 && validPrepared.count > opts.validLimit {
            validPrepared = Array(validPrepared.prefix(opts.validLimit))
        }

        trainAll.append(contentsOf: trainPrepared)
        validAll.append(contentsOf: validPrepared)
        subsetIndex += 1
    }

    if trainAll.isEmpty && validAll.isEmpty {
        print("No ETHICS records found. Check input path: \(rootURL.path)")
        exit(2)
    }

    if opts.shuffle {
        shuffleInPlace(&trainAll, seed: opts.seed)
        shuffleInPlace(&validAll, seed: opts.seed &+ 1)
    }

    let trainOut = outDirURL.appendingPathComponent("prepared_train.jsonl")
    let validOut = outDirURL.appendingPathComponent("prepared_valid.jsonl")
    try writeJSONL(trainAll, to: trainOut)
    try writeJSONL(validAll, to: validOut)

    print("Prepared ETHICS train: \(trainAll.count) -> \(trainOut.path)")
    print("Prepared ETHICS valid: \(validAll.count) -> \(validOut.path)")
    exit(0)
}

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

if isDirectory(inputURL) || !FileManager.default.fileExists(atPath: inputURL.path) {
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
