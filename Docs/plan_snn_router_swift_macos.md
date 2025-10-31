# План реализации исследовательской архитектуры «энергетический роутер» (macOS · Swift · M4)

_Оценка уверенности ≈ 85 %. План описывает спайковую (SNN) архитектуру EnergeticRouter: энергия движется по временной сетке, спайки инициируют прыжки без заранее заданных направлений. Фолбэков на прежнюю softmax/графовую схему нет._

---

## Цели и принципы
- **MVP**: потоковый EnergeticRouter, где каждое «зерно» энергии идёт вперёд по времени (ось X), а спайки позволяют прыгать на несколько слоёв вперёд и смещаться по оси Y. Все решения (энергия, смещения) принимает обучаемая SNN.
- **Производительность**: максимальное использование Accelerate/Swift SIMD на M4; архитектура готова к переносу на MPS/Metal.
- **Конфигурация**: ConfigCenter определяет диапазоны смещений, пороги, затухание и лоссы; никаких CLI-флагов.
- **Качество**: fail-fast при нарушении диапазонов, учёт `stream_id`, headless/UI получают одно и то же состояние.
- **Простота → Эмерджентность**: задаём только границы и правила, модель сама выбирает смещения. Минимум hand-crafted ограничений.

---

## Архитектура (высокий уровень)

```
Capsule → Energies → SpikeRouter ──► EnergyFlow ──► Outputs
           │             │                │
           │             ▼                │
           │       SpikingKernel          │
           ▼             │                ▼
    TemporalGrid ←──── TrainingLoop ←─── SNNLosses
                    │
                    ▼
              RouterMetrics/Logger
```

- **TemporalGrid**: размеры и wrap/clamp правила.
- **SpikingKernel**: общий SNN элемент с мембранным потенциалом, surrogate градиентами и предсказанием `Δx/Δy`.
- **SpikeRouter**: применяет kernel к активным потокам, решает про движение/прыжок.
- **EnergyFlow**: исполняет шаги во времени, собирает выходы.
- **TrainingLoop**: surrogate backprop или локальные правила, Adam.
- **Metrics/Logger**: наблюдаемость, snapshot для UI/headless.

---

## Ключевые модули и файлы

| Область | Основные файлы | Функция |
|---------|----------------|---------|
| Конфиг  | `RouterConfig.swift`, `TemporalGrid.swift` | Диапазоны SNN, wrap/clamp, проверка YAML |
| Ядро    | `SpikingKernel.swift`, `SurrogateActivation.swift` | Мембрана `V`, энергия, смещения, surrogate градиенты |
| Потоки  | `EnergyPacket.swift`, `SpikeRouter.swift`, `EnergyFlowSimulator.swift` | Обработка `stream_id`, шаги времени, прыжки |
| Обучение| `SNNLosses.swift`, `TrainingLoop.swift`, `Optimizer.swift` | Energy balance, spike rate, Adam |
| Метрики | `RouterMetrics.swift`, `RouterLogger.swift`, `PipelineSnapshot` | Статистика, логирование событий, headless экспорт |
| Интеграция | `BridgeSNN` (позже), UI обновления | Связь Capsule ↔ Router, визуализация |

---

## Конфигурация (Baseline пример)

```yaml
router:
  layers: 10
  nodes_per_layer: 1024
  snn:
    decay: 0.92
    threshold: 0.8
    reset_value: 0.0
    delta_x_range: [1, 4]
    delta_y_range: [-128, 128]
    surrogate: "fast_sigmoid"
    dt: 1
  alpha: 0.9
  energy_floor: 1.0e-5
  training:
    optimizer:
      type: "adam"
      lr: 1.0e-3
      beta1: 0.9
      beta2: 0.999
      eps: 1.0e-8
    losses:
      energy_balance_weight: 1.0
      jump_penalty_weight: 1.0e-2
      spike_rate_target: 0.1
```

- ConfigCenter обязателен: валидации диапазонов, соответствие `energy_base`.
- Значения легко менять для экспериментов (эмерджентность), но в рамках допустимых границ.

---

## Поток данных

1. Capsule кодирует вход → `EnergyPacket(streamID, x=0, y=index, energy, t=0)`.
2. На каждом шаге `SpikeRouter`:
   - нормализует `(x, y, e, t)`;
   - обновляет мембранный потенциал через `SpikingKernel`;
   - вычисляет `energy_next` и `Δx/Δy`;
   - если нет спайка → поток идёт в `x+1`;
   - если есть спайк → прыжок в `x + Δx` (квантуется и ограничивается), `y` по тору;
   - энергия обновляется `α * energy_next`. Если ниже `energy_floor` — поток затухает.
3. EnergyFlowSimulator ведёт список активных потоков и складывает выходы, когда `x ≥ layers`.
4. TrainingLoop использует surrogate градиенты, лоссы и Adam для обновления параметров.
5. RouterMetrics/Logger фиксируют шаг, спайки, отклонения энергии; UI/headless читают одинаковую трассу.

---

## Тестирование

- **Динамика без спайков**: порог высокий → поток просто шагает вперёд, энергия затухает согласно `alpha`.
- **Спайк**: опустить порог → проверить прыжок, wrap по `y`, попадание в выходной буфер при `x` > `layers-1`.
- **Surrogate grad**: finite differences по маленькой сети (2 слоя) для проверки обратного прохода.
- **Energy balance**: `|Σout − α·Σin| < ε` под контролем лосса.
- **Snapshot**: проверка, что headless JSON воспроизводит все спайки.

---

## Headless и UI

- Headless CLI пишет `Artifacts/pipeline_snapshot.json` с полями:
  - `streams`: последовательность `(time, x, y, energy, spike?)`;
  - `snn_params`: текущие `decay`, `threshold`, `delta_x/y range`, `surrogate`.
- UI (SwiftUI/Metal) подписывается на LoggingHub:
  - рисует временную ленту и прыжки;
  - отображает распределение `Δx/Δy`, карту активных потоков;
  - даёт управление (пауза/шаг/сброс).

---

## Производительность (M4)

- **CPU**: batched `SpikingKernel` с `vDSP_mmul`, SIMD-оптимизация мембран и смещений.
- **Swift Concurrency**: `TaskGroup` по потокам или слоям, пер-поточные буферы для агрегирования энергии.
- **GPU** (позднее): 
  - `SpikingKernel` → `MPSMatrixMultiplication` для обновления мембран и линейных слоёв;
  - SpikeRouter — Metal compute kernels для квантования и wrap.
- **Память**: компактные структуры (`SIMD2`, `SIMD4`), когерентные массивы.

---

## Дорожная карта

1. **Фаза 2** (текущая): TemporalGrid, SpikingKernel, SpikeRouter, EnergyFlow, SNNLosses, RouterMetrics.
2. **Фаза 3**: локальные правила (например, STDP), смешанные с surrogate-gradient обучением; специализация под задачи (reward signals).
3. **Фаза 4**: GPU перенос (MPS/Metal), оптимизация шагов и профилирование (`os_signpost`, Instruments).
4. **Фаза 5**: расширенная визуализация, набор задач (sequence routing, arithmetic), автоматизация экспериментов.

---

## Риски и смягчение

- **Частые спайки**: следим за `spike_rate`, регулируем `threshold`/регуляризаторы.
- **Большие прыжки**: `delta_x/y` квантуются и ограничиваются, лосс штрафует выход за диапазон.
- **Численная стабильность**: surrogate функции с безопасными производными, clamp энергий, сброс мембраны.
- **Производительность**: батчевые операции, ограничение количества активных потоков (энергия ниже порога гасит поток).
- **Согласованность конфигов**: ConfigCenter валидирует диапазоны, обеспечивает детерминированный запуск (seed).

---

## Итог

Новая архитектура фиксирует единственный путь развития EnergeticRouter: временная сетка + SNN прыжки без заранее заданных рёбер. Далее все улучшения (обучение, GPU, визуализация) строятся вокруг этой схемы. Конфиги и документация очищены от старых подходов; дальнейшие шаги — реализация кода и эксперименты с диапазонами для эмерджентного поведения.
