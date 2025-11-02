# EnergeticRouter SNN — архитектурная схема

---

## Общий обзор модулей

```
┌──────────────────────────────────────────────────────┐
│                    EnergeticCore                     │
├──────────────────────────────────────────────────────┤
│ TemporalGrid ─► SpikingKernel ─► SpikeRouter ─► EnergyFlow │
│        │             │               │             │ │
│        ▼             ▼               ▼             │ │
│ RouterConfig   SurrogateGradients  SNNLosses   RouterMetrics │
│                                                     │       │
│                               TrainingLoop ◄────────┘       │
│                                                     ▼       │
│                                                RouterLogger │
└────────────────────────────────────────────────────────────┘
```

- `TemporalGrid` задаёт размеры сетки и правила wrap/clamp.
- `SpikingKernel` обновляет мембранный потенциал и вычисляет `Δx/Δy`, энергию.
- `SpikeRouter` реализует логику движения и спайковых прыжков.
- `EnergyFlow` отслеживает активные и завершённые потоки.
- `TrainingLoop` использует surrogate градиенты и лоссы.
- `RouterMetrics`/`RouterLogger` обеспечивают headless/UI диагностику.

---

## TemporalGrid & ConfigCenter

```
RouterConfig (YAML)
    ├─ layers
    ├─ nodes_per_layer
    └─ snn:
         decay, threshold, reset
         delta_x_range, delta_y_range
         surrogate, dt
         alpha, energy_floor
         training.{optimizer, losses}
            ↓
TemporalGrid(layers, nodesPerLayer)
    ├─ advanceForward(x) → min(x+1, layers)
    ├─ wrapY(y) → (y mod nodesPerLayer)
    └─ isOutputLayer(x)
```

- ConfigCenter валидирует диапазоны, запрещает `Δx < 1`.
- Grid предоставляет быстрые операции для SpikeRouter.

---

## SpikingKernel

```
inputs: [x_norm, y_norm, e_norm, t_norm]  (батч)
┌──────────────────────┐
│ V ← decay·V + W_in·inputs + b_in       │
│ energy_next = clamp(W_energy·h + b)    │
│ delta_xy = tanh(W_delta·h + b)         │
│ spike = (V ≥ threshold)                │
│ if spike { V ← resetValue }            │
└──────────────────────┘
```

- Реализуется с Accelerate (матрицы) либо SIMD.
- Surrogate градиенты (`fast_sigmoid`, `tanh_clip`) обеспечивают обучаемость порога.
- Выход `delta_xy` масштабируется диапазоном конфигурации.

---

## SpikeRouter & EnergyFlow

```
for packet in activePackets:
    input = packet.asNormalizedInput()
    output = SpikingKernel.forward(input, membrane[packet])

    x_base = packet.x + 1
    y_base = wrap(packet.y)

    if output.spike:
        x_jump = clamp(round(output.delta_x), deltaXRange)
        y_jump = wrap(packet.y + round(output.delta_y))
        x_next = min(x_base + x_jump - 1, grid.layers)
        y_next = y_jump
    else:
        x_next = x_base
        y_next = y_base

    energy_next = alpha * max(output.energy_next, 0)
    if energy_next ≥ energy_floor:
        enqueue(newPacket(streamID, x_next, y_next, energy_next, t+1))
    else:
        drop (поток затух)
```

- Если `x_next == grid.layers`: энергия уходит в `OutputAccumulator`.
- `EnergyFlowSimulator` выполняет шаги, пока есть активные пакеты или не достигнут лимит времени.

---

## Обучение и лоссы

```
SNNLosses:
  energyBalance(inputs, outputs, alpha)
  jumpPenalty(deltaX, deltaY, ranges)
  spikeRateLoss(spikeCount, targetRate)

TrainingLoop:
  - собирает траекторию (для surrogate backprop)
  - считает лоссы
  - вычисляет градиенты по SpikingKernel
  - применяет Adam / выбранный оптимизатор
```

- Surrogate производные применяются к порогу и мембранам.
- Логирование шагов и метрик (`energy_error`, `spike_rate`, `mean_delta`).

---

## Метрики и логирование

```
SpikeRouter ─► RouterMetrics(step, spikeCount, meanΔx, meanΔy, energyError)
                 │
                 ├─► RouterLogger.router.step
                 ├─► RouterLogger.router.spike (stream details)
                 └─► PipelineSnapshot (headless/UI)
```

- Snapshot содержит: параметры SNN, список активных потоков, историю спайков (`time, stream_id, x, y, Δx, Δy, energy`).
- Headless и UI читают одинаковые данные.

---

## GPU перспектива

- Batched операции `SpikingKernel` → `MPSMatrixMultiplication`.
- SpikeRouter может быть разложен на compute kernels: обновление мембраны, применение порога, перенос пакетов.
- CPU реализация остаётся эталоном для тестов и численной проверки.

---
