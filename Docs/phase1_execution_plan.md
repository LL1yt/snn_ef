# Фаза 1 · Инфраструктурный каркас (Config + Логи + Placeholder UI)

_Цель:_ получить минимально рабочий костяк с единой конфигурацией, базовым логированием и заглушками UI, покрывая каждый шаг тестами.

## Шаг 1. ConfigCenter MVP
- [ ] Реализовать загрузку YAML (`Docs/config_center_schema.md`) → `ConfigSnapshot`.
- [ ] Проверка обязательных ключей, валидация `capsule.base == router.energy_constraints.energy_base`.
- [ ] Юнит-тесты: happy-path конфиг, отсутствующий ключ, несогласованные базы.
- [ ] CLI-флаг `--config` подключить к `CapsuleCLI` и `EnergeticCLI` (пока просто читает файл, логирует успех).

## Шаг 2. LoggingHub маршрутизация
- [ ] Конфигурируемые destination: stdout + файл (`Logs/*.log`).
- [ ] Поддержка override уровней по `process_id`.
- [ ] Тесты:форматирование события, honor override, файл создаётся.
- [ ] Добавить метрику времени (relative) и вытащить в `LogEvent`.

## Шаг 3. ProcessRegistry & Diagnostics
- [ ] Загрузка реестра из конфига (override, merge с дефолтом).
- [ ] Тест: неизвестный alias → error.
- [ ] Diagnostics.fail → лог и `preconditionFailure` (ловим в тестах).

## Шаг 4. CLI wire-up
- [ ] `CapsuleCLI` читает конфиг, логирует `capsule`-секцию, выводит подсказку по UI/бенчмарку.
- [ ] `EnergeticCLI` аналогично для `router`.
- [ ] Интеграционный тест: запуск через `swift test --filter` с фиктивным конфигом (используем `Process.run`).

## Шаг 5. UI заглушки + снимок пайплайна
- [ ] CapsuleUI: отображение `pipeline_example_text`, базовых параметров из конфига.
- [ ] EnergeticUI: отображение размеров решётки, top-K.
- [ ] Подготовить JSON-снапшот (пока статический) и кнопку «Reload» (SwiftUI `@State`).
- [ ] Снапшот тест: проверка, что файл создаётся в `paths.pipeline_snapshot`.

## Шаг 6. CI Hook (опционально в фазе 1)
- [ ] Скрипт `Scripts/run_checks.sh`: `swift test`, статический анализ (пока `swift build`).
- [ ] Документировать команду в README.

_Выходные артефакты:_ собирающийся пакет (`swift build`), зелёные юнит-тесты, лог-файл в `Logs/`, первичный UI предпросмотр.
