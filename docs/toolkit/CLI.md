# CLI, Output and Logging

## Назначение

Этот документ определяет единый контракт пользовательского CLI-вывода и
диагностического логирования Macseed.

Обе части используют общий Logger, но имеют разные задачи:

- **CLI Output** показывает пользователю текущее действие и итог выполнения;
- **History Logging** сохраняет диагностическую историю запуска.

Бизнес-логика Toolkit не должна зависеть от способа отображения или сохранения
сообщений.

---

# Основные принципы

- Quiet by Default;
- Verbose When Needed;
- единый формат сообщений;
- понятные секции и статусы;
- обязательный итоговый Summary;
- диагностические подробности сохраняются в history log;
- один результат не должен многократно сообщаться пользователю;
- Logger представляет и сохраняет информацию, но не принимает domain-решения.

---

# Типы сообщений

```text
[....] Action
[ OK ] Success
[WARN] Warning
[ERROR] Error
[INFO] Information
```

## Action

Показывает выполняемое действие.

```text
[....] Installing Homebrew packages...
```

## Success

Показывает успешное завершение операции.

```text
[ OK ] Homebrew already installed
```

## Warning

Показывает ситуацию, которая требует внимания, но не обязательно останавливает
работу Toolkit.

```text
[WARN] Configuration file not found
```

## Error

Показывает ошибку, из-за которой операция не может быть нормально завершена.
Сообщение должно по возможности объяснять причину проблемы.

```text
[ERROR] Bootstrap failed
```

## Info и Detail

`info()` показывает информационное сообщение пользователю и записывает его в
лог.

Для диагностических подробностей, которые должны появляться на экране только с
`--verbose`, используется `detail()`.

History log сохраняет диагностическую информацию независимо от того, была ли
каждая подробность показана в стандартном CLI-выводе.

---

# Режимы CLI-вывода

## Standard / Quiet

Стандартный режим показывает только информацию, необходимую для понимания
выполнения:

- основные действия;
- успешные результаты;
- предупреждения;
- ошибки;
- итоговый Summary.

Пример:

```text
==========================================
 Homebrew Packages
==========================================
[ OK ] All Homebrew packages are installed.
```

Интерактивный Blueprint selector является отдельным workflow: selection state и
prompts необходимы пользователю для принятия решений, поэтому его интерфейс не
обязан быть таким же кратким, как неинтерактивный вывод.

## Verbose

`--verbose` дополняет обычный вывод диагностическими подробностями, контекстом
ошибок и внутренними этапами выполнения там, где это полезно.

Verbose не меняет семантику выполнения Toolkit. Blueprint selector может иметь
мало видимых отличий в verbose-режиме, поскольку уже показывает необходимую
пользователю информацию.

---

# Секции

Основные компоненты Toolkit по возможности используют единый формат секций:

```text
==========================================
 Homebrew
==========================================
[ OK ] Homebrew already installed
```

Секция помогает быстро определить текущий или уже обработанный компонент.

---

# Результаты выполнения

Toolkit различает следующие состояния:

- **Success** — операция успешно завершена;
- **Changed / Installed** — существующий lifecycle фактически изменил состояние;
- **Unchanged / Skipped** — изменение не требовалось;
- **Warning** — работа продолжена, но требуется внимание;
- **Error** — операция не была успешно завершена.

Preview выводит planned actions через `Would ...`; отдельный статус
`Planned` не используется. Сами planned actions возвращают `0`.

---

# Summary

Summary зависит от режима и контекста запуска и не должен дублировать детальный
lifecycle из history log.

## Lifecycle/count Summary

Check и Bootstrap без Blueprint используют существующий Summary
жизненного цикла. Он может включать:

```text
Modules Checked
Installed
Skipped
Warnings
Errors
Duration
```

Пример:

```text
==========================================
 Summary
==========================================
[ OK ] Bootstrap completed successfully

------------------------------------------
Modules Checked : 11
Installed       : 0
Skipped         : 11
Warnings        : 0
Errors          : 0
------------------------------------------
Duration        : 15s
```

Discovery использует отдельный набор полей:

```text
Modules Processed : 12
Warnings          : 0
Errors            : 0
```

`Modules Processed` — существующий счётчик вызовов `run_module()`, включая
четыре общих Core-модуля и восемь Discovery-модулей при полном проходе.
Это не число обнаруженных компонентов или опубликованных файлов. `Warnings`
и `Errors` сохраняют существующий учёт результатов lifecycle, включая ошибку
preflight; они не считают каждое отдельное сообщение. При остановке на
preflight число обработанных модулей равно нулю. Поля `Installed` и `Skipped`
в Discovery Summary не выводятся. `Duration` сохраняется при наличии времени
начала запуска. Терминал и лог содержат одинаковые поля и значения.

Проверка Homebrew в Discovery не предлагает установку: при подтверждённом
отсутствии Homebrew inventory не публикуется, а запуск сообщает ошибку
prerequisite. Ошибка самой проверки доступности сообщается отдельно.

Во всех режимах headline определяется lifecycle-счётчиками с приоритетом:

```text
ERROR_COUNT > 0
→ <Mode> completed with errors

иначе WARNING_COUNT > 0
→ <Mode> completed with warnings

иначе
→ <Mode> completed successfully
```

Ошибки имеют приоритет над предупреждениями. Success-only выполнение сохраняет
exit status `0`, warning-only — `1`, выполнение с ошибкой — `2`. Отрисовка
Summary не меняет счётчики или итоговый lifecycle status.

## Blueprint selector Summary

Интерактивный selector перед Save показывает selection Summary: selected / total
для item-категорий и Yes / No для категорий настроек. Это подтверждение выбора,
а не Summary выполнения Bootstrap.

## Blueprint-aware Bootstrap Summary

Bootstrap с Blueprint показывает выбранный scope и результат выполнения.
Например:

```text
Applications
  Homebrew packages      28 / 28 selected
  Homebrew casks          3 / 16 selected

Workspace
  Folders                 2 / 4 selected

Settings
  Git Configuration      Enabled
  VS Code Settings       Skipped

Result
  Warnings               0
  Errors                 0

Duration                 15s
```

`Enabled` означает «выбрано в Blueprint», а не «изменено в текущем запуске».

---

# History Logging

Каждый запуск Toolkit сохраняет историю в:

```text
logs/
    latest.log
    history/
```

`logs/latest.log` содержит последний запуск, а `logs/history/` — отдельные
исторические логи.

Имена history-файлов соответствуют режиму:

```text
check-YYYY-MM-DD_HH-MM-SS.log
bootstrap-YYYY-MM-DD_HH-MM-SS.log
discover-YYYY-MM-DD_HH-MM-SS.log
blueprint-YYYY-MM-DD_HH-MM-SS.log
```

Логи являются локальными рабочими файлами Toolkit и не должны попадать в Git.

Каждая запись содержит timestamp, например:

```text
2026-08-10 19:16:45 [ OK ] Bootstrap completed successfully
```

---

# Module Lifecycle в логах

Основные модули могут фиксировать диагностический lifecycle:

```text
[MODULE] START: Homebrew
[MODULE] Changed: No
[MODULE] RESULT: SUCCESS
```

При изменении:

```text
[MODULE] Changed: Yes
```

Другие результаты:

```text
[MODULE] RESULT: WARNING
[MODULE] RESULT: ERROR
[MODULE] RESULT: UNKNOWN
```

`UNKNOWN` используется для неожиданного кода завершения.

Эти записи предназначены прежде всего для диагностики и не должны перегружать
стандартный CLI-вывод.

## Blueprint Lifecycle

Blueprint использует минимальный lifecycle:

```text
[BLUEPRINT] START
[BLUEPRINT] Generated configuration: Ready
[BLUEPRINT] Existing configuration: Valid
[BLUEPRINT] RESULT: SAVED
```

При отмене:

```text
[BLUEPRINT] RESULT: CANCELLED
```

`q` или `Q` отменяет Blueprint из любого интерактивного prompt, включая
nested Edit. Отмена немедленно прекращает selector, не публикует частичный
выбор и сохраняет существующий `config/blueprint.conf` без изменений. Если
файла не было, он не создаётся. В Guided Workflow отмена также останавливает
весь Workflow до Preview и Bootstrap.

`Existing configuration: Valid` записывается только после успешной валидации.
При stale или malformed Blueprint сохраняются существующие warning/error
семантики без ложной записи `Valid`.

Выбранные элементы, checkbox-операции, ответы по категориям и содержимое
`config/blueprint.conf` намеренно не копируются в lifecycle log. Источником
состояния выбора остаётся сам Blueprint.

---

# Прерывание Toolkit

Logging System обрабатывает `INT` и `TERM`.

При прерывании в лог записывается:

```text
[WARN] Toolkit interrupted
Finished : YYYY-MM-DD HH:MM:SS
Duration : Ns
Status   : Interrupted
```

После этого текущий лог сохраняется как `latest.log`. Это позволяет отличать
успешное, ошибочное и прерванное завершение и сохранять диагностический контекст.

---

# Dry-run / Preview

`--dry-run` является отдельным execution mode. Одновременно можно выбрать
ровно один из `--check`, `--bootstrap`, `--discover`, `--blueprint`,
`--dry-run`, `--compare`, `--workflow`, `--capture` и `--restore <bundle>`; отсутствие mode
или конфликтующие mode-флаги
возвращают `1`.

Preview выполняет последовательность:

```text
CLI parse → Logger → Blueprint validation → selected input validation
→ read-only preflight → read-only Core inspection
→ domain Preview → Summary → exit code
```

Он не вызывает `sudo -v`, не устанавливает Homebrew и не запускает Bootstrap
mutations. Applications, Git configuration, SSH configuration, VS Code settings,
Zsh, Workspace и macOS Preview используют
существующие validators, Blueprint selection и inspection helpers и могут
вывести:

```text
Would install Homebrew formula: <name>
Would install Homebrew cask: <name>
Would reinstall Homebrew cask: <name>
Would install App Store app: <name> (<id>)
Would install VS Code extension: <id>
Would configure Git setting: <key>
Would update VS Code settings
Would restore Zsh configuration
Would restore SSH configuration: <count> eligible profiles
Would create workspace folder: <path>
Would clone repository: <id>
Would switch repository branch: <id> -> <branch>
Would change macOS setting: <domain/key> (<current> -> <desired>)
Would change macOS setting: <domain/key> (absent -> <desired>)
Would create screenshots directory: <path>
Would restart process: <process>
```

Уже соответствующие состоянию и невыбранные элементы не выводятся как planned
actions. Сами planned actions сохраняют status `0`; observation error возвращает
`2`. Summary Preview показывает `Modules Inspected`, `Warnings` и `Errors`, без
Bootstrap-полей `Installed` и `Skipped`. Stale Blueprint сохраняет warning
status; malformed Blueprint или обязательный selected input возвращает `2`.
Отсутствующий optional source VS Code settings сохраняет warning status.
Workspace Preview сохраняет текущую warning-политику для dirty repositories,
remote mismatch и существующих non-Git destinations. После clone-плана он не
предполагает будущую branch state. macOS Preview использует typed defaults
inspection; один restart-план выводится для изменяемой Finder, Dock или
Screenshots category независимо от количества изменяемых settings. Для Screenshots
mkdir-only plan не требует restart: проверяются generated destination и
filesystem, даже если preference уже совпадает. Порядок планов — directory →
preference → restart; unsafe destination возвращает `2` до actionable output.
План создания каталога использует существующий Preview change signal, поэтому
Guided Workflow предлагает Bootstrap confirmation и для directory-only change.

Порядок domain inspections: Homebrew formulae → casks → App Store → VS Code
extensions → Git configuration → VS Code settings → Zsh → SSH configuration →
Workspace folders → repositories → macOS. Disabled selections сохраняют
существующую фильтрацию.

Ошибки startup validation и preflight останавливают запуск. После ошибки Core
или domain inspection последующие read-only inspections продолжаются;
ошибка сохраняется в общем accounting и итоговый exit code равен `2`.
Внутри domain helper ошибка может остановить оставшиеся items этого helper.
Warnings без errors дают `1`; planned actions без warnings/errors дают `0`.
`Modules Inspected` считает вызовы inspection wrapper, включая Core и Blueprint
validation при его наличии; это не число items. Terminal и logger используют
одинаковые Summary counters, без `MODULE_CHANGED`, Installed или Skipped.

---

# Архитектурное правило

```text
Module
   ↓
Result
   ├── CLI Presentation
   └── History Logging
```

CLI объясняет пользователю, что происходит и чем завершилась операция.
Logging сохраняет необходимый диагностический контекст и историю.

Logger не содержит бизнес-логику. Решения о состоянии системы, конфигурации и
необходимых действиях принимают соответствующие модули.

Реализованные режимы:

```text
Check
Discovery
Blueprint
Bootstrap
Preview (`--dry-run`)
Environment Comparison (`--compare`)
Guided Workflow (`--workflow`)
Capture (`--capture`)
Restore (`--restore <bundle>`)
```

`bs compare` / `./bootstrap.sh --compare` явно сравнивает выбранное эталонное
окружение с текущим Mac. Режим использует текущие Blueprint и
`config/generated/`, проецирует существующие Verification/Coverage facts и
ничего не применяет или не удаляет. Discovery, Bootstrap Apply и
административный preflight не запускаются; Blueprint, Generated Configuration
и target state не изменяются. Общая инфраструктура создаёт лог.

Отчёт различает `matching`, `missing`, `differing`, `unverified` и поддерживаемые
`extra`. Последние доступны для Homebrew casks, App Store IDs и VS Code
extension IDs только при полной provenance исходного inventory и успешном
наблюдении target inventory. Лишние Homebrew formulae не определяются:
исходный inventory формул не является полным списком установленных формул.
Comparison не запускается автоматически после Bootstrap, Workflow или Restore.
Код `0` означает завершённый observation pass независимо от verdict; `2` —
неполный run, `1` — ошибку CLI.

---

# Guided Workflow

`--workflow` выполняет существующие режимы последовательно: проверка Generated
Configuration → optional/required Discovery → interactive Blueprint → automatic
Preview → optional Bootstrap. Каждый запущенный этап сохраняет собственный
Logger и Summary.

Отмена Blueprint через `q` / `Q` или отказ от финального Save останавливает
Workflow до Preview и Bootstrap. Ошибка Preview (`2`) также останавливает
Workflow. При status `0` или `1` и наличии planned changes Toolkit спрашивает:

```text
Apply these changes with Bootstrap? [y/N]
```

Только явный Yes запускает существующий Bootstrap path. Если planned changes
нет, подтверждение не показывается, Bootstrap не запускается, а Workflow
выводит:

```text
[ OK ] No changes to apply
[INFO] Workflow finished.
```

Warning status Preview при этом сохраняется как итоговый status `1`. Global
Verification наблюдает выбранное состояние после Bootstrap или после Preview,
когда Bootstrap не запускается; отдельная Comparison остаётся явной командой.

---

# Короткий launcher `bs`

Канонической точкой входа остаётся `./bootstrap.sh --<mode>`. Опциональный
repository-owned launcher `bin/bs` только сопоставляет короткие команды с
существующими production modes:

```text
bs workflow   → bootstrap.sh --workflow
bs capture    → bootstrap.sh --capture
bs restore <bundle> → bootstrap.sh --restore <bundle>
bs discover   → bootstrap.sh --discover
bs blueprint  → bootstrap.sh --blueprint
bs preview    → bootstrap.sh --dry-run
bs compare    → bootstrap.sh --compare
bs bootstrap  → bootstrap.sh --bootstrap
bs check      → bootstrap.sh --check
```

`bs`, `bs help`, `bs --help` и `bs -h` показывают краткую справку. Неизвестная
команда возвращает non-zero status без dispatch. После определения реального
расположения launcher переходит в корень Toolkit и использует `exec`, поэтому
repository-relative paths и exit status `bootstrap.sh` сохраняются.

При первом запуске пользователь по-прежнему вызывает канонический entrypoint.
Когда `--workflow` доходит до Bootstrap или напрямую выполняется
`./bootstrap.sh --bootstrap`, Bootstrap автоматически запускает launcher
setup с lifecycle `Check → Apply → Verify`. Корректный `bs` остаётся unchanged;
отсутствующий устанавливается существующим installer и проверяется повторно.
Ошибка installer или Verify возвращает Bootstrap error без ложного success.
Исключение для Restore без Homebrew: отсутствующий launcher откладывается с
предупреждением `1`; используйте `./bootstrap.sh` из корня репозитория.

Discovery, Blueprint, Preview и Comparison не запускают installer. Workflow,
завершившийся после zero-change Preview, также не устанавливает `bs`. Ручная установка и
repair остаются доступны. Launcher self-setup не отображается как domain
Preview plan: это отдельная Bootstrap self-setup операция.

```bash
./scripts/install-bs.sh
```

Installer выбирает `$(brew --prefix)/bin`, если Homebrew доступен, иначе
архитектурно подходящий стандартный каталог. Корректная существующая ссылка
считается успешной установкой; посторонняя команда, ссылка или файл `bs` не
перезаписывается. Конфликт, unwritable destination и failure проверки являются
Bootstrap error `2`; sudo автоматически не вызывается. Перемещение репозитория
нарушает PATH symlink, поэтому старую ссылку нужно удалить и запустить installer
из нового расположения.

# Capture и Restore

Рекомендуемые entry points: `bs workflow` для этого Mac; `bs capture` на
исходном Mac → приватный перенос одного `.mbt` → `bs restore <bundle>` на
новом Mac. Если launcher ещё не установлен, из корня репозитория доступны
`./bootstrap.sh --workflow`, `./bootstrap.sh --capture` и
`./bootstrap.sh --restore /absolute/path/bundle.mbt`. Отдельные `--discover`,
`--blueprint`, `--dry-run`, `--bootstrap` и standalone Secure SSH Migration
CLI — ручные/advanced команды, не обязательные этапы этого сценария.

`bs capture` запускает Discovery и подробный Blueprint selector в приватном
staging, не меняя рабочий `config/blueprint.conf`. Затем предлагает отдельно
выбрать SSH identities и создаёт один приватный `exports/bootstrap-*.mbt`
Bundle. При выборе identities отсутствие `age` приводит к явному предложению
установки через Homebrew; без согласия можно продолжить без них или отменить
Capture. Capture показывает кандидатов без повторного unlock, затем полностью
проверяет выбранный SSH key из приватного staging перед шифрованием. `age`
запрашивает новый passphrase для `secure.age`, отличный от SSH-key passphrase;
он нужен при Restore на новом Mac и должен храниться отдельно от Bundle.
Если оставить prompt пустым, `age` показывает автоматически созданный
passphrase один раз — его также нужно сохранить. Путь к готовому Bundle
выводится после полной публикации.

Здесь два независимых секрета: **SSH-key passphrase** уже принадлежит
конкретному private key и нужен для его unlock/validation; **Bundle passphrase**
создаётся заново для шифрования `secure.age` и
требуется на целевом Mac. Введённый passphrase не выводится и не пишется в
Bundle или лог. Автоматически созданный `age` passphrase показывается один раз.

`bs restore <bundle>` требует один путь к Bundle; launcher разрешает
относительный путь до перехода в корень репозитория. Restore проверяет Bundle,
показывает выбранные категории (`Enter` — продолжить, `C` — отключить
категории, `Q` — отменить). Выбор источника задаёт верхнюю границу: Restore
не добавляет отсутствующие категории и элементы. Затем Restore запускает
обычный Preview по staged input и запрашивает подтверждение Apply. После этого
публикует normal state в `config/generated/` и `config/blueprint.conf`,
запускает Bootstrap с подготовкой выбранной SSH configuration и выбранным
SSH import до Workspace. Полная повторная валидация ввода и preflight
предшествуют этим операциям; импорт требует отдельного подтверждения `import`.
На чистом Mac Restore Preview показывает необходимость Homebrew для выбранных
formulae/casks; Bootstrap отдельно спрашивает разрешение на его установку.
Если `age` всё ещё отсутствует, Restore явно предлагает установку через
Homebrew. Перед расшифровкой Restore поясняет, что требуется passphrase от
Secure Credentials в Bundle. Конфликт SSH configuration, отказ или ошибка SSH
import останавливают дальнейшее восстановление до Workspace. Уже выполненные
изменения сохраняются для повторного Restore.
Отмена Blueprint в Capture оставляет рабочий Blueprint без изменений и не
публикует Bundle. Отмена Restore до Apply не публикует staged state; перед
выбором может выполняться recovery прежней прерванной публикации. Ошибка до
завершения публикации восстанавливает прежнюю пару generated/Blueprint или
останавливает запуск для ручной проверки. Bootstrap запускается только
после успешной публикации; ошибка до SSH prerequisites блокирует их при
валидации или preflight, а позднейшая ошибка не откатывает импорт. Обычный
контракт статусов `0` / `1` / `2` сохраняется.

Bundle v1 и безопасная публикация локального состояния описаны в
[Configuration](CONFIGURATION.md). Bundle переносится выбранным пользователем
способом; Toolkit не реализует транспорт. Повторный Restore использует
идемпотентность существующего Bootstrap и отдельно повторяет ожидающий SSH
import.

# Secure SSH Identity Migration

Отдельная команда `scripts/ssh-identity-migrate.sh` поддерживает `list`,
`export --output /absolute/path/package.age` и
`import --input /absolute/path/package.age`. Контракт и ограничения описаны в
[Secure SSH Identity Migration](SSH-IDENTITY-MIGRATION.md).
