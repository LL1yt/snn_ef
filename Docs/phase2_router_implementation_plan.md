# План реализации EnergeticRouter Core v1 (CPU)

**Статус**: Готов к реализации
**Дата**: 2025-10-30
**Предыдущая фаза**: ✅ ReversibleCapsule v1 (CPU) + визуализация
**Текущая фаза**: § 2. EnergeticRouter Core v1 (CPU) из `phase2_execution_plan.md`

---

## Контекст и зависимости

### ✅ Готовая база из фазы 1:
- **CapsuleCore**: полная реализация encode/decode, PRP (Feistel), EnergyMapper
- **Инфраструктура**: ConfigCenter, LoggingHub, ProcessRegistry, Diagnostics, PipelineSnapshot
- **Визуализация**: CapsuleUI с отображением snapshot и метрик
- **Конфигурация**: `baseline.yaml` с полными секциями `router` и `capsule`

### 📦 Что нужно реализовать:
EnergeticCore с полным функционалом роутера на CPU:
- Структуры графа (CSR-формат)
- Forward-pass с softmax и распределением энергии
- Loss функции и backpropagation
- Метрики и логирование

---

## § 2.1 Структуры графа

### Задачи:

#### 2.1.1 Базовые типы данных
**Файл**: `Sources/EnergeticCore/GraphTypes.swift`

Реализовать:
```swift
// Идентификатор узла
public struct NodeID: Hashable, Sendable {
    public let layer: Int
    public let index: Int
}

// Конфигурация слоя
public struct LayerConfig: Sendable {
    public let nodeCount: Int
    public let localNeighbors: Int
    public let jumpNeighbors: Int
}

// Ребро графа
public struct Edge: Sendable {
    public let src: NodeID
    public let dst: NodeID
    public var weight: Float  // энергетический вес
}

// Конфигурация графа из ConfigCenter
public struct GraphConfig: Sendable {
    public let layers: Int
    public let nodesPerLayer: Int
    public let localNeighbors: Int
    public let jumpNeighbors: Int
}
```

**Тесты**: `Tests/EnergeticCoreTests/GraphTypesTests.swift`
- Проверка Hashable для NodeID
- Создание LayerConfig из конфига
- Валидация параметров

---

#### 2.1.2 CSR-представление графа
**Файл**: `Sources/EnergeticCore/Graph.swift`

Реализовать:
```swift
// Граф в формате CSR (Compressed Sparse Row)
public struct Graph: Sendable {
    // CSR-структура
    public let rowPtr: [Int]        // [numNodes+1] - указатели на начало рёбер
    public let colIdx: [Int]        // [numEdges] - индексы целевых узлов
    public var weights: [Float]     // [numEdges] - веса рёбер

    // Метаданные
    public let config: GraphConfig
    public let numNodes: Int
    public let numEdges: Int

    // Позиционные признаки узлов
    public let nodePositions: [SIMD2<Float>]  // (x, y) для каждого узла

    // Вспомогательные методы
    public func neighbors(of node: NodeID) -> Range<Int>
    public func edgeWeight(from src: NodeID, to dst: NodeID) -> Float?
    public mutating func setWeight(from src: NodeID, to dst: NodeID, weight: Float)
}
```

**Тесты**: `Tests/EnergeticCoreTests/GraphTests.swift`
- Создание пустого графа
- Навигация по рёбрам через CSR
- Проверка корректности индексов

---

#### 2.1.3 Генератор решётки
**Файл**: `Sources/EnergeticCore/GraphBuilder.swift`

Реализовать:
```swift
public struct GraphBuilder {
    // Создаёт граф-решётку из конфига
    public static func buildLattice(config: GraphConfig) throws -> Graph

    // Генерирует локальные соседи (8 направлений в слое j+1)
    private static func generateLocalEdges(...)

    // Генерирует jump-соседи (прыжки через слой)
    private static func generateJumpEdges(...)

    // Инициализирует позиционные эмбеддинги
    private static func initPositions(...)
}
```

**Логика**:
- Слой 0: входные узлы (без входящих рёбер)
- Слои 1..L-2: узлы с `local` (в слое j+1) + `jump` (в слое j+2) соседями
- Слой L-1: выходные узлы
- Позиции: `x = layer / (layers-1)`, `y = index / nodesPerLayer`

**Тесты**: `Tests/EnergeticCoreTests/GraphBuilderTests.swift`
- Маленький граф (3 слоя × 4 узла)
- Проверка количества рёбер
- Валидация соседей (не выходят за границы)
- Проверка симметричности локальных связей

---

## § 2.2 Forward-pass CPU

### Задачи:

#### 2.2.1 Параметры роутера
**Файл**: `Sources/EnergeticCore/RouterParams.swift`

Реализовать:
```swift
public struct RouterParams: Sendable {
    // Attention-параметры (общие для всех узлов)
    public var Q: [Float]  // [numNodes, d] - Query проекции
    public var K: [Float]  // [numNodes, d] - Key проекции
    public var bias: [Float]  // [numEdges] - биасы для рёбер

    // Гиперпараметры
    public let hiddenDim: Int
    public let tau: Float       // температура softmax
    public let alpha: Float     // коэффициент распределения энергии
    public let topK: Int        // количество активных рёбер

    // Инициализация из конфига
    public static func initialize(graph: Graph, config: RouterConfig) -> RouterParams
}
```

**Инициализация**:
- Q, K: Xavier/He initialization
- bias: нули или малый шум
- Параметры из `baseline.yaml:router`

**Тесты**: `Tests/EnergeticCoreTests/RouterParamsTests.swift`
- Проверка размерностей
- Инициализация не NaN/Inf
- Загрузка из конфига

---

#### 2.2.2 Forward-pass ядро (CPU)
**Файл**: `Sources/EnergeticCore/ForwardPassCPU.swift`

Реализовать:
```swift
// Входные данные для forward-pass
public struct ForwardInput: Sendable {
    public let nodeEnergies: [Float]  // [numNodes] - энергия в каждом узле
    public let nodeActive: [Bool]     // [numNodes] - активен ли узел
}

// Результат forward-pass
public struct ForwardOutput: Sendable {
    public let nextEnergies: [Float]  // [numNodes] - энергии следующего слоя
    public let edgePi: [Float]        // [numEdges] - вероятности π_jk для каждого ребра
    public let edgeFlow: [Float]      // [numEdges] - потоки энергии α·e·π_jk
    public let metrics: ForwardMetrics
}

public struct ForwardMetrics: Sendable {
    public let totalEnergy: Float
    public let activeNodes: Int
    public let maxEdgeFlow: Float
    public let avgEntropy: Float
}

public final class ForwardPassCPU: @unchecked Sendable {
    private let graph: Graph
    private let params: RouterParams

    public func forward(input: ForwardInput) throws -> ForwardOutput

    // Шаги forward-pass:
    // 1. Вычисление логитов: logit_jk = dot(Q[j], K[k]) + bias[edge_jk]
    // 2. Softmax по рёбрам каждого узла (с температурой τ)
    // 3. Top-K отбор (опционально)
    // 4. Распределение энергии: flow_jk = α · energy[j] · π_jk
    // 5. Аккумуляция в целевые узлы
}
```

**Использование Accelerate**:
- `vDSP_dotpr` для dot-products
- `vDSP_vsmul` для масштабирования
- Custom softmax с температурой

**Тесты**: `Tests/EnergeticCoreTests/ForwardPassCPUTests.swift`
- Маленький граф (2 слоя × 3 узла)
- Проверка сохранения энергии: `sum(output) ≈ α · sum(input)`
- Проверка softmax: `sum(π_jk for k in neighbors(j)) ≈ 1.0`
- Проверка отсутствия NaN/Inf
- Top-K: только K рёбер с ненулевым потоком

---

#### 2.2.3 Метрики forward-pass
**Файл**: `Sources/EnergeticCore/Metrics.swift`

Реализовать:
```swift
public struct RouterMetrics: Sendable {
    public let stepIndex: Int
    public let timestamp: Date

    // Forward метрики
    public let totalEnergy: Float
    public let activeNodes: Int
    public let activeEdges: Int
    public let avgEntropy: Float
    public let maxEdgeFlow: Float

    // Backward метрики (добавим в 2.3)
    public var loss: Float?
    public var gradNorm: Float?

    // Экспорт в JSON
    public func toJSON() throws -> Data
}

public actor MetricsCollector {
    private var metrics: [RouterMetrics] = []

    public func record(_ metric: RouterMetrics)
    public func export(to path: String) throws
    public func latest() -> RouterMetrics?
}
```

**Тесты**: `Tests/EnergeticCoreTests/MetricsTests.swift`
- Запись и извлечение метрик
- JSON сериализация
- Thread-safety (actor)

---

## § 2.3 Loss & backprop (baseline)

### Задачи:

#### 2.3.1 Loss-модули
**Файл**: `Sources/EnergeticCore/Loss.swift`

Реализовать:
```swift
public protocol LossFunction: Sendable {
    func compute(predicted: [Float], target: [Float]) -> Float
    func gradient(predicted: [Float], target: [Float]) -> [Float]
}

// MSE Loss (для регрессии/addition task)
public struct MSELoss: LossFunction {
    public func compute(predicted: [Float], target: [Float]) -> Float
    public func gradient(predicted: [Float], target: [Float]) -> [Float]
}

// Cross-Entropy Loss (для классификации)
public struct CrossEntropyLoss: LossFunction {
    public func compute(predicted: [Float], target: [Float]) -> Float
    public func gradient(predicted: [Float], target: [Float]) -> [Float]
}

// Энтропийная регуляризация
public struct EntropyRegularization {
    public let lambda: Float

    public func compute(edgePi: [Float], graph: Graph) -> Float
    public func gradient(edgePi: [Float], graph: Graph) -> [Float]
}
```

**Тесты**: `Tests/EnergeticCoreTests/LossTests.swift`
- MSE: известные входы → известный loss
- CE: проверка численной стабильности
- Entropy: максимум при uniform, минимум при peaked
- Градиенты: численная проверка (finite differences)

---

#### 2.3.2 Backward-pass (градиенты softmax)
**Файл**: `Sources/EnergeticCore/BackwardPassCPU.swift`

Реализовать:
```swift
public struct BackwardInput: Sendable {
    public let outputGrad: [Float]     // [numNodes] - градиент по выходу
    public let forwardOutput: ForwardOutput  // сохранённые значения из forward
}

public struct BackwardOutput: Sendable {
    public let gradQ: [Float]          // [numNodes, d]
    public let gradK: [Float]          // [numNodes, d]
    public let gradBias: [Float]       // [numEdges]
    public let gradNorm: Float         // норма градиента
}

public final class BackwardPassCPU: @unchecked Sendable {
    private let graph: Graph
    private let params: RouterParams

    public func backward(input: BackwardInput) throws -> BackwardOutput

    // Шаги backward-pass:
    // 1. Градиент по edgeFlow → grad_energy
    // 2. Градиент по π_jk (softmax backward)
    // 3. Градиент по logit_jk
    // 4. Градиенты по Q, K через chain rule
}
```

**Тесты**: `Tests/EnergeticCoreTests/BackwardPassCPUTests.swift`
- Численная проверка градиентов (finite differences)
- Градиент softmax: известные формулы
- Проверка chain rule для Q, K

---

#### 2.3.3 Adam оптимизатор
**Файл**: `Sources/EnergeticCore/Optimizer.swift`

Реализовать:
```swift
public struct AdamConfig: Sendable {
    public let lr: Float
    public let beta1: Float
    public let beta2: Float
    public let eps: Float
}

public actor AdamOptimizer {
    private var m: [Float]  // первый момент
    private var v: [Float]  // второй момент
    private var t: Int = 0  // номер шага

    private let config: AdamConfig

    public func step(params: inout [Float], grads: [Float])
    public func reset()
}
```

**Тесты**: `Tests/EnergeticCoreTests/OptimizerTests.swift`
- Корректность обновления параметров
- Проверка моментов m, v
- Сброс состояния

---

## § 2.4 Logging/metrics

### Задачи:

#### 2.4.1 Интеграция с LoggingHub
**Файл**: `Sources/EnergeticCore/RouterLogger.swift`

Реализовать:
```swift
public struct RouterLogger {
    private let loggingHub: LoggingHub
    private let processID: String

    public func logForward(
        stepIndex: Int,
        input: ForwardInput,
        output: ForwardOutput
    )

    public func logBackward(
        stepIndex: Int,
        loss: Float,
        gradNorm: Float
    )

    public func logCheckpoint(
        stepIndex: Int,
        checkpointPath: String
    )
}
```

**События** (из `baseline.yaml:process_registry`):
- `router.forward`: метрики forward-pass
- `router.backward`: loss, grad_norm
- `router.checkpoint`: путь к сохранённым весам

**Тесты**: `Tests/EnergeticCoreTests/RouterLoggerTests.swift`
- Проверка отправки событий в LoggingHub
- Корректность уровней логирования
- Формат JSON-полей

---

#### 2.4.2 Расширение PipelineSnapshot
**Файл**: `Sources/SharedInfrastructure/PipelineSnapshot.swift` (обновить)

Добавить поля:
```swift
// Энергетические показатели роутера
public var routerTotalEnergy: Float?
public var routerActiveNodes: Int?
public var routerActiveEdges: Int?
public var routerMaxEdgeFlow: Float?
public var routerLoss: Float?

// Размеры графа
public var routerLayers: Int?
public var routerNodesPerLayer: Int?
public var routerNumEdges: Int?
```

**Тесты**: `Tests/SharedInfrastructureTests/PipelineSnapshotTests.swift` (обновить)
- Экспорт/импорт с новыми полями
- JSON-валидация

---

#### 2.4.3 Метрики в CSV/JSON
**Файл**: `Sources/EnergeticCore/MetricsExporter.swift`

Реализовать:
```swift
public struct MetricsExporter {
    public func exportCSV(metrics: [RouterMetrics], to path: String) throws
    public func exportJSON(metrics: [RouterMetrics], to path: String) throws
}
```

**Формат CSV**:
```
step,timestamp,total_energy,active_nodes,active_edges,avg_entropy,loss,grad_norm
0,2025-10-30T...,1000.0,512,4096,0.85,0.123,0.045
...
```

**Тесты**: `Tests/EnergeticCoreTests/MetricsExporterTests.swift`
- Экспорт в CSV
- Экспорт в JSON
- Чтение и парсинг

---

## Порядок реализации (последовательность)

### Этап 1: Структуры данных (§ 2.1)
**Время**: ~2-3 часа
1. `GraphTypes.swift` - базовые типы
2. `Graph.swift` - CSR-представление
3. `GraphBuilder.swift` - генератор решётки
4. Тесты для всех трёх файлов

**Критерий готовности**:
- ✅ `swift test --filter EnergeticCoreTests.GraphTests` проходит
- ✅ Можно создать граф 10×1024 из `baseline.yaml`

---

### Этап 2: Forward-pass (§ 2.2)
**Время**: ~3-4 часа
1. `RouterParams.swift` - параметры и инициализация
2. `ForwardPassCPU.swift` - ядро forward-pass
3. `Metrics.swift` - сбор метрик
4. Тесты для всех трёх компонентов

**Критерий готовности**:
- ✅ Forward-pass на маленьком графе сохраняет энергию
- ✅ Softmax корректен, нет NaN/Inf
- ✅ Top-K работает

---

### Этап 3: Loss & Backprop (§ 2.3)
**Время**: ~3-4 часа
1. `Loss.swift` - loss-функции
2. `BackwardPassCPU.swift` - backward-pass
3. `Optimizer.swift` - Adam
4. Тесты: численная проверка градиентов

**Критерий готовности**:
- ✅ Градиенты корректны (finite differences)
- ✅ Adam обновляет параметры
- ✅ Loss уменьшается на игрушечной задаче

---

### Этап 4: Logging & Integration (§ 2.4)
**Время**: ~2-3 часа
1. `RouterLogger.swift` - логирование
2. Обновить `PipelineSnapshot.swift`
3. `MetricsExporter.swift` - экспорт метрик
4. Интеграционные тесты

**Критерий готовности**:
- ✅ События логируются через LoggingHub
- ✅ PipelineSnapshot содержит поля роутера
- ✅ Метрики экспортируются в CSV/JSON

---

## Итоговые критерии завершения фазы 2 (§ 2)

### ✅ Функциональность:
- [ ] Граф-решётка генерируется из `baseline.yaml`
- [ ] Forward-pass работает на CPU (Accelerate/vDSP)
- [ ] Backward-pass корректен (численная проверка)
- [ ] Adam оптимизатор обновляет параметры
- [ ] Loss функции (MSE, CE) реализованы

### ✅ Тестирование:
- [ ] Все unit-тесты проходят: `swift test --filter EnergeticCoreTests`
- [ ] Численная проверка градиентов (finite differences)
- [ ] Тест сохранения энергии
- [ ] Тест softmax-нормализации

### ✅ Логирование:
- [ ] События `router.forward`, `router.backward` логируются
- [ ] Метрики записываются в `MetricsCollector`
- [ ] Экспорт в CSV/JSON работает

### ✅ Интеграция:
- [ ] `PipelineSnapshot` содержит поля роутера
- [ ] ConfigCenter читает секцию `router` из `baseline.yaml`
- [ ] Все зависимости (SharedInfrastructure) подключены

---

## Дальнейшие шаги (фаза 3)

После завершения § 2 переходим к:
- **§ 3. Интеграция Capsule ↔ Router**: CapsuleBridge, end-to-end тесты
- **§ 4. Метрики и визуализация**: обновление EnergeticUI
- **§ 5. Тестирование и качество**: бенчмарки, производительность

---

## Риски и смягчение

| Риск | Вероятность | Смягчение |
|------|-------------|-----------|
| Численная нестабильность softmax | Средняя | Log-sum-exp trick, температура τ ≥ 1.0 |
| Производительность на CPU для 10×1024 | Средняя | Accelerate/vDSP, профилирование, sparse ops |
| Ошибки в градиентах | Низкая | Численная проверка (finite differences) |
| Интеграция с LoggingHub | Низкая | Инфраструктура уже протестирована |

---

## Финальный чек-лист

Перед переходом к фазе 3:
- [ ] Код проверен через `swift build -c release`
- [ ] Все тесты проходят: `swift test`
- [ ] Документация обновлена (README_arch.md, config_center_schema.md)
- [ ] Коммит и push в `claude/reversible-capsule-v1-cpu-011CUe2P8CuRTMjvbPk3RBky`
- [ ] Plan review: все задачи § 2 завершены

---

**Готовы начать реализацию! 🚀**
