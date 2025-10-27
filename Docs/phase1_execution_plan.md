# Фаза 1 · Инфраструктурный каркас (Config + Логи + Placeholder UI)

_Цель:_ получить минимально рабочий костяк с единой конфигурацией, базовым логированием и заглушками UI, покрывая каждый шаг тестами.

## Шаг 1. ConfigCenter MVP
- [x] Реализовать загрузку YAML (`Docs/config_center_schema.md`) → `ConfigSnapshot`.
- [x] Проверка обязательных ключей, валидация `capsule.base == router.energy_constraints.energy_base`.
- [x] Юнит-тесты: happy-path конфиг, отсутствующий ключ, несогласованные базы.
- [x] CLI-утилиты автоматически читают `Configs/baseline.yaml` (без флагов); при отсутствии файла — fail-fast.

## Шаг 2. LoggingHub маршрутизация
- [x] Конфигурируемые destination: stdout + файл (`Logs/*.log`).
- [x] Поддержка override уровней по `process_id`.
- [x] Тесты:форматирование события, honor override, файл создаётся.
- [x] Добавить метрику времени (relative) и вытащить в `LogEvent`.

## Шаг 3. ProcessRegistry & Diagnostics
- [x] Загрузка реестра из конфига (override, merge с дефолтом).
- [x] Тест: неизвестный alias → error.
- [x] Diagnostics.fail → лог и `preconditionFailure` (для тестов доступен `failForTesting`).

## Шаг 4. CLI wire-up
- [x] `CapsuleCLI` читает конфиг (поддержка `SNN_CONFIG_PATH`), логирует `capsule`-секцию, выводит подсказку по UI/бенчмарку.
- [x] `EnergeticCLI` аналогично для `router`.
- [x] Интеграционный тест: запуск через `Process.run` с временным конфигом.

## Шаг 5. UI заглушки + снимок пайплайна
- [x] CapsuleUI: отображение `pipeline_example_text`, базовых параметров из конфига.
- [x] EnergeticUI: отображение размеров решётки, топологии и последних событий лога.
- [x] Подготовить JSON-снапшот (PipelineSnapshotExporter) + кнопки Export/Reload.
- [x] Тесты: snapshot export/load, CLI интеграция через `Process.run`.

## Шаг 6. CI Hook (опционально в фазе 1)
- [ ] Скрипт `Scripts/run_checks.sh`: `swift test`, статический анализ (пока `swift build`).
- [ ] Документировать команду в README.

_Выходные артефакты:_ собирающийся пакет (`swift build`), зелёные юнит-тесты, лог-файл в `Logs/`, первичный UI предпросмотр.
