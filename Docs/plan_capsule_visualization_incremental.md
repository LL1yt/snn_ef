# План инкрементальной визуализации CapsuleCore (macOS · Swift · SwiftUI)

_С определённой долей вероятности ≈ 90 %: этот план позволит постепенно покрывать визуализацией реализованный функционал, чередуя бэкенд и UI-фазы._

**Текущий статус:** Реализован полный **CapsuleCore** (шаги 1.1–1.5): структуры, кодек, Feistel PRP, CRC32, конвертеры bytes↔digits↔printable, EnergyMapper, CapsuleBridge, тесты, CLI.

**Цель:** Создать интерактивную визуализацию пайплайна, которая:
- Показывает **каждый этап** трансформации с реальными данными
- Позволяет **интерактивно** вводить текст и наблюдать прохождение через систему
- Помогает **интуитивно понять** работу всех компонентов
- Служит **инструментом отладки** для будущих улучшений
- Готова к **расширению** при добавлении роутера и других компонентов

---

## Структура визуализации

### Архитектура модулей

```
Sources/
├─ CapsuleUI/
│  ├─ CapsuleUI.swift                     # существует (базовый preview)
│  ├─ Models/
│  │  ├─ PipelineStage.swift              # модель этапа пайплайна
│  │  ├─ PipelineSnapshot.swift           # снимок состояния всех этапов
│  │  └─ PipelineMetrics.swift            # метрики для каждого этапа
│  ├─ Executors/
│  │  ├─ PipelineExecutor.swift           # оркестратор выполнения пайплайна
│  │  └─ StageDataCapture.swift           # захват данных на каждом этапе
│  ├─ Views/
│  │  ├─ CapsulePipelineView.swift        # главная view пайплайна
│  │  ├─ InputStageView.swift             # этап: исходный текст
│  │  ├─ BlockStructureView.swift         # этап: Header+Data+Padding
│  │  ├─ PRPStageView.swift               # этап: PRP трансформация
│  │  ├─ CapsuleHexView.swift             # этап: капсюль (hex dump)
│  │  ├─ DigitsStageView.swift            # этап: base-B digits
│  │  ├─ PrintableStageView.swift         # этап: printable string
│  │  ├─ EnergiesStageView.swift          # этап: энергии [1..B]
│  │  ├─ NormalizedStageView.swift        # этап: нормализованные [0..1]
│  │  ├─ ReverseStageView.swift           # этап: обратный процесс
│  │  └─ MetricsPanelView.swift           # панель метрик
│  ├─ Components/
│  │  ├─ HexDumpView.swift                # компонент hex-дампа
│  │  ├─ DigitsTableView.swift            # компонент таблицы цифр
│  │  ├─ StageHeaderView.swift            # заголовок этапа
│  │  ├─ StageNavigationView.swift        # навигация (prev/next/play)
│  │  └─ ErrorHighlightView.swift         # подсветка ошибок
│  └─ Utilities/
│     ├─ HexFormatter.swift               # форматирование hex
│     ├─ DataFormatter.swift              # форматирование данных
│     └─ ColorScheme.swift                # цветовая схема для этапов
```

---

## Фазы реализации

### ✅ ФАЗА 0: Базовая инфраструктура (ГОТОВО)
- CapsuleCore полностью реализован
- CLI работает
- Базовая UI структура создана
- ConfigCenter, LoggingHub, ProcessRegistry готовы

---

### 🎯 ФАЗА 1: Модель данных пайплайна (0.5 дня)

**Цель:** Создать структуры данных для представления каждого этапа трансформации.

#### 1.1. PipelineStage
```swift
public enum PipelineStageType: String, Sendable, Codable {
    case input              // исходный текст
    case blockStructure     // Header + Data + Padding
    case prpTransform       // PRP применён
    case capsuleBlock       // финальный capsule block
    case baseConversion     // конверсия в base-B digits
    case printableString    // printable representation
    case energiesMapping    // энергии [1..B]
    case normalization      // нормализованные значения
    case reverseProcess     // обратный процесс
    case recovered          // восстановленный текст
}

public struct PipelineStage: Sendable, Identifiable {
    public let id: UUID
    public let type: PipelineStageType
    public let timestamp: Date
    public let data: StageData
    public let metrics: StageMetrics
    public let error: Error?
}

public enum StageData: Sendable {
    case text(String)
    case bytes([UInt8])
    case header(CapsuleHeader, payload: [UInt8], padding: Int)
    case digits([Int])
    case printable(String)
    case energies([Int])
    case normalized([Double])
}

public struct StageMetrics: Sendable {
    public let duration: TimeInterval
    public let inputSize: Int
    public let outputSize: Int
    public let metadata: [String: String]
}
```

#### 1.2. PipelineSnapshot
```swift
public struct PipelineSnapshot: Sendable {
    public let id: UUID
    public let generatedAt: Date
    public let inputText: String
    public let config: ConfigRoot.Capsule
    public let stages: [PipelineStage]
    public let totalDuration: TimeInterval
    public let success: Bool
}
```

_Оценка уверенности: ≈ 95 % (простые структуры данных)._

---

### 🎯 ФАЗА 2: PipelineExecutor (1 день)

**Цель:** Создать оркестратор, который выполняет все этапы и захватывает детали каждого.

#### 2.1. PipelineExecutor
```swift
public actor PipelineExecutor {
    private let config: ConfigRoot.Capsule
    private var currentSnapshot: PipelineSnapshot?

    public init(config: ConfigRoot.Capsule)

    // Выполнить полный прямой пайплайн
    public func executeForward(_ input: String) async throws -> PipelineSnapshot

    // Выполнить обратный пайплайн
    public func executeReverse(from energies: [Int]) async throws -> PipelineSnapshot

    // Выполнить круговой проход (forward + reverse)
    public func executeRoundtrip(_ input: String) async throws -> PipelineSnapshot
}
```

#### 2.2. Логика захвата данных
Для каждого этапа:
1. Засечь время начала
2. Выполнить трансформацию
3. Засечь время окончания
4. Создать StageData с полными деталями
5. Вычислить метрики
6. Залогировать через LoggingHub
7. Добавить этап в snapshot

#### 2.3. Детали каждого этапа

**Этап 1: Input**
- Данные: исходная UTF-8 строка
- Метрики: длина в байтах, длина в символах

**Этап 2: Block Structure**
- Данные: Header (len, flags, crc32), payload bytes, padding size
- Метрики: header size, payload size, padding size, total block size

**Этап 3: PRP Transform**
- Данные: bytes до PRP, bytes после PRP
- Метрики: rounds count, transform time

**Этап 4: Capsule Block**
- Данные: финальный block bytes
- Метрики: block size, первые/последние 16 байт

**Этап 5: Base Conversion**
- Данные: массив digits [0..B-1]
- Метрики: digits count, base B, теоретический D

**Этап 6: Printable String**
- Данные: printable string (по алфавиту)
- Метрики: string length, alphabet size

**Этап 7: Energies Mapping**
- Данные: массив energies [1..B]
- Метрики: min/max/mean энергии, sum

**Этап 8: Normalization**
- Данные: normalized values [0..1]
- Метрики: min/max/mean нормализованных значений

**Этап 9: Reverse Process**
- Данные: восстановленные bytes после inverse PRP
- Метрики: время обратного прохода

**Этап 10: Recovered**
- Данные: восстановленный UTF-8 текст
- Метрики: CRC match (bool), recovered length

#### 2.4. Интеграция с LoggingHub
```swift
LoggingHub.emit(
    process: "ui.pipeline",
    level: .info,
    message: "Stage \(stage.type.rawValue) completed in \(metrics.duration)ms"
)
```

_Оценка уверенности: ≈ 90 % (стандартная оркестрация)._

---

### 🎯 ФАЗА 3: Базовые UI компоненты (0.5 дня)

**Цель:** Создать переиспользуемые компоненты для отображения данных.

#### 3.1. HexDumpView
```swift
struct HexDumpView: View {
    let bytes: [UInt8]
    let bytesPerRow: Int = 16
    let highlightRange: Range<Int>?

    var body: some View {
        // Формат: offset | hex bytes | ASCII
        // 00000000 | 48 65 6c 6c 6f 20 57 6f | Hello Wo
        // 00000008 | 72 6c 64 21 00 00 00 00 | rld!....
    }
}
```

#### 3.2. DigitsTableView
```swift
struct DigitsTableView: View {
    let digits: [Int]
    let base: Int
    let columns: Int = 10
    let highlightIndices: Set<Int>?

    var body: some View {
        // Grid с digits, позиция и значение
        // [0]: 42   [1]: 15   [2]: 89 ...
    }
}
```

#### 3.3. StageHeaderView
```swift
struct StageHeaderView: View {
    let stage: PipelineStage
    let expanded: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack {
            Image(systemName: iconForStage(stage.type))
            Text(stage.type.rawValue)
            Spacer()
            if let error = stage.error {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.red)
            }
            Text("\(stage.metrics.duration * 1000, specifier: "%.2f") ms")
                .font(.caption)
                .foregroundColor(.secondary)
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
        }
    }
}
```

#### 3.4. StageNavigationView
```swift
struct StageNavigationView: View {
    let currentIndex: Int
    let totalStages: Int
    let isPlaying: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onTogglePlay: () -> Void
    let onReset: () -> Void

    var body: some View {
        HStack {
            Button(action: onPrevious) {
                Image(systemName: "chevron.left.circle")
            }
            .disabled(currentIndex == 0)

            Button(action: onTogglePlay) {
                Image(systemName: isPlaying ? "pause.circle" : "play.circle")
            }

            Button(action: onNext) {
                Image(systemName: "chevron.right.circle")
            }
            .disabled(currentIndex >= totalStages - 1)

            Spacer()

            Text("\(currentIndex + 1) / \(totalStages)")
                .font(.caption)

            Spacer()

            Button(action: onReset) {
                Image(systemName: "arrow.counterclockwise.circle")
            }
        }
    }
}
```

_Оценка уверенности: ≈ 95 % (стандартные SwiftUI компоненты)._

---

### 🎯 ФАЗА 4: Детальные view для каждого этапа (1.5 дня)

**Цель:** Создать специализированные view для каждого типа этапа.

#### 4.1. InputStageView
```swift
struct InputStageView: View {
    let stage: PipelineStage

    var body: some View {
        if case let .text(input) = stage.data {
            VStack(alignment: .leading, spacing: 8) {
                Text("Original Text")
                    .font(.headline)

                Text(input)
                    .font(.body)
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)

                LabeledContent("Length (bytes)", value: "\(stage.metrics.inputSize)")
                LabeledContent("Length (chars)", value: "\(input.count)")
            }
        }
    }
}
```

#### 4.2. BlockStructureView
```swift
struct BlockStructureView: View {
    let stage: PipelineStage

    var body: some View {
        if case let .header(header, payload, paddingSize) = stage.data {
            VStack(alignment: .leading, spacing: 12) {
                // Header details
                GroupBox("Header (\(CapsuleHeader.byteCount) bytes)") {
                    LabeledContent("Length", value: "\(header.length)")
                    LabeledContent("Flags", value: "0x\(String(header.flags, radix: 16))")
                    LabeledContent("CRC32", value: "0x\(String(header.crc32, radix: 16))")
                }

                // Payload
                GroupBox("Payload (\(payload.count) bytes)") {
                    HexDumpView(bytes: payload, highlightRange: nil)
                }

                // Padding
                LabeledContent("Padding", value: "\(paddingSize) bytes")

                // Total
                LabeledContent("Total Block Size", value: "\(stage.metrics.outputSize) bytes")
            }
        }
    }
}
```

#### 4.3. PRPStageView
```swift
struct PRPStageView: View {
    let beforePRP: [UInt8]
    let afterPRP: [UInt8]
    let rounds: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Feistel PRP (\(rounds) rounds)")
                .font(.headline)

            GroupBox("Before PRP (first/last 16 bytes)") {
                HStack {
                    HexDumpView(bytes: Array(beforePRP.prefix(16)), highlightRange: nil)
                    Text("...")
                    HexDumpView(bytes: Array(beforePRP.suffix(16)), highlightRange: nil)
                }
            }

            Image(systemName: "arrow.down.circle")
                .font(.title2)

            GroupBox("After PRP (first/last 16 bytes)") {
                HStack {
                    HexDumpView(bytes: Array(afterPRP.prefix(16)), highlightRange: nil)
                    Text("...")
                    HexDumpView(bytes: Array(afterPRP.suffix(16)), highlightRange: nil)
                }
            }
        }
    }
}
```

#### 4.4. DigitsStageView
```swift
struct DigitsStageView: View {
    let stage: PipelineStage

    var body: some View {
        if case let .digits(digits) = stage.data {
            VStack(alignment: .leading, spacing: 12) {
                Text("Base-\(stage.config.base) Digits")
                    .font(.headline)

                LabeledContent("Total Digits", value: "\(digits.count)")
                LabeledContent("Range", value: "[0..\(stage.config.base - 1)]")

                // Показываем первые 50 + последние 10
                GroupBox("Digits (first 50 + last 10)") {
                    DigitsTableView(
                        digits: Array(digits.prefix(50)) + Array(digits.suffix(10)),
                        base: stage.config.base,
                        columns: 10,
                        highlightIndices: nil
                    )
                }
            }
        }
    }
}
```

#### 4.5. EnergiesStageView
```swift
struct EnergiesStageView: View {
    let stage: PipelineStage

    var body: some View {
        if case let .energies(energies) = stage.data {
            let min = energies.min() ?? 0
            let max = energies.max() ?? 0
            let mean = Double(energies.reduce(0, +)) / Double(energies.count)
            let sum = energies.reduce(0, +)

            VStack(alignment: .leading, spacing: 12) {
                Text("Energies [1..\(stage.config.base)]")
                    .font(.headline)

                // Статистика
                GroupBox("Statistics") {
                    LabeledContent("Count", value: "\(energies.count)")
                    LabeledContent("Min", value: "\(min)")
                    LabeledContent("Max", value: "\(max)")
                    LabeledContent("Mean", value: String(format: "%.2f", mean))
                    LabeledContent("Sum", value: "\(sum)")
                }

                // Гистограмма (простая)
                GroupBox("Distribution") {
                    // TODO: простая chart/гистограмма распределения энергий
                }

                // Первые/последние значения
                GroupBox("Values (first 50 + last 10)") {
                    DigitsTableView(
                        digits: Array(energies.prefix(50)) + Array(energies.suffix(10)),
                        base: stage.config.base + 1,
                        columns: 10,
                        highlightIndices: nil
                    )
                }
            }
        }
    }
}
```

#### 4.6. NormalizedStageView
```swift
struct NormalizedStageView: View {
    let stage: PipelineStage

    var body: some View {
        if case let .normalized(values) = stage.data {
            let min = values.min() ?? 0
            let max = values.max() ?? 0
            let mean = values.reduce(0, +) / Double(values.count)

            VStack(alignment: .leading, spacing: 12) {
                Text("Normalized Values [0..1]")
                    .font(.headline)

                GroupBox("Statistics") {
                    LabeledContent("Count", value: "\(values.count)")
                    LabeledContent("Min", value: String(format: "%.6f", min))
                    LabeledContent("Max", value: String(format: "%.6f", max))
                    LabeledContent("Mean", value: String(format: "%.6f", mean))
                }

                // Первые/последние значения
                GroupBox("Values (first 30 + last 10)") {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5)) {
                            ForEach(Array((Array(values.prefix(30)) + Array(values.suffix(10))).enumerated()), id: \.offset) { idx, val in
                                VStack {
                                    Text("[\(idx)]")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text(String(format: "%.4f", val))
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
```

#### 4.7. ReverseStageView
```swift
struct ReverseStageView: View {
    let stage: PipelineStage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reverse Process")
                .font(.headline)

            Text("Энергии → Digits → Bytes → PRP⁻¹ → Header/Data")
                .font(.caption)
                .foregroundColor(.secondary)

            if case let .bytes(bytes) = stage.data {
                GroupBox("Recovered Bytes") {
                    HexDumpView(bytes: bytes, highlightRange: nil)
                }
            }

            LabeledContent("Duration", value: String(format: "%.2f ms", stage.metrics.duration * 1000))
        }
    }
}
```

#### 4.8. RecoveredStageView
```swift
struct RecoveredStageView: View {
    let stage: PipelineStage
    let originalText: String

    var body: some View {
        if case let .text(recovered) = stage.data {
            let crcMatch = recovered == originalText

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Recovered Text")
                        .font(.headline)
                    Spacer()
                    if crcMatch {
                        Label("CRC Match", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Label("CRC Mismatch", systemImage: "xmark.circle.fill")
                            .foregroundColor(.red)
                    }
                }

                Text(recovered)
                    .font(.body)
                    .padding()
                    .background(crcMatch ? Color.green.opacity(0.1) : Color.red.opacity(0.1))
                    .cornerRadius(8)

                // Comparison
                if !crcMatch {
                    GroupBox("Comparison") {
                        LabeledContent("Original", value: originalText)
                        LabeledContent("Recovered", value: recovered)
                    }
                }
            }
        }
    }
}
```

_Оценка уверенности: ≈ 85 % (стандартные view, требуют тестирования с реальными данными)._

---

### 🎯 ФАЗА 5: Главная CapsulePipelineView (1 день)

**Цель:** Собрать всё вместе в интерактивное приложение.

#### 5.1. CapsulePipelineView
```swift
public struct CapsulePipelineView: View {
    @StateObject private var executor: PipelineExecutorViewModel
    @State private var inputText: String
    @State private var currentStageIndex: Int = 0
    @State private var isPlaying: Bool = false
    @State private var expandedStages: Set<UUID> = []

    public init(config: ConfigRoot.Capsule) {
        _executor = StateObject(wrappedValue: PipelineExecutorViewModel(config: config))
        _inputText = State(initialValue: config.pipelineExampleText)
    }

    public var body: some View {
        NavigationSplitView {
            // Боковая панель: управление + метрики
            VStack(alignment: .leading, spacing: 16) {
                // Input
                GroupBox("Input") {
                    TextEditor(text: $inputText)
                        .frame(height: 100)
                    Button("Execute Pipeline") {
                        Task {
                            await executor.execute(inputText)
                            currentStageIndex = 0
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }

                // Navigation
                if let snapshot = executor.snapshot {
                    StageNavigationView(
                        currentIndex: currentStageIndex,
                        totalStages: snapshot.stages.count,
                        isPlaying: isPlaying,
                        onPrevious: { currentStageIndex = max(0, currentStageIndex - 1) },
                        onNext: { currentStageIndex = min(snapshot.stages.count - 1, currentStageIndex + 1) },
                        onTogglePlay: {
                            isPlaying.toggle()
                            if isPlaying {
                                startAutoPlay()
                            }
                        },
                        onReset: { currentStageIndex = 0 }
                    )
                }

                // Metrics Panel
                if let snapshot = executor.snapshot {
                    MetricsPanelView(snapshot: snapshot)
                }

                Spacer()
            }
            .padding()
            .frame(width: 300)
        } detail: {
            // Главная область: текущий этап
            if let snapshot = executor.snapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(Array(snapshot.stages.enumerated()), id: \.element.id) { idx, stage in
                            let isExpanded = expandedStages.contains(stage.id)
                            let isCurrent = idx == currentStageIndex

                            VStack(alignment: .leading, spacing: 8) {
                                StageHeaderView(
                                    stage: stage,
                                    expanded: isExpanded,
                                    onToggle: {
                                        if isExpanded {
                                            expandedStages.remove(stage.id)
                                        } else {
                                            expandedStages.insert(stage.id)
                                        }
                                    }
                                )
                                .onTapGesture {
                                    currentStageIndex = idx
                                }

                                if isExpanded || isCurrent {
                                    stageDetailView(for: stage, snapshot: snapshot)
                                        .padding(.leading, 20)
                                }
                            }
                            .padding()
                            .background(isCurrent ? Color.blue.opacity(0.1) : Color.clear)
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(isCurrent ? Color.blue : Color.clear, lineWidth: 2)
                            )
                        }
                    }
                    .padding()
                }
            } else {
                VStack {
                    Image(systemName: "arrow.left")
                    Text("Enter text and execute pipeline")
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("Capsule Pipeline Visualizer")
    }

    @ViewBuilder
    private func stageDetailView(for stage: PipelineStage, snapshot: PipelineSnapshot) -> some View {
        switch stage.type {
        case .input:
            InputStageView(stage: stage)
        case .blockStructure:
            BlockStructureView(stage: stage)
        case .prpTransform:
            if let prevStage = snapshot.stages.first(where: { $0.type == .blockStructure }) {
                PRPStageView(
                    beforePRP: extractBytes(from: prevStage.data),
                    afterPRP: extractBytes(from: stage.data),
                    rounds: snapshot.config.feistelRounds
                )
            }
        case .capsuleBlock:
            if case let .bytes(bytes) = stage.data {
                CapsuleHexView(bytes: bytes)
            }
        case .baseConversion:
            DigitsStageView(stage: stage)
        case .printableString:
            PrintableStageView(stage: stage)
        case .energiesMapping:
            EnergiesStageView(stage: stage)
        case .normalization:
            NormalizedStageView(stage: stage)
        case .reverseProcess:
            ReverseStageView(stage: stage)
        case .recovered:
            RecoveredStageView(stage: stage, originalText: snapshot.inputText)
        }
    }

    private func startAutoPlay() {
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { timer in
            guard isPlaying else {
                timer.invalidate()
                return
            }
            if let snapshot = executor.snapshot, currentStageIndex < snapshot.stages.count - 1 {
                currentStageIndex += 1
            } else {
                isPlaying = false
                timer.invalidate()
            }
        }
    }
}
```

#### 5.2. PipelineExecutorViewModel
```swift
@MainActor
public class PipelineExecutorViewModel: ObservableObject {
    @Published public var snapshot: PipelineSnapshot?
    @Published public var isExecuting: Bool = false
    @Published public var error: Error?

    private let executor: PipelineExecutor

    public init(config: ConfigRoot.Capsule) {
        self.executor = PipelineExecutor(config: config)
    }

    public func execute(_ input: String) async {
        isExecuting = true
        error = nil

        do {
            let result = try await executor.executeRoundtrip(input)
            snapshot = result
            LoggingHub.emit(
                process: "ui.pipeline",
                level: .info,
                message: "Pipeline executed: \(result.stages.count) stages, \(result.totalDuration * 1000)ms"
            )
        } catch {
            self.error = error
            LoggingHub.emit(
                process: "ui.pipeline",
                level: .error,
                message: "Pipeline failed: \(error.localizedDescription)"
            )
        }

        isExecuting = false
    }
}
```

_Оценка уверенности: ≈ 85 % (SwiftUI coordination, требует тестирования)._

---

### 🎯 ФАЗА 6: MetricsPanelView и утилиты (0.5 дня)

#### 6.1. MetricsPanelView
```swift
struct MetricsPanelView: View {
    let snapshot: PipelineSnapshot

    var body: some View {
        GroupBox("Pipeline Metrics") {
            LabeledContent("Total Duration", value: String(format: "%.2f ms", snapshot.totalDuration * 1000))
            LabeledContent("Stages", value: "\(snapshot.stages.count)")
            LabeledContent("Success", value: snapshot.success ? "✓" : "✗")

            Divider()

            ForEach(snapshot.stages) { stage in
                HStack {
                    Text(stage.type.rawValue)
                        .font(.caption2)
                    Spacer()
                    Text(String(format: "%.2f ms", stage.metrics.duration * 1000))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}
```

#### 6.2. HexFormatter
```swift
public enum HexFormatter {
    public static func format(bytes: [UInt8], bytesPerRow: Int = 16) -> String {
        var result = ""
        for (offset, chunk) in bytes.chunked(into: bytesPerRow).enumerated() {
            let address = String(format: "%08X", offset * bytesPerRow)
            let hexPart = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            let asciiPart = chunk.map { byte in
                (32...126).contains(byte) ? String(Character(UnicodeScalar(byte))) : "."
            }.joined()
            result += "\(address) | \(hexPart.padding(toLength: bytesPerRow * 3, withPad: " ", startingAt: 0)) | \(asciiPart)\n"
        }
        return result
    }
}
```

#### 6.3. ColorScheme
```swift
public enum VisualizationColorScheme {
    public static func color(for stageType: PipelineStageType) -> Color {
        switch stageType {
        case .input: return .blue
        case .blockStructure: return .cyan
        case .prpTransform: return .purple
        case .capsuleBlock: return .indigo
        case .baseConversion: return .green
        case .printableString: return .mint
        case .energiesMapping: return .orange
        case .normalization: return .yellow
        case .reverseProcess: return .pink
        case .recovered: return .green
        }
    }

    public static func icon(for stageType: PipelineStageType) -> String {
        switch stageType {
        case .input: return "text.cursor"
        case .blockStructure: return "square.grid.3x3"
        case .prpTransform: return "lock.rotation"
        case .capsuleBlock: return "cube.fill"
        case .baseConversion: return "number.circle"
        case .printableString: return "text.quote"
        case .energiesMapping: return "bolt.fill"
        case .normalization: return "slider.horizontal.3"
        case .reverseProcess: return "arrow.uturn.backward"
        case .recovered: return "checkmark.circle.fill"
        }
    }
}
```

_Оценка уверенности: ≈ 95 % (вспомогательные утилиты)._

---

### 🎯 ФАЗА 7: Тестирование и отладка (0.5 дня)

#### 7.1. Ручное тестирование
- Запустить с `config.pipelineExampleText`
- Проверить каждый этап визуально
- Протестировать навигацию (prev/next/play)
- Протестировать разные входные строки:
  - Пустая строка
  - Очень короткая (1-2 символа)
  - Средняя (50-100 символов)
  - Близкая к max_input_bytes (256)
  - С юникодом (кириллица, эмодзи)

#### 7.2. Проверка метрик
- Сравнить суммарное время с CLI
- Проверить корректность размеров на каждом этапе
- Убедиться в совпадении CRC

#### 7.3. UI polish
- Проверить читаемость шрифтов
- Настроить spacing/padding
- Добавить tooltips для сложных параметров

_Оценка уверенности: ≈ 90 % (стандартное QA)._

---

## ФАЗА 8: Дополнительные улучшения (опционально)

### 8.1. Экспорт снапшотов
```swift
Button("Export Snapshot") {
    if let snapshot = executor.snapshot {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(snapshot) {
            // Сохранить в Artifacts/Snapshots/
        }
    }
}
```

### 8.2. Сравнение снапшотов
- Загрузить два снапшота
- Показать diff между этапами
- Полезно для тестирования изменений в PRP/алгоритмах

### 8.3. Простая Charts интеграция
```swift
import Charts

struct EnergyDistributionChart: View {
    let energies: [Int]

    var body: some View {
        let histogram = Dictionary(grouping: energies, by: { $0 })
            .mapValues { $0.count }

        Chart {
            ForEach(Array(histogram.keys.sorted()), id: \.self) { energy in
                BarMark(
                    x: .value("Energy", energy),
                    y: .value("Count", histogram[energy] ?? 0)
                )
            }
        }
        .frame(height: 200)
    }
}
```

### 8.4. Анимация переходов
- Добавить плавные transitions между этапами
- Анимировать изменения в hex-дампах
- Highlight измененных байтов при PRP

_Оценка уверенности: ≈ 80 % (nice-to-have features)._

---

## Интеграция с существующей инфраструктурой

### ConfigCenter
- Добавить в `ui` секцию конфига:
```yaml
ui:
  pipeline:
    enabled: true
    auto_expand_errors: true
    hex_bytes_per_row: 16
    digits_per_row: 10
    animation_speed: 1.5  # seconds per stage
```

### LoggingHub
Все действия визуализации логируются:
```swift
LoggingHub.emit(process: "ui.pipeline", level: .info, message: "Stage changed to \(newStage)")
LoggingHub.emit(process: "ui.pipeline", level: .debug, message: "Snapshot loaded: \(snapshot.id)")
```

### ProcessRegistry
Зарегистрированные процессы:
- `ui.pipeline` — главный процесс визуализации
- `ui.stage.input`, `ui.stage.block`, ... — детали этапов
- `ui.executor` — выполнение пайплайна

---

## Точки расширения для будущих фаз

### Когда добавится Router (Фаза 9+):
1. **Новый этап:** `routerForward` после `normalization`
   - Показывать входные энергии
   - Показывать граф маршрутизации (слои, узлы, рёбра)
   - Показывать выходные энергии после роутера

2. **Новый этап:** `routerBackward` перед `reverseProcess`
   - Показывать градиенты/обновления
   - Показывать метрики маршрутизации (энтропия, активные пути)

3. **Интеграция:** `CapsulePipelineView` + `RouterGraphView`
   - Split view: слева пайплайн капсюля, справа граф роутера
   - Синхронизация: при клике на этап energiesMapping — подсветить входной слой роутера

### Когда добавится обучение:
1. **Новая вкладка:** Training Progress
   - График loss/accuracy
   - Batch-by-batch визуализация
   - Checkpoint management

2. **Интеграция с визуализацией:**
   - Показывать, как меняются маршруты в роутере при обучении
   - Показывать влияние ошибок SNN на восстановление капсюля

---

## Дорожная карта (сроки)

| Фаза | Описание | Время | Статус |
|------|----------|-------|--------|
| 0 | Базовая инфраструктура | — | ✅ ГОТОВО |
| 1 | Модель данных пайплайна | 0.5 дня | 🎯 СЛЕДУЮЩАЯ |
| 2 | PipelineExecutor | 1 день | ⏳ |
| 3 | Базовые UI компоненты | 0.5 дня | ⏳ |
| 4 | Детальные view этапов | 1.5 дня | ⏳ |
| 5 | Главная CapsulePipelineView | 1 день | ⏳ |
| 6 | Метрики и утилиты | 0.5 дня | ⏳ |
| 7 | Тестирование и отладка | 0.5 дня | ⏳ |
| 8 | Дополнительные улучшения | опционально | 💡 |

**Общее время:** ≈ 5.5 дня для полной визуализации текущего CapsuleCore.

---

## Риски и митигация

| Риск | Вероятность | Митигация |
|------|-------------|-----------|
| SwiftUI performance с большими hex-дампами | 60% | Виртуализация (LazyVStack), ограничение показа первых/последних N байт |
| Сложность синхронизации async executor + UI | 40% | Использовать @MainActor, ObservableObject, четкое разделение слоёв |
| Переусложнение UI на ранних этапах | 50% | Начать с минимального MVP (фазы 1-5), добавлять улучшения инкрементально |
| Несовместимость с будущим роутером | 30% | Спроектировать расширяемую модель (enum StageType легко расширяется) |

---

## Критерии успеха

✅ Визуализация показывает **все 10 этапов** пайплайна
✅ Можно **интерактивно** вводить текст и наблюдать трансформации
✅ Каждый этап показывает **детальные данные** (hex, digits, energies)
✅ **Метрики** корректны и совпадают с CLI
✅ **CRC проверка** работает и визуализируется
✅ UI **расширяема** для будущей интеграции с роутером
✅ Логирование через **LoggingHub** работает
✅ Все данные **реальные** (не mock)

---

## Примечания

- Вся визуализация строится на **реальных данных** из CapsuleCore, без mock-данных.
- Архитектура позволяет **инкрементальное развитие**: после каждой фазы визуализации можно вернуться к бэкенду, добавить новые фичи, затем снова расширить визуализацию.
- **Fail-fast** политика сохраняется: ошибки на любом этапе пайплайна подсвечиваются в UI, но не скрываются.
- План согласован с общей архитектурой из `plan_reversible_text_capsule_swift_macos.md` и `plan_snn_router_swift_macos.md`.

_С определённой долей вероятности ≈ 90 %: следование этому плану даст наглядную, расширяемую визуализацию, которая станет ключевым инструментом для понимания и отладки всей системы._
