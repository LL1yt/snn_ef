# Переход на «гистограмма как язык»

Цель
Сделать гистограмму основным смысловым сигналом, а декод текста — опциональным retrieval‑слоем для человека. Обратимость перестает быть критичной. Пайплайн становится: текст → капсула → энергии → входная гистограмма → динамика → выходная гистограмма → метрики схождения, и опционально retrieval‑подпись.

Ключевые принципы
- Гистограмма — основной сигнал и объект обучения.
- Никаких фолбэков: при некорректных данных — fail fast.
- Конфигурация централизована в ConfigCenter; все инварианты валидируются.
- UI и CLI используют одинаковые снапшоты, headless режим обязателен.
- Логирование через LoggingHub, process_id обязателен.

Интеграция идей из Docs/plan_projection_weighting.md
- Вводим projectedHistogram как взвешенный буфер для частиц, не дошедших до границы.
- Правило веса: w = r/R при r <= R и w = R/r при r > R, clamp (0, 1].
- predictedBins без -1 (детерминированно через проекцию).
- Без замены на нули и без fallback‑логики.

Фаза 0. Уточнение архитектурного контракта
1. Зафиксировать в документации, что «истинным» сигналом в обучении и метриках является нормализованная гистограмма, а не последовательность спайков/лучей и не точный декод текста.
2. Зафиксировать два типа гистограмм:
   - inputHistogram: из энергий капсулы.
   - outputHistogram: из динамики роутера.
3. Зафиксировать, что predictedBins используются только для дебага и UI‑подсказок, не как основной сигнал обучения.
4. Зафиксировать инварианты:
   - router.energy_constraints.energy_base == capsule.base.
   - bins == capsule.base.
   - projectedHistogram имеет размер bins.

Фаза 1. Конфиг и схема (ConfigCenter)
1. В Docs/config_center_schema.md добавить секцию histogram_language с параметрами:
   - enabled: Bool (обязателен, без fallback).
   - normalize_input: Bool.
   - normalize_output: Bool.
   - metrics: ["l1", "l2", "cosine"] (строгая валидация множества).
   - retrieval: { enabled: Bool, top_k: Int, corpus_path: String }.
2. В ConfigCenter добавить валидацию:
   - corpus_path обязателен, если retrieval.enabled == true.
   - normalize_* допускает только Bool.
   - metrics список не пуст и без неизвестных значений.
3. Обновить пример профиля в Configs/*.yaml под новую секцию.

Фаза 2. Роутер: вывод гистограмм как первоклассных артефактов
1. В EnergeticRouter сформировать outputHistogram как обязательный результат шага.
2. Интегрировать projectedHistogram по правилам из Docs/plan_projection_weighting.md:
   - Путь «slow/UI» для захвата lastPosByID и вычисления weighted projectedHistogram.
   - predictedBins вычисляются всегда, без -1.
   - Никаких замен на нули, если нет данных — бросаем ошибку.
3. Ввести четкую границу:
   - outputHistogram: основной сигнал.
   - projectedHistogram: UI/диагностика и дополнительная визуальная серия.
4. Везде где доступна outputHistogram, использовать размер bins и проверку соответствия.

Фаза 3. Капсула и входная гистограмма
1. В ReversibleCapsule и BridgeSNN зафиксировать:
   - Input histogram строится из энергий (E = digits + 1), затем нормализация при необходимости.
2. Ввести явное имя для входной гистограммы в общих структурах (например, inputHistogram).
3. Валидация длины inputHistogram == bins без fallback.

Фаза 4. Метрики схождения (L1/L2/cosine)
1. В SharedInfrastructure или EnergeticCore создать единый модуль вычисления метрик.
2. Метрики должны принимать нормализованные гистограммы, если включено normalize_*.
3. Строгая проверка:
   - одинаковый размер массивов,
   - отсутствие NaN/inf,
   - значения в ожидаемых диапазонах (после нормализации).
4. Сохранить результат в LearningLogPayload и CLI‑выводе.

Фаза 5. Логирование и снапшоты
1. Обновить LearningLogPayload:
   - inputHistogram
   - outputHistogram
   - projectedHistogram (optional, UI only)
   - metrics { l1, l2, cosine }
   - predictedBins (debug)
2. LoggingHub: вывести лог под process_id router.step и ui.pipeline.
3. PipelineSnapshotExporter: писать JSON снапшоты с полями гистограмм и метрик в paths.pipeline_snapshot.

Фаза 6. UI (overlay + retrieval‑подпись)
1. LearningMetricsView:
   - Overlay input vs output (главная серия).
   - Опциональный слой projectedHistogram (toggle/legend).
2. Вывести метрики L1/L2/cosine как основные показатели схождения.
3. Retrieval‑подпись:
   - Если retrieval включен, показывать ближайший пример (top‑1) и его дистанцию.
   - Если corpus отсутствует или пуст, бросать ошибку при запуске (без fallback).

Фаза 7. Retrieval‑decode (опционально)
1. Создать модуль поиска по базе гистограмм:
   - corpus хранит пары {histogram, text}.
   - метрика совпадает с выбранной в конфиге.
2. Индексация минимальная (baseline) без дополнительных зависимостей.
3. В UI/CLI показывать только «closest example», не утверждая точность восстановления текста.

Фаза 8. Деприоритет обратимого декода
1. Пометить восстановление текста как debug‑функцию.
2. В местах, где раньше требовался точный декод, заменить на:
   - гистограмму + метрики,
   - retrieval‑подпись (если включено).
3. Удалять/изолировать зависимости, связанные с обязательным round‑trip декодом.

Фаза 9. Тесты (без запуска)
1. Юнит‑тесты на гистограммы:
   - inputHistogram размер == bins.
   - outputHistogram размер == bins.
   - projectedHistogram применяет правила веса корректно.
2. Тесты на метрики:
   - одинаковые гистограммы дают L1=0, cosine=1.
   - нормализация не меняет порядок метрик.
3. Тесты на fail fast:
   - bins mismatch,
   - NaN/inf,
   - пустой retrieval corpus при enabled.

Фаза 10. Валидация поведения и порядок включения
1. Сначала включить histogram_language.enabled в отдельном профиле.
2. Проверить, что UI/CLI читает новые поля, headless работает.
3. Сравнить визуально overlay input vs output и метрики в нескольких сценариях.

Артефакты перехода
- Новый конфиг‑флаг histogram_language.enabled.
- Новые поля в логах и снапшотах.
- UI overlay гистограмм и метрик.
- Retrieval‑подпись как опциональный слой.

Список основных файлов для изменений
- Docs/config_center_schema.md
- Configs/*.yaml
- Sources/SharedInfrastructure/ConfigCenter.swift
- Sources/EnergeticCore/FlowLearningLoop.swift
- Sources/EnergeticCore/FlowProjector.swift
- Sources/EnergeticUI/LearningMetricsView.swift
- Sources/SharedInfrastructure/PipelineSnapshotExporter.swift
- Tests/* (новые тесты для гистограмм и метрик)

Чек-лист PR
1. PR1: Документация и контракт
Scope: зафиксировать гистограмму как основной сигнал, инварианты и новый раздел histogram_language в схеме.
Files: `Docs/plan_histogram_language_transition.md`, `Docs/config_center_schema.md`.
Done when: в схеме есть histogram_language с правилами валидации и обновленным примером baseline.

2. PR2: ConfigCenter + пример профиля
Scope: строгая валидация histogram_language и актуализация Configs/*.yaml.
Files: `Sources/SharedInfrastructure/ConfigCenter.swift`, `Configs/*.yaml`.
Done when: ConfigCenter валидирует metrics/retrieval без fallback и примерные профили содержат новую секцию.

3. PR3: Router outputHistogram + projectedHistogram (slow/UI path)
Scope: сделать outputHistogram обязательным артефактом, projectedHistogram — UI payload.
Files: `Sources/EnergeticCore/FlowLearningLoop.swift`, `Sources/EnergeticCore/FlowProjector.swift`.
Done when: outputHistogram size == bins, predictedBins без -1, projectedHistogram считается по правилу r/R и R/r.

4. PR4: Input histogram из капсулы
Scope: явный inputHistogram и строгая валидация длины.
Files: `Sources/ReversibleCapsule/*`, `Sources/EnergeticCore/*`.
Done when: inputHistogram строится из энергий и валидируется по bins.

5. PR5: Метрики (L1/L2/cosine)
Scope: единый модуль метрик с fail fast.
Files: `Sources/SharedInfrastructure/*` или `Sources/EnergeticCore/*`.
Done when: метрики работают на нормализованных данных, NaN/inf и mismatch кидают ошибку.

6. PR6: Логи и снапшоты
Scope: добавить гистограммы и метрики в payload и снапшоты.
Files: `Sources/SharedInfrastructure/PipelineSnapshotExporter.swift`, `Sources/SharedInfrastructure/LoggingHub.swift`, `Sources/EnergeticCore/*`.
Done when: JSON снапшот содержит input/output/projected + metrics.

7. PR7: UI overlay + retrieval‑подпись
Scope: визуальный overlay и отображение метрик, retrieval как подпись.
Files: `Sources/EnergeticUI/LearningMetricsView.swift`.
Done when: overlay input vs output, projectedHistogram опционален, метрики видимы.

8. PR8: Retrieval‑decode (baseline)
Scope: поиск ближайшего текста по гистограмме.
Files: `Sources/EnergeticCore/*` или `Sources/SharedInfrastructure/*`.
Done when: top‑1 retrieval работает по выбранной метрике, fail fast при пустом корпусе.

9. PR9: Деприоритизация обратимого декода
Scope: убрать зависимость от обязательного round‑trip декода.
Files: `Sources/EnergeticCore/*`, `Sources/ReversibleCapsule/*`, `Sources/EnergeticUI/*`.
Done when: основной сценарий работает без точного декода.

10. PR10: Тесты
Scope: инварианты гистограмм и метрик.
Files: `Tests/*`.
Done when: тесты на размеры, метрики, projectedHistogram и fail fast.
