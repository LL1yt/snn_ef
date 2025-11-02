# EnergeticCore Visualization Plan

## Goals
- Показать пошаговую маршрутизацию энергопакетов через `TemporalGrid`.
- Объяснить работу `SpikingKernel`, мембранных динамик и порогов.
- Отразить влияние конфигурации (`RouterConfig`, `SNNConfig`) на поведение сети.
- Синхронизировать headless-трассировку и интерактивную SwiftUI/Metal визуализацию, используя единый снимок состояния.

## Основные сущности
- **TemporalGrid** — слои × узлы, отображение структуры маршрутизатора.
- **EnergyPacket** — положение `(x, y)`, энергия `energy`, время `time`, статус (`alive`, `completed`, `dead`).
- **SpikingKernel & Membrane** — текущее значение мембраны, флаги спайков, выходы `energyNext`, `deltaXY`.
- **EnergeticRouter / SpikeRouter** — текущий шаг маршрутизации, каналы передачи энергий, статистика.
- **ConfigCenter Snapshot** — обязательный источник параметров для headless и UI слоёв.

## Представление данных
1. **Grid Map**
   - 2D-раскадровка: ось X = слой, ось Y = узлы.
   - Цвет/насыщенность = текущая энергия узла или мембранный потенциал.
   - Иконка/маркер для активных пакетов (разный стиль для alive/completed/dead).

2. **Packet Timeline**
   - Линии времени для выбранных потоков (`streamID`).
   - Узлы: `energy`, `membrane`, `spike` флаг, `deltaXY`.
   - Хранить историю в кольцевом буфере, подтягивать для headless JSON.

3. **Membrane & Spike Dashboard**
   - Диаграмма мембраны по шагам, пороговая линия, пометки спайков.
   - Отдельный график для surrogate-градиентов (tanh_clip / fast_sigmoid) с β (из Config).

4. **Energy Flow Metrics**
   - Общая энергия по слоям (stacked bar) + изменение vs пред. шаг.
   - Кол-во активных пакетов, средняя энергия, мин/макс.

5. **Configuration HUD**
   - Сводка: `layers`, `nodes_per_layer`, `alpha`, `energy_floor`, `snn.parameter_count`, `surrogate`.
   - Ссылки на `process_id` из `ProcessRegistry` для логирования.

## Визуальные слои
1. **SwiftUI Scene**
   - `GridView` (Metal-backed) для слоёв.
   - `PacketInspectorView` — поп-овер/панель деталей активного пакета.
   - `MembraneChartView` — графика мембраны (Metal Performance Shaders или Swift Charts).

2. **Metal Rendering**
   - Буфер позиций пакетов (structured buffer), индексы слоёв/узлов.
   - Compute kernel для раскраски heatmap (энергия/мембрана).
   - Offscreen render targets → SwiftUI `MetalView`.

3. **Headless Snapshot**
   - JSON (`Artifacts/pipeline_snapshot.json`) с:
     ```json
     {
       "step": n,
       "packets": [...],
       "grid": {...},
       "membrane_stats": {...},
       "events": [
         { "process_id": "router.step", "level": "info", "message": "...", "ts": ... }
       ]
     }
     ```
   - Совместно используется UI и CLI.

## Источники данных
- `EnergyFlowSimulator.step()` — основной драйвер, отдаёт пакеты и мембраны.
- `SpikeRouter.route(packet:membrane:)` — низкоуровневые события для logging.
- `LoggingHub` — оси для профилирования (`os_signpost`, уровни trace/debug).
- `ConfigCenter` — только immutable snapshot, передаётся при создании визуализатора.

## Поток данных
1. CLI/UI запрашивают у `EnergyFlowSimulator` следующий кадр.
2. Симулятор:
   - Обновляет мембраны и пакеты.
   - Логирует события через `LoggingHub`.
   - Пушит данные в `VisualizationBus` (Combine publisher).
3. В headless режиме `VisualizationBus` сериализует state в `Artifacts/pipeline_snapshot.json`.
4. В UI режиме `VisualizationBus` ↔ SwiftUI views, Metal получает новые буферы по шагу.

## Интеграция с существующей визуализацией Capsule
- Повторное использование:
  - `LoggingHub` subscriptions.
  - Конфигурационный HUD.
  - Общая система снимков (`ConfigPipelineSnapshot`).
- Новое:
  - Heatmap слоёв SNN.
  - Membrane charts.
  - Packet timelines (вместо символов капсулы).

## Пошаговый план реализации
1. **Infrastructure**
   - [ ] Создать протокол `EnergeticVisualizationDataSource` (headless + UI).
   - [ ] Добавить `VisualizationBus` (Combine Subject) с throttling.
   - [ ] Расширить `ConfigPipelineSnapshot` для EnergeticCore блоков.

2. **Сбор данных**
   - [ ] Добавить в `EnergyFlowSimulator` метод `makeFrameState()`:
       - активные пакеты
       - мембраны
       - статистика по слоям
   - [ ] В `SpikeRouter`/`SpikingKernel` протоколировать мембрану и спайки (без сильного оверхеда).

3. **Headless Export**
   - [ ] `EnergeticCLI` сохраняет снимок после каждого шага (или батча).
   - [ ] Добавить `--frame-count` в конфиг (через ConfigCenter) для лимита шагов в headless тестах.

4. **UI Layer**
   - [ ] SwiftUI `EnergeticPipelineView`:
       - секция Grid (Metal view)
       - секция Metrics (Charts)
       - кампактный HUD (Config summary).
   - [ ] Реализовать взаимодействие: клик по пакету → раскрыть подробности.
   - [ ] Поддержка паузы/скорости (`SimulationControlBar`).

5. **Metal Render**
   - [ ] Подготовить compute shader: вход — массив энергий, выход — цветовая карта.
   - [ ] Приоритизировать GPU, избегая копий CPU↔GPU (использовать `MTLBuffer` из `EnergyFlowSimulator`).

6. **Testing / Diagnostics**
   - [ ] Snapshot-тесты headless (сравнение JSON).
   - [ ] Проверка производительности (`os_signpost`, LoggingHub).
   - [ ] Unit-тест на корректность агрегации (`EnergyFlowSimulatorTests` дополнить проверкой визуальной структуры).

## UX Артефакты
- Tooltip:
  - `EnergyPacket`: `(x, y, energy, time, membrane, spike)`
  - `Layer`: средняя энергия, количество пакетов.
- Alerts:
  - Нарушение energy floor → выделять красным слой/пакет.
  - Spike storm (слишком много спайков) → баннер.

## Ограничения и риски
- Размер сетки (слои × узлы) может быть большим → агрегация/вьюпорт.
- Запоминание истории требует аккуратного ограничения (ring buffer на N шагов).
- Headless режим должен оставаться lightweight; визуализация не должна менять математические результаты.

## Следующие шаги
1. Прототип headless экспорта (`VisualizationBus`, JSON форматы).
2. Простой SwiftUI эскиз: grid + список пакетов.
3. Метализация heatmap и membrane charts.
4. Интеграция с CLI (команда snapshot) и UI (live view).
