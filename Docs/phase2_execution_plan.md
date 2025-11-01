# Фаза 2 · Реализация ядра капсюля и SNN-роутера (Swift · Metal · Apple Silicon)

_С определённой долей вероятности ≈ 80 %_: шаги ниже позволят перейти от инфраструктурного каркаса (фаза 1) к работающему прототипу «капсюль ⟷ энергорегистратор ⟷ роутер» с базовыми метриками и визуализацией. План разбит на модули с обязательными тестами, логированием и интеграционными проверками.

---

## 0. Контекст и готовая база

- Инфраструктура из фазы 1: ConfigCenter, LoggingHub, ProcessRegistry, Diagnostics, CLI/SwiftUI заглушки, PipelineSnapshotExporter. (Docs/phase1_execution_plan.md)
- Общие планы: `Docs/plan_reversible_text_capsule_swift_macos.md`, `Docs/plan_snn_router_swift_macos.md`.
- Цель фазы 2: реализовать «капсюль → энергии» и «энергии → роутер» с CPU-бэкендом (Swift + Accelerate), подключить метрики/визуализацию и обеспечить end-to-end проверку.

---

## 1. Реализация ReversibleCapsule v1 (CPU)

### 1.1 Архитектура данных

- [ ] Структуры `CapsuleHeader`, `CapsuleBlock`, `CapsuleEncoder`/`Decoder`.
- [ ] Конфигурационные поля: `maxInputBytes`, `blockSize`, `alphabet`, `base`, PRP-параметры.

### 1.2 PRP-ядро (Feistel)

- [ ] Реализация Feistel-сети (10 раундов, Blake2s/HMAC-SHA256 через CryptoKit) в `CapsuleCore`.
- [ ] Юнит-тесты: 1000 случайных строк → encode → decode → исходное совпадает.
- [ ] Negative-тесты: CRC mismatch, длина > `maxInputBytes` → ошибка.

### 1.3 Отображение bytes ↔ digits ↔ printable

- [ ] Конвертер `ByteDigitsConverter` (256 → base-B) с длинной арифметикой.
- [ ] Конвертер `DigitStringConverter` (digits ↔ printable string по алфавиту).
- [ ] Тесты: граничные значения, разные базы (B=64/85/100), случайные данные.

### 1.4 Энергетический интерфейс

- [ ] `EnergyMapper` (digits ↔ energies 1..B, нормализация `E/(B+1)`).
- [ ] Тесты: `makeEnergies`/`recoverCapsule` + CRC-восстановление, шум ±1.
- [ ] Логирование: `capsule.encode`, `capsule.decode` через LoggingHub.

### 1.5 CLI/Tests

- [ ] `capsule-cli encode`/`decode` команды (или подкоманды) для проверки вручную.
- [ ] Автотест `swift test --filter CapsuleCoreTests`: round-trip, ошибки.

---

## 2. EnergeticRouter Core v1 (CPU)

### 2.1 Структуры графа

- [ ] `Graph` (CSR), `Node`, `Edge`, `LayerConfig`.
- [ ] Генератор решётки (локальные + jump-соседи) из конфигурации.

### 2.2 Forward-pass CPU

- [ ] Расчёт логитов (dot(q_j, k_k)) + softmax (Accelerate/vDSP) по рёбрам узла.
- [ ] Распределение энергии `α·e·π_{jk}`, учёт ограничений `Δx`, `Δy`, нормализация.
- [ ] Метрики: суммарная энергия, активные узлы, top-K использование.
- [ ] Тесты: маленький граф (2×3 слоёв) с известным результатом; защита от NaN.

### 2.3 Loss & backprop (baseline)

- [ ] Loss-модули (MSE/CE), градиенты softmax, Adam-оптимизатор.
- [ ] Тест: численная проверка градиентов (finite differences).

### 2.4 Logging/metrics

- [ ] LoggingHub события: `router.step`, `router.spike`, `router.output`.
- [ ] Метрики → `Metrics.swift` (CSV/JSON) для обучения/валидации.
- [ ] PipelineSnapshot: добавить энергетические показатели (сумма, максимум).

---

## 3. Интеграция Capsule ↔ Router

### 3.1 BridgeSNN

- [ ] Реализация адаптера `CapsuleBridge` (подготовка батча энергий, обратное восстановление).
- [ ] Тест: encode строк → energies → router → recover → строка.

### 3.2 CLI End-to-End

- [ ] `capsule-cli` команда `demo` (encode → energies → decode) с логами.
- [ ] `energetic-cli` команда `demo` (прогон по фиксированному графу, лог метрик).
- [ ] Интеграционный тест через `Process.run` (env `SNN_CONFIG_PATH`).

### 3.3 Pipeline Snapshot & UI

- [ ] Расширить `PipelineSnapshot` полями: энергия, длина пути, размеры графа.
- [ ] В `CapsuleUI`/`EnergeticUI`: отобразить новые поля, кнопка “Refresh metrics”.
- [ ] Тест: snapshot export → UI просматривает значения.

---

## 4. Метрики и визуализация (SwiftUI/Metal)

### 4.1 CapsuleUI

- [ ] Показывать актуальный snapshot (base, block size, пример текста, CRC статус).
- [ ] Добавить график (SwiftUI Charts) распределения энергий (если включено).
- [ ] Привязать кнопки Export/Reload к LoggingHub/metrics.

### 4.2 EnergeticUI

- [ ] Заглушка визуализации маршрутов (GraphView) → пока CPU-данные.
- [ ] Показ top-K рёбер, суммарной энергии, последних событий.
- [ ] Подготовить протокол данных для будущего Metal-рендера.

### 4.3 Headless reports

- [ ] CLI опция `--report` → вывод метрик + путь к snapshot JSON.
- [ ] Тест: Process.run с `--report`, проверка stdout/JSON.

---

## 5. Тестирование и качество

### 5.1 Юнит/интеграция

- [ ] Unit: CapsuleCore, EnergyMapper, Router forward/backward, BridgeSNN.
- [ ] Integration: CLI demo, snapshot export, end-to-end roundtrip.

### 5.2 Производительность

- [ ] Микро-бенчмарки (Capsule encode, Router forward) на CPU (vDSP).
- [ ] Сбор метрик `step_time`, `energy_sum`, `entropy` через LoggingHub.
- [ ] План профилирования (Instruments Time Profiler, Energy Diagnostics).

### 5.3 Документация

- [ ] Обновить `Docs/config_center_schema.md` (поля capsule/router/UI).
- [ ] Обновить `Docs/README_arch.md` диаграммами flow данных.
- [ ] Дополнить WARP.md новыми принципами (энтропия, energy guards, snapshot usage).

---

## 6. Критерии завершения фазы 2

- Капсюль: encode/decode работает, тесты и CLI демонстрация успешны.
- Энергетический роутер: forward/backward CPU реализован, метрики логируются.
- Capsule ↔ Router интеграция покрыта тестами, snapshot JSON содержит актуальные поля, UI отражает значения.
- Документация и планы синхронизированы.
- Все тесты (`swift test`) и key CLI демо проходят локально на Apple Silicon (M-серия).

---

_Дальше_: фаза 3 предполагает локальные правила обучения, GPU ускорение и расширенную визуализацию.
