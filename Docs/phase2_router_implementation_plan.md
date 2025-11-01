# План реализации EnergeticRouter SNN (CPU-first)

**Статус**: готов к реализации  
**Дата**: 2025-10-30  
**Фаза**: §2 EnergeticRouter (обновлено под спайковую схему)  
**Фолбэки**: отсутствуют, предыдущая softmax/графовая модель исключена.

---

## Контекст

- ReversibleCapsule, SharedInfrastructure, ConfigCenter и UI из фазы 1 готовы.
- Новая цель: реализовать спайковый EnergeticRouter, где движением энергии управляет единый SNN-элемент, работающий во времени. Потоки двигаются по сетке, спайки задают прыжки вперёд.
- CPU-версия (Accelerate + Swift Concurrency) — эталон для тестов; дизайн сразу подготовлен к MPS/Metal.

---

## §2.1 TemporalGrid и конфигурация

### 2.1.1 RouterConfig обновление
- **Файл**: `Sources/EnergeticCore/RouterConfig.swift`
- Добавить секцию `snn`:
  - `decay`, `threshold`, `resetValue`, `deltaXRange (ClosedRange<Int>)`, `deltaYRange (ClosedRange<Int>)`, `surrogate`, `dt`.
  - `energyFloor`, `alpha`.
- Валидация: `deltaXRange.lowerBound >= 1`, `deltaYRange.contains(0)`, `threshold ∈ (0, 1]`, `decay ∈ (0,1)`.
- **Тесты**: `RouterConfigTests` — парсинг YAML, некорректные ranges выдают `ConfigError`.

### 2.1.2 TemporalGrid
- **Файл**: `Sources/EnergeticCore/TemporalGrid.swift`
- Поля: `layers`, `nodesPerLayer`.
- Методы:
  - `advanceForward(x:) -> Int` (x+1, clamp к `layers`).
  - `wrapY(_:) -> Int` (modulo).
  - `isOutputLayer(_:)`.
- **Тесты**: `TemporalGridTests` — шаг за шагом, wrap-around, выход за границу X.

---

## §2.2 SpikingKernel

### 2.2.1 Мембранная динамика
- **Файл**: `Sources/EnergeticCore/SpikingKernel.swift`
- Хранит параметры и веса (общие для всех узлов/слоёв):
  - `W_in: [Float]` (4×H), `b_in`, `W_energy`, `b_energy`, `W_delta`, `b_delta`.
  - `threshold`, `decay`, `resetValue`.
- Общее число параметров контролируется `snn.parameter_count` (базовый профиль — 512); ConfigCenter гарантирует минимум и позволяет экспериментировать.
- `forward(batchInputs: [SIMD4<Float>], membrane: inout [Float]) -> SpikingOutputBatch`.
- Выход:
  - `energyNext: [Float]`,
  - `deltaXY: [SIMD2<Float>]` (float смещения),
  - `spikes: [Bool]`,
  - обновлённый `membrane`.
- Использовать Accelerate (`vDSP_mmul`) или ручной SIMD при малых H.
- **Тесты**: `SpikingKernelTests` — проверка мембранного накопления, сброс после спайка, отсутствие NaN, сравнение одиночного/батчевого режима.

### 2.2.2 Surrogate gradients
- **Файл**: `Sources/EnergeticCore/SurrogateActivation.swift`
- Реализовать варианты (`fast_sigmoid`, `tanh_clip`).
- Предоставить `forward(x)` и `backward(x)` для обучения.
- **Тесты**: `SurrogateActivationTests` — корректность значений и производных, устойчивость.

---

## §2.3 SpikeRouter и EnergyFlow

### 2.3.1 EnergyPacket & State
- **Файл**: `Sources/EnergeticCore/EnergyPacket.swift`
- Поля: `streamID`, `x`, `y`, `energy`, `time`.
- Вспомогательные функции:
  - `asNormalizedInput(grid:, maxEnergy:, maxTime:) -> SIMD4<Float>`.
  - `isAlive(minEnergy:)`.
- **Тесты**: `EnergyPacketTests` — нормализация, проверка порога энергии.

### 2.3.2 SpikeRouter
- **Файл**: `Sources/EnergeticCore/SpikeRouter.swift`
- Состав:
  - ссылки на `TemporalGrid`, `SpikingKernel`, `RouterConfig`.
  - `route(packets:, membraneState:) -> RouteResult`.
- Алгоритм:
  1. сформировать входы (`x_norm`, `y_norm`, `energy_norm`, `t_norm`);
  2. вызвать `SpikingKernel`;
  3. рассчитать новое `x`:
     - базовый шаг: `x_next = x + 1`;
     - при спайке: `x_next += clamp(round(deltaX), deltaXRange)` и ограничить по `layers`;
  4. `y_next = wrap(y + round(deltaY), nodesPerLayer)`;
  5. энергия: `alpha * max(energy_next, 0)`; если меньше `energyFloor` — поток гаснет;
  6. формировать новые пакеты/завершённые потоки.
- **Тесты**: `SpikeRouterTests` — базовое движение (без спайков), прыжок через спайк, wrap по Y, сброс мембраны.

### 2.3.3 EnergyFlowSimulator
- **Файл**: `Sources/EnergeticCore/EnergyFlowSimulator.swift`
- Отвечает за многотактное исполнение:
  - `step()` — вызывает `SpikeRouter`, обновляет активные/завершённые потоки;
  - `run(until:)` — выполняет заданное число шагов или пока нет активных пакетов;
  - `collectOutputs()` — `streamID → энергия`.
- **Тесты**: `EnergyFlowSimulatorTests` — длинный маршрут, множественные потоки, проверка суммарной энергии.

---

## §2.4 Обучение

### 2.4.1 Лоссы
- **Файл**: `Sources/EnergeticCore/SNNLosses.swift`
- Реализовать:
  - `energyBalanceLoss(inputs:, outputs:, alpha:)`;
  - `jumpPenalty(deltaX:, deltaY:, range:)`;
  - `spikeRateLoss(actual:, target:)` (регулируем плотность спайков).
- Возвращают значения и градиенты (для CPU тестов).
- **Тесты**: `SNNLossesTests` — аналитические кейсы, finite differences.

### 2.4.2 TrainingLoop
- **Файл**: `Sources/EnergeticCore/TrainingLoop.swift`
- Поддержка surrogate backprop:
  - сохранение `membrane` истории при необходимости;
  - применение `SurrogateActivation.backward`.
- Adam-оптимизатор (расширить существующий `Optimizer.swift`).
- Логирование метрик (`spike_rate`, `energy_balance`, `avg_delta`).
- **Тесты**: `TrainingLoopTests` — игрушечный пример, проверка уменьшения лосса, стабилизация спайк-рейта.

---

## §2.5 Метрики и логирование

### RouterMetrics
- **Файл**: `Sources/EnergeticCore/RouterMetrics.swift`
- Поля: `step`, `activeStreams`, `spikeCount`, `meanDeltaX`, `meanDeltaY`, `energyError`, `spikeRate`.
- Методы сериализации в JSON/CSV.
- **Тесты**: `RouterMetricsTests` — агрегация, сериализация, edge cases.

### RouterLogger
- **Файл**: `Sources/EnergeticCore/RouterLogger.swift`
- События:
  - `router.step` — суммарные метрики шага;
  - `router.spike` — подробности отдельного спайка (`stream_id`, `Δx`, `Δy`, энергия);
  - `router.output` — финальный вклад в выходной буфер.
- Интеграция с `ProcessRegistry` (актуализировать `baseline.yaml`).
- **Тесты**: мок LoggingHub, проверки payload.

### PipelineSnapshot
- **Файл**: `Sources/SharedInfrastructure/PipelineSnapshot.swift`
- Новые поля: `snnDecay`, `snnThreshold`, `deltaXRange`, `deltaYRange`, `activeStreams`, `spikeTimeline`.
- Headless экспорт → `Artifacts/pipeline_snapshot.json`.
- **Тесты**: `PipelineSnapshotTests` — JSON round-trip.

---

## Порядок реализации

1. ConfigCenter и TemporalGrid (валидаторы диапазонов).
2. SpikingKernel + surrogate активации (CPU реализация).
3. SpikeRouter и EnergyFlowSimulator (потоковая динамика).
4. Обучение: лоссы, TrainingLoop, Adam.
5. Метрики, логирование, snapshot, интеграция с UI/headless.

Каждый этап закрывается `swift test --filter EnergeticCoreTests.<Suite>` и проверкой новых конфигурационных ограничений.

---

## Контрольные проверки

- **Энергия**: `|Σ выходов − α·Σ входов| < ε`.
- **Пределы**: `Δx` всегда ≥ 1 и ≤ `deltaXRange.upperBound`; `Δy` после wrap попадает в `[0, nodesPerLayer)`.
- **Spikes**: при `threshold → 1` спайки редки; при низком пороге — частые. Метрики отражают это.
- **Fail-fast**: отрицательная энергия, NaN в мембране, выход за границу `layers` — немедленный `preconditionFailure`.
- **Headless**: CLI в headless режиме повторяет ту же трассу, что и UI, и пишет в snapshot.
- **GPU-перспектива**: batched интерфейсы `SpikingKernel`/`SpikeRouter` пригодны для портирования на MPS (матрицы входов, вектор мембран).

---

## Результат

После завершения:
- EnergeticRouter реализует спайковую модель без упора на предвычисленные рёбра;
- Capsule ↔ Router связь готова (потоки формируются из капсулы, результаты возвращаются в BridgeSNN);
- Документация и конфиги полностью соответствуют новой архитектуре; альтернативных реализаций не предусмотрено.
