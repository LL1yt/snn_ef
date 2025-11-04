# Сравнение CALM и snn_ef

Детальный анализ двух подходов к energy-based моделированию: CALM (Continuous Autoregressive Language Models) и текущая реализация snn_ef (Spiking Neural Network Energy Flow).

---

## Краткое резюме

| Аспект | CALM | snn_ef |
|--------|------|--------|
| **Парадигма** | Continuous autoregressive LLM | Event-driven SNN energy routing |
| **Цель** | Ускорение генерации токенов в K раз | Исследование SNN-маршрутизации энергии |
| **Платформа** | PyTorch / HuggingFace / Multi-GPU | Swift / Metal / Apple Silicon |
| **Масштаб** | 371M-1.82B параметров, 2.5TB данных | 10K узлов, 90K рёбер, исследовательский |
| **Training** | Energy-based loss, BrierLM metric | Backprop + local Hebbian rules |
| **Производство** | Production-ready LLM | Research stack |

---

## 1. Архитектурные подходы

### CALM: Two-Stage Architecture

```
┌─────────────────────────────────────────────────────────┐
│ Stage 1: High-fidelity Autoencoder                      │
├─────────────────────────────────────────────────────────┤
│ K tokens → single continuous vector                     │
│ Near-perfect reconstruction (15B tokens training)       │
│                                                          │
│ Input:  ["The", "quick", "brown", "fox", ...]  (K tok)  │
│ Output: v ∈ ℝᵈ  (single dense vector)                   │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│ Stage 2: Continuous Language Model                      │
├─────────────────────────────────────────────────────────┤
│ Autoregressive prediction in vector space               │
│ Energy-based training (likelihood-free)                 │
│                                                          │
│ v₁ → v₂ → v₃ → ... (each vᵢ = K tokens)                 │
│                                                          │
│ Reduces autoregressive steps by factor K!               │
└─────────────────────────────────────────────────────────┘
```

**Ключевые особенности:**
- **Semantic bandwidth scaling**: K токенов за один шаг
- **Likelihood-free training**: energy loss вместо traditional loss
- **BrierLM metric**: калиброванная оценка без likelihood
- **Temperature sampling**: управляемая генерация через black-box sampler

### snn_ef: Reversible Capsule + SNN Router

```
┌──────────────────────────────────────────────────────────┐
│ ReversibleCapsule: Deterministic Bijection               │
├──────────────────────────────────────────────────────────┤
│ String ↔ Fixed-size block ↔ Base-B digits ↔ Energies    │
│                                                           │
│ "text" → [bytes] → PRP → [digits] → [energies] → Router  │
│         ↑────────────────────────────────────────────────│
│         └─ CRC32-guarded reversibility                    │
└──────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────┐
│ EnergeticRouter: Sparse Graph with SNN Dynamics          │
├──────────────────────────────────────────────────────────┤
│ 10 layers × 1024 nodes = 10,240 nodes                    │
│ ~90K directed edges (local + jump connections)           │
│                                                           │
│ Energy packets flow through:                             │
│   SpikingKernel: V ← decay·V + W·x                       │
│                  spike = (V ≥ threshold)                 │
│   SpikeRouter:   if spike: jump (Δx, Δy)                 │
│                  else:     regular step (+1, wrap)       │
│                                                           │
│   Training: backprop + local Hebbian/REINFORCE           │
└──────────────────────────────────────────────────────────┘
```

**Ключевые особенности:**
- **Обратимость**: детерминистичное восстановление текста
- **Event-driven**: пакеты энергии движутся асинхронно
- **Sparse graph**: CSR формат, 850KB для 10K узлов
- **Dual learning**: backprop для baseline + local rules для биоплаузибильности

---

## 2. Energy-Based Training: Сходства и различия

### CALM: Energy Loss

```python
# Likelihood-free approach
energy_loss = energy_function(v_pred, v_target)

# Key insight: works directly in continuous space
# No need to marginalize over discrete tokens
# Enables semantic-level optimization

# BrierLM metric:
# Calibrated evaluation without likelihood
# Score: CALM-M = 5.72 (lower is better)
```

**Преимущества:**
- Обходит проблему высокой размерности токенов
- Работает в непрерывном семантическом пространстве
- Likelihood-free → проще тренировать большие модели

### snn_ef: Energy Flow + Constraints

```swift
// Energy conservation constraint
energyBalance = abs(Σ inputs - Σ outputs - α·Σ flows)

// Loss components:
total_loss = λ₁·energyBalance
           + λ₂·jumpPenalty(Δx, Δy)
           + λ₃·spikeRateLoss(rate, target)

// Energy as first-class entity:
// - Tracks through packets
// - Decays with alpha coefficient
// - Subject to floor threshold
```

**Преимущества:**
- Явное моделирование потоков энергии
- Физически интерпретируемые ограничения
- Локальные правила для биоплаузибильности

**Ключевое различие:**

| CALM | snn_ef |
|------|--------|
| Energy = loss function | Energy = routed quantity |
| Semantic compression | Event-driven routing |
| Batch training | Temporal dynamics |

---

## 3. Токены vs. События

### CALM: K-Token Chunks

```
Traditional LM:
"The" → "quick" → "brown" → "fox" → ...
(N tokens, N autoregressive steps)

CALM:
["The", "quick", "brown"] → ["fox", "jumps", "over"] → ...
(N/K chunks, N/K autoregressive steps)

Speedup: K× faster inference!
```

**Trade-off:**
- ✅ K× меньше autoregressive steps
- ✅ Parallel processing внутри chunks
- ⚠️ Требует high-fidelity autoencoder
- ⚠️ Quality зависит от K (semantic bandwidth)

### snn_ef: Energy Packets

```
Input energies: [5, 3, 8, 2, ...]  (from capsule digits)

Packets flow through temporal grid:
  Packet(stream=0, x=0, y=5, energy=5.0, t=0)
    ↓ SpikingKernel decides: spike or no spike
    ↓ if spike: jump to (x+Δx, y+Δy)
    ↓ energy decay: e' = α·max(e_next, 0)
  Packet(stream=0, x=3, y=12, energy=3.2, t=1)
    ↓ continues until:
    ├─ reaches output layer (accumulated)
    ├─ energy below floor (dead)
    └─ max time steps (truncated)

Output: accumulated energies at output layer
```

**Trade-off:**
- ✅ Event-driven: compute only for active packets
- ✅ Биоплаузибильная SNN-динамика
- ✅ Естественная sparse computation
- ⚠️ Variable time-to-output
- ⚠️ Harder to train (temporal credit assignment)

---

## 4. Производительность и масштаб

### CALM: Production LLM Scale

```
Model variants:
  CALM-M:  371M params  → BrierLM 5.72
  CALM-L:  735M params  → BrierLM 6.58
  CALM-XL: 1.82B params → BrierLM 8.53

Infrastructure:
  - 2.5TB pile-uncopyrighted dataset
  - Multi-GPU distributed training
  - PyTorch + HuggingFace Transformers
  - Production-ready for text generation

Training time: Stage 1 (autoencoder) + Stage 2 (LM)
```

**Целевой use case:**
- Faster LLM inference (K× speedup)
- Large-scale text generation
- Real-world deployment

### snn_ef: Research Stack

```
Model scale:
  - 10 layers × 1024 nodes = 10,240 nodes
  - ~90K edges (CSR format)
  - SpikingKernel: ~8K-64K parameters (configurable)
  - Memory: ~850KB for graph + kernel weights

Infrastructure:
  - Apple Silicon M-series (target M4)
  - Swift + Metal/MPS for GPU acceleration
  - Headless CLI + SwiftUI visualization
  - Modular: CapsuleCore | EnergeticCore | SharedInfra

Development focus: correctness → performance → optimization
```

**Целевой use case:**
- Исследование SNN-динамики
- Event-driven energy routing
- Модульная архитектура для экспериментов

---

## 5. Технические детали: Обучение

### CALM: Energy-Based + Temperature Sampling

```python
# Stage 2 training loop:
for batch in dataloader:
    # Encode K tokens → continuous vectors
    v_input = autoencoder.encode(batch.tokens)

    # Predict next chunk in vector space
    v_pred = language_model(v_input)
    v_target = autoencoder.encode(batch.next_tokens)

    # Energy loss (likelihood-free)
    loss = energy_loss(v_pred, v_target)

    loss.backward()
    optimizer.step()

# Inference with temperature sampling:
def generate(prompt, temperature):
    v = encode(prompt)
    while not done:
        v_next = sample_with_temperature(v, temperature)
        tokens = decode(v_next)
        yield tokens
```

**Особенности:**
- Gradient descent в continuous space
- Black-box sampling for generation
- BrierLM для evaluation (calibrated)

### snn_ef: Backprop + Local Rules

```swift
// Training step:
func train(inputs: [Float], targets: [Float]) {
    // 1. Forward pass: simulate energy flow
    let packets = inputs.enumerated().map { (i, e) in
        EnergyPacket(streamID: i, x: 0, y: i, energy: e, time: 0)
    }
    simulator = EnergyFlowSimulator(router: router, initialPackets: packets)

    // 2. Collect trajectory for surrogate backprop
    var trajectory: [State] = []
    while simulator.step() {
        trajectory.append(simulator.currentState)
    }

    // 3. Compute losses
    let energyLoss = energyBalance(inputs, simulator.outputs, alpha)
    let jumpLoss = jumpPenalty(trajectory)
    let spikeLoss = spikeRateLoss(trajectory)

    let total = λ₁*energyLoss + λ₂*jumpLoss + λ₃*spikeLoss

    // 4. Surrogate gradient through spike function
    let grad = computeSurrogateGradients(trajectory, total)

    // 5. Adam optimizer update
    optimizer.apply(grad, to: &kernel.parameters)

    // 6. Optional: local Hebbian update for eligibility traces
    applyLocalRule(trajectory)
}
```

**Особенности:**
- Surrogate gradients (fast_sigmoid, tanh_clip) для spike threshold
- Adam для baseline training
- Local rules (Hebbian/REINFORCE) для биоплаузибильности
- Энтропийная регуляризация для exploration

---

## 6. Сходства: Energy как центральная концепция

### Оба проекта используют energy:

1. **CALM:**
   - Energy loss для training
   - Likelihood-free methodology
   - Работает в continuous semantic space

2. **snn_ef:**
   - Energy packets как routed entities
   - Energy constraints для physics-inspired dynamics
   - Локальные правила для homeostasis

### Философское сходство:

```
Traditional approach:
  Token-by-token → discrete space → likelihood maximization

Energy-based approach:
  - CALM: Semantic chunks → continuous space → energy optimization
  - snn_ef: Event packets → temporal dynamics → energy conservation
```

**Оба избегают:**
- Combinatorial explosion discrete tokens (CALM)
- Dense matrix operations (snn_ef → sparse graph)
- Traditional likelihood-based training (в разной степени)

---

## 7. Различия: Цели и приоритеты

| Аспект | CALM | snn_ef |
|--------|------|--------|
| **Главная цель** | Faster LLM inference | SNN dynamics research |
| **Metric** | BrierLM (calibrated) | Energy balance, spike rate |
| **Deployment** | Production text generation | Experimental platform |
| **Data scale** | 15B tokens (autoencoder), 2.5TB (LM) | Synthetic + small inputs |
| **Hardware** | Multi-GPU (PyTorch) | Single Apple Silicon (Metal) |
| **Модуляризация** | Autoencoder + LM | Capsule + Router + Infra |
| **Обратимость** | N/A (lossy compression OK) | Strict (CRC32-guarded) |
| **Temporal dynamics** | Autoregressive chunks | Event-driven packets |

---

## 8. Потенциальные взаимные идеи

### Что snn_ef может взять из CALM:

1. **Semantic chunk processing:**
   ```swift
   // Вместо побайтового капсюля:
   // K символов → 1 энерговектор (autoencoder-style)
   // Может сократить количество packets
   ```

2. **BrierLM-style metric:**
   ```swift
   // Calibrated evaluation для SNN output:
   // Не просто energy balance, а semantic quality
   ```

3. **Temperature sampling:**
   ```swift
   // Для inference в SpikeRouter:
   // Добавить temperature к softmax в роутинге
   ```

4. **Likelihood-free training:**
   ```swift
   // Усилить energy-based loss:
   // Меньше полагаться на surrogate gradients
   ```

### Что CALM может взять из snn_ef:

1. **Event-driven computation:**
   ```python
   # Sparse packet processing вместо dense forward:
   # Compute only for "active" semantic chunks
   ```

2. **Local learning rules:**
   ```python
   # Hebbian/REINFORCE для части сети:
   # Reduce global backprop dependency
   ```

3. **Explicit energy routing:**
   ```python
   # Energy не только loss, но и routed quantity:
   # Track semantic flow through layers
   ```

4. **Reversibility constraints:**
   ```python
   # CRC-guarded bijections для debugging:
   # Ensure information preservation
   ```

---

## 9. Практические выводы

### Когда использовать CALM:

✅ Нужен faster LLM inference (K× speedup)
✅ Есть ресурсы для двухэтапного обучения
✅ Цель: production text generation
✅ Можно позволить lossy compression (high-fidelity, но не strict bijection)
✅ Multi-GPU инфраструктура доступна

### Когда использовать snn_ef:

✅ Исследование SNN-динамики и спайковых правил
✅ Event-driven computation experiments
✅ Строгая обратимость текста (CRC32-guarded)
✅ Модульная архитектура для быстрых итераций
✅ Apple Silicon target (Metal/MPS optimization)
✅ Headless + GUI опциональная визуализация

---

## 10. Архитектурные диаграммы: Прямое сравнение

### CALM: End-to-End Flow

```
User Input:
   "The quick brown fox jumps over the lazy dog"
      ↓
Tokenizer:
   [2348, 2935, 7586, 3029, 8264, 625, 152, 4729, 1553]
      ↓
Autoencoder (Stage 1):
   K=3 tokens → v₁ ∈ ℝ⁷⁶⁸
   [2348,2935,7586] → v₁
   [3029,8264,625]  → v₂
   [152,4729,1553]  → v₃
      ↓
Language Model (Stage 2):
   v₁ → v₂ → v₃ → v₄ (predict next chunks)
   [autoregressive in vector space]
      ↓
Decoder:
   v₄ → [tokens] → "The dog sleeps"
```

### snn_ef: End-to-End Flow

```
User Input:
   "Hello"
      ↓
ReversibleCapsule:
   "Hello" → [bytes] → PRP permutation → [base-B digits]
   digits: [5, 3, 15, 8, 9, ...]
      ↓
EnergyMapper:
   digits → energies = digits + 1 ∈ [1..B]
   energies: [6, 4, 16, 9, 10, ...]
      ↓
Normalize (optional):
   x = energies / (B+1) ∈ [0, 1]
      ↓
EnergeticRouter:
   EnergyPackets flow through 10-layer graph
   SpikingKernel + SpikeRouter dynamics
   [spike → jump, no spike → regular step]
      ↓
OutputAccumulator:
   Collect energies at output layer per stream
   output_energies: [5.2, 3.1, 14.8, ...]
      ↓
Reverse pipeline:
   energies → digits → PRP⁻¹ → bytes → "Hello"
   [CRC32 validates round-trip]
```

---

## 11. Численный пример: Energy Flow

### CALM (simplified):

```
Chunk 1: ["The", "quick", "brown"]
  Encode → v₁ = [0.23, -0.45, 0.67, ..., 0.12] ∈ ℝ⁷⁶⁸

Energy loss:
  v_pred = model(context)
  v_target = v₁
  energy = ||v_pred - v_target||² + regularization
  loss = energy → backprop

BrierLM score (validation):
  score = calibrated_metric(predictions, targets)
  CALM-M: 5.72 (lower is better)
```

### snn_ef (simplified):

```
Input energies: [6, 4, 16] (from capsule)

Packet routing:
  t=0: Packet(stream=0, x=0, y=0, e=6.0)
       SpikingKernel → spike=true, Δx=2, Δy=3
       → new position: x=2, y=3, e=5.1 (decayed by α=0.85)

  t=1: Packet(stream=0, x=2, y=3, e=5.1)
       SpikingKernel → spike=false
       → regular step: x=3, y=3, e=4.3

  t=2: Packet(stream=0, x=3, y=3, e=4.3)
       → ... (continues until output or death)

Energy balance loss:
  Σ inputs = 6 + 4 + 16 = 26.0
  Σ outputs = 22.3 (at output layer)
  loss = |26.0 - 22.3 / 0.85| → train to minimize
```

---

## 12. Итоговая таблица: Quick Reference

| Feature | CALM | snn_ef |
|---------|------|--------|
| **Язык** | Python | Swift |
| **Framework** | PyTorch/HuggingFace | Metal/MPS |
| **Основная идея** | K tokens → 1 vector | Text → energy packets → route |
| **Energy роль** | Loss function | Routed quantity |
| **Training** | Energy loss + BrierLM | Backprop + local rules |
| **Inference** | Temperature sampling | Event-driven simulation |
| **Масштаб** | 371M-1.8B params | 10K nodes, 90K edges |
| **Данные** | 2.5TB text | Synthetic/small |
| **Reversibility** | No (lossy OK) | Yes (CRC32-guarded) |
| **Production** | Ready for deployment | Research platform |
| **GPU** | Multi-GPU required | Single Apple Silicon |
| **Модульность** | Autoencoder + LM | Capsule + Router + Infra |
| **Временная динамика** | Chunk autoregressive | Packet event-driven |
| **Evaluation** | BrierLM (calibrated) | Energy balance, spike rate |

---

## 13. Заключение

### Философское сходство:

Оба проекта исследуют **energy-based paradigms** как альтернативу традиционным подходам:

- **CALM:** Преодолевает token-by-token bottleneck через semantic chunk compression
- **snn_ef:** Исследует event-driven SNN dynamics для sparse energy routing

### Практические различия:

- **CALM** — production-ready LLM ускоритель с конкретной бизнес-ценностью (K× faster)
- **snn_ef** — research platform для изучения SNN-архитектур и биоплаузибильных правил

### Потенциал взаимного обогащения:

```
CALM → snn_ef:
  ├─ Semantic chunking (reduce packet count)
  ├─ BrierLM-style metrics (calibrated evaluation)
  ├─ Temperature sampling (inference control)
  └─ Likelihood-free focus (strengthen energy loss)

snn_ef → CALM:
  ├─ Event-driven sparsity (compute only active chunks)
  ├─ Local learning rules (reduce backprop dependency)
  ├─ Explicit energy routing (track semantic flow)
  └─ Reversibility constraints (debugging/validation)
```

### Рекомендации:

1. **Для snn_ef:**
   - Рассмотреть **chunk-based capsule encoding** (вместо побайтового)
   - Добавить **BrierLM-inspired metric** для оценки quality
   - Экспериментировать с **temperature-controlled routing** (softmax τ)

2. **Для CALM-inspired research:**
   - Изучить **sparse packet processing** из snn_ef для ускорения
   - Добавить **local learning components** для части сети
   - Протестировать **energy routing** как дополнение к energy loss

---

**Ссылки:**

- CALM: https://github.com/shaochenze/calm
- snn_ef: текущий репозиторий `/home/user/snn_ef`

**Документ создан:** 2025-11-04
**Автор:** Claude (анализ по запросу пользователя)
