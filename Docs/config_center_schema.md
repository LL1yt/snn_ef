# ConfigCenter Schema (Energetic Router · Reversible Capsule)

_С определённой долей вероятности ≈ 85 %: единый конфиг для обоих исследовательских модулей. ConfigCenter читает YAML, валидирует значения, снапшот передается подсистемам без «горячих» правок. Все ключи обязательны, если не указано иное._

---

## 1. Верхний уровень

```yaml
version: 1 # int, инкрементируем при изменении схемы
profile: "baseline" # читаемое имя набора параметров
seed: 42 # общий сид для воспроизводимости
logging: { ... } # см. раздел 2
process_registry: { ... } # см. раздел 3
paths: { ... } # директории/файлы артефактов
capsule: { ... } # настройки reversible capsule
router: { ... } # настройки SNN-router
ui: { ... } # визуализация/CLI
```

Дополнительно допустимы только поля `notes` (строка) и `metadata` (map<string,string>) для комментариев.

---

## 2. Logging

```yaml
logging:
  default_level: "info" # trace|debug|info|warn|error
  signposts: true # включать os_signpost маркеры
  destinations:
    - type: "stdout"
    - type: "file"
      path: "Logs/run.log"
  levels_override:
    capsule.encode: "debug"
    router.forward: "debug"
    router.local_hebb: "trace"
    ui.pipeline: "info"
  timestamp_kind: "relative" # relative|absolute (по умолчанию relative)
```

- `destinations` — упорядоченный список без дубликатов. Минимум один пункт.
- `levels_override` использует ключи из `process_registry`.
- При указании `type: file` путь проверяется и создается при старте (fail-fast при ошибке).

---

## 3. Process Registry

Каждый ключ — читаемый alias, значение — canonical `process_id`, используемый во всех логах/метриках/трейсах.

```yaml
process_registry:
  capsule.encode: "capsule.encode"
  capsule.base_b: "capsule.base_b"
  capsule.to_energies: "capsule.to_energies"
  capsule.from_energies: "capsule.from_energies"
  router.forward: "router.forward"
  router.backward: "router.backward"
  router.local_hebb: "router.local_hebb"
  router.checkpoint: "router.checkpoint"
  trainer.loop: "trainer.loop"
  trainer.eval: "trainer.eval"
  ui.pipeline: "ui.pipeline"
  ui.graph: "ui.graph"
  cli.main: "cli.main"
```

- Alias должен совпадать с canonical строкой (для простоты), но ConfigCenter валидирует на уникальность значений.
- Любая подсистема, создающая новый этап, обязана заранее добавить его сюда: иначе конфиг не пройдет валидацию.

---

## 4. Paths

```yaml
paths:
  logs_dir: "Logs"
  checkpoints_dir: "Artifacts/Checkpoints"
  snapshots_dir: "Artifacts/Snapshots"
  pipeline_snapshot: "Artifacts/pipeline_snapshot.json"
```

- Пути относительные рабочему каталогу; ConfigCenter нормализует и создаёт директории.
- `pipeline_snapshot` может совпадать с файлом в `snapshots_dir`.

---

## 5. Capsule Section

```yaml
capsule:
  enabled: true
  max_input_bytes: 256
  block_size: 320
  base: 256
  alphabet: "ĀāĂăĄąĆćĈĉĊċČčĎďĐđĒēĔĕĖėĘęĚěĜĝĞğĠġĢģĤĥĦħĨĩĪīĬĭĮįİıĲĳĴĵĶķĸĹĺĻļĽľĿŀŁłŃńŅņŇňŉŊŋŌōŎŏŐőŒœŔŕŖŗŘřŚśŜŝŞşŠšŢţŤťŦŧŨũŪūŬŭŮůŰűŲųŴŵŶŷŸŹźŻżŽžſƀƁƂƃƄƅƆƇƈƉƊƋƌƍƎƏƐƑƒƓƔƕƖƗƘƙƚƛƜƝƞƟƠơƢƣƤƥƦƧƨƩƪƫƬƭƮƯưƱƲƳƴƵƶƷƸƹƺƻƼƽƾƿǀǁǂǃǄǅǆǇǈǉǊǋǌǍǎǏǐǑǒǓǔǕǖǗǘǙǚǛǜǝǞǟǠǡǢǣǤǥǦǧǨǩǪǫǬǭǮǯǰǱǲǳǴǵǶǷǸǹǺǻǼǽǾǿ"
  prp: "feistel" # feistel|aes|gpu_feistel
  feistel_rounds: 10
  key_hex: "000102030405060708090a0b0c0d0e0f"
  normalization: "e_over_bplus1" # e_over_bplus1|none|custom
  pipeline_example_text: "Hello, Energetic Router!"
  crc: "crc32" # crc32|crc32c
  gpu_batch: 512 # размер батча для GPU-конверсий (>=1)
```

Constraints:

- `block_size` ≥ `max_input_bytes + header_size` (ConfigCenter проверяет, header = 7 байт в MVP).
- Алфавит строго длины `base` (в примере — 256 символов из диапазона Latin Extended без повтора).
- `enabled` можно выключить для чистых тестов роутера.

---

## 6. Router Section

```yaml
router:
  layers: 10
  nodes_per_layer: 1024
  prototypes:
    count: 64
    hidden_dim: 8
  neighbors:
    local: 8
    jump: 2
  alpha: 0.9
  tau: 3.0
  top_k: 4
  energy_constraints:
    max_dx: 10
    min_dx: 1
    max_dy: 64
    energy_base: 256 # должно совпадать с capsule.base
  optimizer:
    type: "adam"
    lr: 1.0e-3
    beta1: 0.9
    beta2: 0.999
    eps: 1.0e-8
  entropy_reg: 0.01
  batch_size: 32
  epochs: 5
  backend: "cpu" # cpu|gpu
  task: "addition" # доменная задача
  headless: false
  checkpoints:
    every_steps: 100
    keep: 5
  local_learning:
    enabled: false
    rho: 0.9
    lr: 1.0e-4
    baseline_beta: 0.95
```

Constraints:

- `energy_constraints.energy_base` = `capsule.base` (валидация).
- Если `local_learning.enabled = true`, ConfigCenter требует `process_registry.router.local_hebb`.

---

## 7. UI Section

```yaml
ui:
  enabled: true
  refresh_hz: 30
  headless_override: false
  show_pipeline: true
  show_graph: true
  pipeline_snapshot_path: "Artifacts/pipeline_snapshot.json"
  metrics_poll_ms: 200
```

- В headless запуске CLI может перезаписать `enabled=false`, но ConfigCenter фиксирует это в логах (process_id `cli.main`).
- `pipeline_snapshot_path` должен совпадать с `paths.pipeline_snapshot`.

---

## 8. Пример единого `Configs/baseline.yaml`

```yaml
version: 1
profile: "baseline"
seed: 42

logging:
  default_level: "info"
  signposts: true
  destinations:
    - type: "stdout"
    - type: "file"
      path: "Logs/baseline.log"
  levels_override:
    capsule.encode: "debug"
    router.local_hebb: "trace"
    ui.pipeline: "info"
  timestamp_kind: "relative"

process_registry:
  capsule.encode: "capsule.encode"
  capsule.base_b: "capsule.base_b"
  capsule.to_energies: "capsule.to_energies"
  capsule.from_energies: "capsule.from_energies"
  router.forward: "router.forward"
  router.backward: "router.backward"
  router.local_hebb: "router.local_hebb"
  router.checkpoint: "router.checkpoint"
  trainer.loop: "trainer.loop"
  trainer.eval: "trainer.eval"
  ui.pipeline: "ui.pipeline"
  ui.graph: "ui.graph"
  cli.main: "cli.main"

paths:
  logs_dir: "Logs"
  checkpoints_dir: "Artifacts/Checkpoints"
  snapshots_dir: "Artifacts/Snapshots"
  pipeline_snapshot: "Artifacts/pipeline_snapshot.json"

capsule:
  enabled: true
  max_input_bytes: 256
  block_size: 320
  base: 256
  alphabet: "ĀāĂăĄąĆćĈĉĊċČčĎďĐđĒēĔĕĖėĘęĚěĜĝĞğĠġĢģĤĥĦħĨĩĪīĬĭĮįİıĲĳĴĵĶķĸĹĺĻļĽľĿŀŁłŃńŅņŇňŉŊŋŌōŎŏŐőŒœŔŕŖŗŘřŚśŜŝŞşŠšŢţŤťŦŧŨũŪūŬŭŮůŰűŲųŴŵŶŷŸŹźŻżŽžſƀƁƂƃƄƅƆƇƈƉƊƋƌƍƎƏƐƑƒƓƔƕƖƗƘƙƚƛƜƝƞƟƠơƢƣƤƥƦƧƨƩƪƫƬƭƮƯưƱƲƳƴƵƶƷƸƹƺƻƼƽƾƿǀǁǂǃǄǅǆǇǈǉǊǋǌǍǎǏǐǑǒǓǔǕǖǗǘǙǚǛǜǝǞǟǠǡǢǣǤǥǦǧǨǩǪǫǬǭǮǯǰǱǲǳǴǵǶǷǸǹǺǻǼǽǾǿ"
  prp: "feistel"
  feistel_rounds: 10
  key_hex: "000102030405060708090a0b0c0d0e0f"
  normalization: "e_over_bplus1"
  pipeline_example_text: "Hello, Energetic Router!"
  crc: "crc32"
  gpu_batch: 512

router:
  layers: 10
  nodes_per_layer: 1024
  prototypes:
    count: 64
    hidden_dim: 8
  neighbors:
    local: 8
    jump: 2
  alpha: 0.9
  tau: 3.0
  top_k: 4
  energy_constraints:
    max_dx: 10
    min_dx: 1
    max_dy: 64
    energy_base: 256
  optimizer:
    type: "adam"
    lr: 1.0e-3
    beta1: 0.9
    beta2: 0.999
    eps: 1.0e-8
  entropy_reg: 0.01
  batch_size: 32
  epochs: 5
  backend: "cpu"
  task: "addition"
  headless: false
  checkpoints:
    every_steps: 100
    keep: 5
  local_learning:
    enabled: false
    rho: 0.9
    lr: 1.0e-4
    baseline_beta: 0.95

ui:
  enabled: true
  refresh_hz: 30
  headless_override: false
  show_pipeline: true
  show_graph: true
  pipeline_snapshot_path: "Artifacts/pipeline_snapshot.json"
  metrics_poll_ms: 200
```

---

## 9. Правила валидации (коротко)

- Все числовые параметры ≥0; ConfigCenter проверяет диапазоны (`max_dx ≥ min_dx ≥ 1`, `layers ≥ 1`, `nodes_per_layer ≥ 1` и т.п.).
- Строковые перечисления проверяются на допустимые значения.
- Логи: override может ссылаться лишь на существующий `process_id`; для файловых назначений путь обязателен.
- Совместимость модулей: `capsule.base == router.energy_constraints.energy_base`.
- При headless режиме CLI может временно задать `ui.enabled=false`; ConfigCenter логирует это как событие `cli.main`.

---

_Уверенность: ≈ 85 % что схема перекроет потребности MVP и исследований без дополнительного ветвления конфигов._
