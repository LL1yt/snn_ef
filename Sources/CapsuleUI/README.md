# CapsulePipeline Visualization

Интерактивная визуализация пайплайна трансформации капсюля для macOS (SwiftUI).

## Что визуализируется

Полный цикл трансформации текста через **10 этапов**:

```
1. 📝 Input Text          → Исходный UTF-8 текст
2. 🔧 Block Structure     → Header + Data + Padding
3. 🔐 PRP Transform       → Feistel преобразование
4. 📦 Capsule Block       → Финальный блок
5. 🔢 Base Conversion     → Конверсия в base-B digits
6. 🖨️ Printable String    → Печатная строка
7. ⚡ Energies Mapping    → Энергии [1..B]
8. 📊 Normalization       → Нормализация [0..1]
9. ⏪ Reverse Process     → Обратный процесс
10. ✅ Recovered Text     → Восстановленный текст + CRC
```

## Архитектура

```
Sources/CapsuleUI/
├── Models/
│   ├── PipelineStage.swift      # Модель этапа пайплайна
│   └── PipelineSnapshot.swift   # Снимок всего пайплайна
├── Executors/
│   └── PipelineExecutor.swift   # Оркестратор выполнения
├── Components/
│   ├── HexDumpView.swift        # Hex dump компонент
│   ├── DigitsTableView.swift    # Таблица цифр
│   ├── StageHeaderView.swift    # Заголовок этапа
│   └── StageNavigationView.swift # Навигация
├── Views/
│   ├── CapsulePipelineView.swift    # Главный view
│   ├── MetricsPanelView.swift       # Панель метрик
│   ├── InputStageView.swift         # View для каждого
│   ├── BlockStructureView.swift     # из 10 этапов
│   └── ... (еще 8 views)
├── Utilities/
│   ├── HexFormatter.swift       # Форматирование hex
│   ├── DataFormatter.swift      # Форматирование данных
│   └── ColorScheme.swift        # Цветовая схема
└── CapsulePipelineApp.swift    # Demo app entry point
```

## Быстрый старт

### 1. Создание Xcode App target

Создайте новый macOS App в Xcode:

```swift
// MyApp.swift
import SwiftUI
import CapsuleUI
import SharedInfrastructure

@main
struct MyApp: App {
    init() {
        do {
            let snapshot = try ConfigCenter.load()
            try LoggingHub.configure(from: snapshot)
            ProcessRegistry.configure(from: snapshot)
        } catch {
            print("Config error: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            if let config = (try? ConfigCenter.load())?.root.capsule {
                CapsulePipelineView(config: config)
                    .frame(minWidth: 900, minHeight: 600)
            } else {
                Text("Failed to load config")
            }
        }
    }
}
```

### 2. Конфигурация

Убедитесь, что `Configs/baseline.yaml` содержит:

```yaml
capsule:
  enabled: true
  max_input_bytes: 256
  block_size: 320
  base: 256
  alphabet: "ĀāĂă..." # 256 уникальных символов из Latin Extended
  prp: "feistel"
  feistel_rounds: 10
  key_hex: "000102030405060708090a0b0c0d0e0f"
  normalization: "e_over_bplus1"
  pipeline_example_text: "Hello, Energetic Router!"

ui:
  enabled: true
  show_pipeline: true
```

### 3. Переменная окружения

Установите путь к конфигу:

```bash
export SNN_CONFIG_PATH=/path/to/snn_ef/Configs/baseline.yaml
```

Или в Xcode:
- Product → Scheme → Edit Scheme
- Run → Arguments → Environment Variables
- Добавить: `SNN_CONFIG_PATH = /path/to/Configs/baseline.yaml`

### 4. Запуск

```bash
# Через Xcode
open MyApp.xcodeproj
# Cmd+R

# Или через swift run (если создали executable target)
swift run capsule-pipeline-viz
```

## Использование UI

### Боковая панель (Sidebar)

**Секция Input:**
- Текстовое поле для ввода
- Кнопка "Execute Pipeline"
- Индикатор прогресса

**Секция Navigation:**
- ◀️ Previous: предыдущий этап
- ▶️ Play/Pause: автовоспроизведение
- ▶️ Next: следующий этап
- 🔄 Reset: в начало
- Progress bar с индикацией текущего этапа

**Секция Metrics:**
- Общее время выполнения
- Количество этапов
- Статус (Success/Failed)
- Время каждого этапа
- Самый медленный этап

### Главная область (Detail)

**Список этапов:**
- Кликабельные заголовки с иконками
- Разворачивание/сворачивание деталей
- Подсветка текущего этапа
- Индикатор ошибок (если есть)

**Детали каждого этапа:**

1. **Input**: Исходный текст + метрики
2. **Block Structure**:
   - Header (length, flags, CRC32)
   - Payload (hex dump)
   - Padding size
3. **PRP Transform**:
   - Before/After hex dumps
   - Rounds count
4. **Capsule Block**: Hex dump финального блока
5. **Base Conversion**:
   - Digits table (первые 50 + последние 10)
   - Статистика
6. **Printable String**: Строка + alphabet preview
7. **Energies**:
   - Статистика (min/max/mean/sum)
   - Распределение (топ-5 значений)
   - Таблица энергий
8. **Normalization**:
   - Формула нормализации
   - Статистика
   - Таблица значений
9. **Reverse Process**:
   - Диаграмма обратного процесса
   - Восстановленные байты
10. **Recovered**:
    - CRC verification (PASS/FAIL)
    - Восстановленный текст
    - Comparison (если mismatch)

## Возможности

✅ **Интерактивность**
- Ввод произвольного текста
- Пошаговая навигация
- Автовоспроизведение с таймером
- Разворачивание деталей

✅ **Детализация**
- Hex dumps (адрес | hex | ASCII)
- Таблицы digits/energies
- Метрики производительности
- CRC verification

✅ **Визуальная обратная связь**
- Цветовое кодирование этапов
- Подсветка текущего этапа
- Индикаторы успеха/ошибок
- Progress bar

✅ **Логирование**
- Интеграция с LoggingHub
- process_id для каждого этапа
- Метрики времени выполнения

## Программное использование

### Прямое использование PipelineExecutor

```swift
import CapsuleCore
import CapsuleUI

let config = try ConfigCenter.load()
let executor = PipelineExecutor(config: config.root.capsule)

// Выполнить roundtrip
let snapshot = try await executor.executeRoundtrip("Hello, World!")

// Получить этапы
for stage in snapshot.stages {
    print("\(stage.type): \(stage.metrics.duration)s")
}

// Проверить успех
if snapshot.success {
    print("All stages completed successfully")
}

// Aggregate metrics
let metrics = snapshot.aggregateMetrics
print("Total: \(metrics.totalDuration)s")
print("Slowest: \(metrics.slowestStage?.rawValue ?? "N/A")")
```

### Использование в SwiftUI

```swift
import SwiftUI
import CapsuleUI

struct MyView: View {
    let config: ConfigRoot.Capsule

    var body: some View {
        CapsulePipelineView(config: config)
    }
}
```

## Расширение

### Добавление нового этапа

1. Добавить case в `PipelineStageType`:
```swift
case myNewStage
```

2. Добавить data type в `StageData`:
```swift
case myData(MyType)
```

3. Создать view: `MyStageView.swift`:
```swift
public struct MyStageView: View {
    let stage: PipelineStage
    // ...
}
```

4. Добавить в `CapsulePipelineView.stageDetailView()`:
```swift
case .myNewStage:
    MyStageView(stage: stage)
```

5. Добавить цвет/иконку в `ColorScheme.swift`

### Кастомизация

**Цвета:**
```swift
// В ColorScheme.swift
public static func color(for stageType: PipelineStageType) -> Color {
    // Ваша логика
}
```

**Форматирование:**
```swift
// В DataFormatter.swift
public static func formatDuration(_ duration: TimeInterval) -> String {
    // Ваш формат
}
```

## Интеграция с Router (будущее)

План предусматривает расширение для отображения SNN Router:

```
Input → Capsule → Energies → [ROUTER] → Energies → Reverse → Output
```

Добавятся новые этапы:
- `routerForward`: Входные энергии → Router → Выходные энергии
- `routerBackward`: Градиенты и обновления
- `routerGraph`: Визуализация графа маршрутизации

## Производительность

- **CPU**: Swift async/await для executor
- **UI**: SwiftUI с LazyVStack для производительности
- **Память**: Compact views показывают только первые/последние N элементов
- **Логирование**: Опциональное, настраивается через config

## Troubleshooting

**Ошибка: Config not found**
- Проверьте `SNN_CONFIG_PATH`
- Убедитесь, что файл существует

**Ошибка: CRC mismatch**
- Проверьте алфавит в config
- Убедитесь, что base корректен
- Проверьте key_hex для PRP

**UI не обновляется**
- Убедитесь, что PipelineExecutor вызывается через `await`
- Проверьте, что ViewModel использует `@MainActor`

**Медленная работа**
- Используйте CompactHexDumpView для больших данных
- Ограничьте количество показываемых digits
- Включите production build (-c release)

## Тестирование

```bash
# Запуск CLI для проверки backend
swift run capsule-cli encode "Test text"

# Проверка конфигурации
cat $SNN_CONFIG_PATH | grep capsule -A 10

# Логи
tail -f Logs/baseline.log | grep ui.pipeline
```

## Roadmap

- [ ] Phase 7: Тестирование и отладка
- [ ] Export snapshot в JSON/PDF
- [ ] Сравнение двух snapshots (diff view)
- [ ] Charts для distribution (SwiftUI Charts)
- [ ] Анимации переходов между этапами
- [ ] Router visualization integration
- [ ] Training progress visualization
- [ ] Performance profiling view

## Связанные документы

- [План визуализации](../../Docs/plan_capsule_visualization_incremental.md)
- [План капсюля](../../Docs/plan_reversible_text_capsule_swift_macos.md)
- [План роутера](../../Docs/plan_snn_router_swift_macos.md)

## Лицензия

См. корневой README проекта.
