# Архитектура Macseed

[English](ARCHITECTURE.md) | Русский

## Назначение

Workflow использует Discovery → Blueprint → Preview → Bootstrap на текущем Mac.
Capture оркестрирует эти компоненты в приватном staging исходного Mac и
публикует Bootstrap Bundle. Restore проверяет Bundle, выполняет Preview по
staged input и после подтверждения публикует обычную пару generated/Blueprint
до Bootstrap. Recovery защищает прежнюю локальную пару. Restore Bootstrap
валидирует весь выбранный ввод, подготавливает зависимости и вызывает существующий
consumer SSH configuration и отдельно подтверждённый Secure Credentials import
до клонирования Workspace. Сбой зависимости останавливает дальнейшее восстановление;
позднейшие ошибки не откатывают импортированные identities. Bundle остаётся транспортом:
дальнейший Workflow работает с локальным состоянием без него.

Обычный путь реконструирует выбранное состояние с поддерживаемыми Bootstrap
consumers: программы устанавливаются, репозитории клонируются, настройки
применяются; working trees и пользовательские данные не копируются. SSH
Configuration — воспроизводимые Host profiles. Только явно выбранные SSH
private/public identities проходят отдельную границу зашифрованного Secure
Migration в `secure.age`. Это не общий перенос данных или состояния Mac.

Macseed — модульная Bash-система для обнаружения и
воспроизведения поддерживаемых частей рабочего окружения macOS. Этот документ
определяет текущую ответственность компонентов, поток состояния, границы и
архитектурные инварианты. Последовательность развития описывается в Roadmap, а
форматы и контракты значений — в Configuration.

## Текущая архитектура

```text
Current Mac
    ↓
Discovery
    ↓
Generated Configuration
    ↓
Blueprint / Desired Selection
    ↓
Preview
    ↓
Bootstrap
    ↓
Target Mac
```

Discovery фиксирует поддерживаемое наблюдаемое состояние. Generated
Configuration хранит эти значения для конкретного Mac. Blueprint при
необходимости выбирает область восстановления. Preview показывает
поддерживаемые изменения без их применения. Bootstrap применяет выбранные
значения на целевом Mac.

## Модель состояния и ответственности

Toolkit отделяет наблюдаемые значения от целевого выбора:

```text
Observed State
    ↓
Generated Configuration
    +
Blueprint Desired Selection
    ↓
Selected Supported State
    ├── Preview
    └── Bootstrap
```

- **Observed State** — поддерживаемое состояние, обнаруженное на исходном Mac.
- **Generated Configuration** — локальное представление наблюдаемых значений.
- **Blueprint Desired Selection** — категории и компоненты, включённые в область
  восстановления.
- **Selected Supported State** — пересечение generated-значений, выбора
  Blueprint и текущих возможностей потребителей.

Blueprint не владеет обнаруженными значениями, не копирует и не перезаписывает
их. Preview не владеет конфигурацией и не определяет вторую модель целевого
состояния. Bootstrap не обнаруживает исходное состояние. Эти ответственности
остаются разделёнными.

## Текущие архитектурные контракты

### Discovery

Discovery наблюдает поддерживаемую область, не изменяя её. Цикл публикации
является архитектурным инвариантом:

```text
Collect → Validate → Serialize → Safe Publication
```

Generated-результат заменяется только после успешного полного сбора, проверки и
сериализации кандидата. Обработанная ошибка сохраняет предыдущее валидное
generated-состояние. Discovery фиксирует конфигурацию и метаданные, но не
копирует пользовательские документы или содержимое репозиториев.

### Generated Configuration

`config/generated/` содержит приватное локальное производное состояние
конкретного Mac и исключён из Git. Форматы producer и consumer должны оставаться
совместимыми, а generated-содержимое всегда разбирается как данные и не
выполняется.
Это не хранилище credentials: producers не должны сознательно публиковать здесь
пароли, токены, приватные ключи или credentials внутри URL.

Большинство generated-файлов публикуются независимо. `workspace.conf` также
публикуется отдельно, а `folders.conf`, `repositories.conf`,
`vscode-workspaces.conf` и `inventory.conf` образуют одну группу согласованности
и публикуются как единый снимок Workspace.

Generated-состояние может содержать личные пути, Git identity, URL репозиториев
и настройки редактора. Непрозрачные snapshots VS Code и Zsh могут содержать
чувствительные данные; общей гарантии отсутствия секретов нет. Generated-состояние
необходимо проверять и защищать перед внешним переносом. Точные форматы и правила
переносимости определены в [Configuration](CONFIGURATION.md).

### Blueprint

Blueprint проверяет и хранит Desired Selection в приватном локальном
`config/blueprint.conf`. Он выбирает обнаруженные категории и компоненты, не
дублируя их значения из Generated Configuration.

При отсутствии Blueprint потребители сохраняют совместимое all-inclusive
поведение для поддерживаемой generated-области. Старый Blueprint без более
новой категории остаётся валидным и сохраняет эту категорию выключенной до
явной миграции.

### Preview

Preview — неизменяющий режим существующей модели восстановления. Он использует
те же Generated Configuration, Blueprint Desired Selection, правила проверки и
семантику наблюдения, что и Bootstrap, а не создаёт вторую модель целевого
состояния.

Preview показывает планируемые поддерживаемые изменения, отличает ошибку
наблюдения от подтверждённого отсутствия или несовпадения и не изменяет целевое
состояние. Он не владеет конфигурацией и не перезаписывает её. Его результат
может разрешать или блокировать Bootstrap в Guided Workflow.

### Bootstrap

Bootstrap применяет выбранные поддерживаемые значения через локальный цикл
модулей:

```text
Check → Apply → Verify
```

Обязательный выбранный ввод проверяется до мутации. Ошибка наблюдения отличается
от допустимого отсутствия или несовпадения и не должна превращаться в «требуется
Apply». Модули применяют только подтверждённо необходимые изменения, сохраняют
существующие данные при сомнениях в безопасности и остаются идемпотентными.

Verify — локальная проверка после Apply, выполняемая, когда модуль способен
наблюдать итоговое управляемое состояние. Она не означает сводную проверку всего
Mac или визуального эффекта за пределами заявленного контракта модуля.

Discovery метаданных VS Code Workspace и генерация
`vscode-workspaces.conf` реализованы. Bootstrap-восстановление
`.code-workspace` намеренно не подключено до появления безопасного потребителя
восстановления.

### Граница Core

`modules/core/` отвечает за общие механизмы вывода, логирования, оркестрации
жизненного цикла модулей, preflight, конфигурационную инфраструктуру и базовые
сервисы окружения. Предметное поведение Discovery, Preview и Bootstrap остаётся
за пределами Core.

Производители и потребители настроек macOS используют общую границу
типизированных поддерживаемых записей. Восстановление снимков экрана также
затрагивает безопасность файловой системы; правила путей, переносимости и
поведение категории определены в [Configuration](CONFIGURATION.md) и здесь не
дублируются.

## Guided Workflow

Guided Workflow оркестрирует существующие режимы, а не вводит ещё один источник
конфигурации или движок целевого состояния:

```text
Readiness / optional Discovery
    ↓
Blueprint
    ↓
Preview
    ↓
Conditional Bootstrap
```

Отмена Blueprint останавливает Workflow. Ошибки Preview блокируют Bootstrap.
При наличии планируемых изменений Bootstrap требует явного подтверждения
пользователя; при отсутствии изменений Bootstrap не запускается. Каждый базовый
режим сохраняет собственную ответственность, проверку, логирование, Summary и
публичную семантику статусов. Перед фактическим Apply входные данные повторно
проверяются там, где это требуется. Состояние между Preview и подтверждением не
замораживается. Global Verification наблюдает выбранное состояние после
Bootstrap или после Preview, когда Bootstrap не запускается.

## Граница проверки

Локальный Verify остаётся частью жизненного цикла модулей. Global
Verification выполняет read-only проверку после Bootstrap, включая Restore
Bootstrap, и после Preview в Workflow, когда Bootstrap не запускается.
Проверяются выбранные Homebrew formulae и casks, App Store application IDs,
прямые global-значения Git, поддерживаемые payload SSH и Zsh config,
VS Code extension IDs и settings payload, Workspace folders и
worktree/origin/branch репозиториев, generated settings Finder, Dock, Windows,
Keyboard, Trackpad и Screenshots. SSH identities остаются вне покрытия.
При отказе Restore prerequisite
отчёт также строится. Ошибки startup validation/preflight и отмена до Preview
сохраняют прежний ранний выход без verification pass.

Predicates сохраняют семантику production readers: установка не подтверждает
работоспособность приложения, равенство файлов не доказывает применение
настроек приложением, а macOS checks подтверждают сохранённые значения и типы
preferences, без проверки UI effect. Location preference и destination
directory Screenshots наблюдаются независимо. Отсутствие `mas` или `code`
оставляет выбранные items unverified; verifier не устанавливает зависимости.
Zsh сохраняет границы ownership snapshot и не добавляет требований к permissions
для идентичного содержимого target.

Поток данных:

```text
Generated + Blueprint → resolved scope + unresolved references
                      → production domain readers → collector → report
```

`modules/core/verification/verification.sh` хранит внутренние Verification,
Coverage, Operation и Diagnostic records и считает детерминированные агрегаты.
Сравнения принадлежат consumers; `modules/verification/verification.sh`
разрешает scope и вызывает readers. Records содержат идентичность subject и
predicate, без копирования desired values. Это данные текущего Bash-процесса,
не публичный API и не постоянное хранилище результатов.

Conformity (`verified`, `mismatch`, `unverified`), поддержка проверки, coverage и
diagnostics независимы. Ошибка операции может сочетаться с подтверждённым
конечным состоянием. Partial source warning SSH не отменяет совпадение
поддерживаемого payload. Stale references остаются unresolved; отсутствие
requirement не становится verified. Происхождение старых source inventory
остаётся unknown, если snapshot явно его не описывает.

Контекст связывает records с origin, digest ввода, интервалом наблюдений и
операциями. Идентичность ввода проверяется до и после прохода; изменение или
невалидный ввод делает отчёт incomplete. Наблюдение target последовательно,
а не атомарно. Resolved predicates делятся по conformity; unsupported —
подмножество unverified, unresolved references и diagnostics считаются отдельно.
Вердикта готовности нет. Публичные exit codes сохраняют семантику выполнения
команды и не доказывают соответствие окружения. Verifier не запускает Discovery
publication, установку, clone/checkout, запись preferences или restart процессов.
Временные файлы для валидации допустимы.

## Планируемая граница Core/GUI

Нативное приложение на SwiftUI будет слоем представления и оркестрации над
существующим Core. Оно использует стабильный машиночитаемый интерфейс для
Discovery, выбранного окружения, Preview, Verification и результатов операций,
а не разбирает сообщения CLI или логи. Core сохраняет ответственность за
валидацию, планирование и мутации; GUI не переписывает Discovery, Blueprint,
Preview, Bootstrap, Capture или Restore на Swift.

## Владение документацией

Этот документ описывает устойчивые архитектурные ответственности и границы.
Текущие форматы и контракты значений находятся в
[Configuration](CONFIGURATION.md), эксплуатационное поведение — в [CLI](CLI.md)
и [Quick Start](../getting-started/QUICKSTART.md), направление развития — в
[ROADMAP.md](../../ROADMAP.md), ближайшие задачи — в [TODO.md](../../TODO.md), а
история завершённых изменений — в [CHANGELOG.md](../../CHANGELOG.md).

Вернуться к [основному README](../../README.md).
