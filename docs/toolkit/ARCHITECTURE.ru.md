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

## Secure SSH Restore в режиме приложения

Будущий launcher Desktop создаёт анонимную соединённую пару Unix stream sockets
и передаёт endpoint Core как унаследованный FD больше 2:
`modules/core/application-interface/core.sh --secure-fd N`. Это launch metadata,
а не параметр JSON. Core проверяет FD и отключает наследование; дочерние утилиты
определения путей закрывают его до запуска. Без корректного канала сохраняется
`secure_bridge_required`. Обычные JSON stdin и JSONL stdout передают только
данные операции и безопасные события.

Кадр приватного канала начинается с четырёхбайтовой unsigned длины body в
big-endian (1–2048 bytes). Challenge содержит JSON только с метаданными:
`type=challenge`, `protocol_version=1`, `operation_id`, новый `challenge_id`
из 32 hex digits, `kind` и `attempt` (1–3). Типы: `bundle_unlock`,
`ssh_key_unlock`, `import_confirmation`. Ответ бинарный: 16 bytes challenge ID,
затем `S` и UTF-8 passphrase, только `Y` для подтверждения либо только `C` для
отмены. Passphrase ограничен 128 bytes, управляющие символы запрещены.
JSON-ответ, чужой ID, незапрошенный ввод, неверная длина, EOF и timeout блокируют
операцию. Полный ответ ожидается не более 120 секунд, secret-consuming tool —
30 секунд. Peer сохраняет endpoint открытым до закрытия Core либо намеренной
отмены. Постоянный listener и filesystem IPC для секретов не создаются.

Execute повторяет Prepare, проверяет ожидаемый план и readiness, повторно
сверяет fingerprints source/stage и публикует обычную пару перед импортом
`secure.age` именно из staging текущей операции. Core запускает существующий
importer Stage 12 в отдельной process group и передаёт challenges через вторую
анонимную socket pair. Только importer наследует этот внутренний FD. Дочерний
secret-consuming tool получает только отдельный PTY и, для age, pinned ciphertext
FD. Echo выключен до записи секрета; PTY не становится controlling TTY Core,
его prompts/output не попадают в JSONL или логи. Bundle unlock и unlock отдельного
защищённого ключа различаются; каждый ограничен тремя попытками. Шифрование ключей
и их проверка сохраняются. Подтверждение import использует приватный канал;
полностью совпадающий план не требует подтверждения или публикации.

Сохраняются protected staging Stage 12, проверки payload и key pair, target plan,
conflict checks, no-clobber publication, permissions и cleanup. Непосредственно
перед созданием `.ssh` либо первой публикацией identity в существующий каталог
importer требует от Core подтверждения mutation boundary. Ввод passphrase,
расшифровка и валидация сами по себе не означают target mutation. После boundary
флаг остаётся true даже при удалении importer только собственных новых файлов.
EOF peer, отмена и SIGTERM Core останавливают owned process group. Cleanup после
SIGKILL или потери питания не гарантируется. На время удаления приватного
staging сигналы отмены откладываются.

Core проверяет существующее evidence importer с привязкой к attempt и закрывает
secret channel до обычного Bootstrap. Bootstrap получает только non-secret
evidence через анонимный временный файловый FD, читает и закрывает его до запуска
других children. Production Global Verification сохраняет
`identity_pair_matches_package`, без утверждений о remote authentication,
Keychain или agent. При типизированном сбое importer evidence также используется
для Verification, если доступно; transport failure может оставить её not run.
Неуспешный secure import останавливает dependent restoration. Успешный импорт
предшествует обычным prerequisites Bootstrap и consumer SSH configuration,
следовательно — клонированию Workspace. Терминальный CLI сохраняет прежний порядок
и UX. Secure-only execution обходит общий administrator preflight: импорт
пользовательских SSH identities не требует администратора. Mixed plans сохраняют
существующие требования авторизации.

Passphrases существуют только временно в памяти процессов и PTY: новые secret argv,
environment, JSON, generated state, логи и файлы не создаются. Python и ОС не
гарантируют zeroization или исключение swap/crash dumps. Protected keys могут
снова запрашивать unlock при production revalidation; passphrases не кэшируются
между identities или операциями. Bridge зависит от terminal input age и stdin
fallback `ssh-keygen -y` (`RP_ALLOW_STDIN`, имеется в OpenSSH 8.1). Desktop не
реализован; упаковка runtime и проверки на поддерживаемых версиях macOS,
age и OpenSSH ещё необходимы.

## Покрытие casks в режиме приложения

При работающем Homebrew уже удовлетворённые выбранные casks не устанавливаются
повторно. Отсутствующие принимаются, только если Homebrew JSON описывает
app-only установку из `homebrew/cask`: artifacts `app`, необязательные неактивные
`uninstall`/`zap`, без install hooks, дополнительных зависимостей кроме
macOS/архитектуры, caveats (включая Rosetta), container override и rename.
Все app targets должны отсутствовать непосредственно в доступном для записи
`/Applications`. Disabled casks и остальные artifacts, включая `pkg`, `installer`,
`binary` и `suite`, пока не входят в этот scope. Зарегистрированный cask с
отсутствующим target требует repair и блокируется; режим приложения не выполняет
reinstall.

Проверяется только выбранная работа до публикации; production installer повторно
проверяет отсутствующий cask перед установкой. Типизированные условия
`cask_execution_requirements_unsupported`, `cask_metadata_unavailable`,
`cask_authorization_required`, `cask_target_conflict` и `cask_repair_not_supported`
сохраняют полный план. Structured failure содержит `category` и
`selected_item_index` — номер с единицы в порядке выбранных валидированных
generated records, без tokens, путей и вывода installer. Обычный cask consumer
устанавливает принятые casks в `/Applications` без sudo, ask mode, автообновления,
install cleanup и install upgrade, под существующим owned process lifecycle и
mutation boundary. Production inspection и Global Verification остаются
авторитетными. Отказ может оставить частичные изменения; независимые диалоги
macOS/vendor не подавляются. CLI сохраняет прежнее поведение. Отсутствие Homebrew
остаётся предпосылкой; Secure Restore требует отдельного канала секретов.

## Покрытие VS Code extensions в режиме приложения

Выбранные расширения используют существующие IDs, Preview, production installer
и Global Verification. В application context приоритет имеет `code` из PATH.
При его отсутствии можно вызвать официальный CLI stable VS Code по пути
`Contents/Resources/app/bin/code` внутри `/Applications/Visual Studio Code.app`
или `$HOME/Applications/Visual Studio Code.app`. Две копии без явного выбора
через PATH дают `vscode_cli_ambiguous`; другие каталоги и варианты требуют
явного `code` в PATH. Shell profiles, symlinks и постоянный PATH не меняются.

CLI требуется только выбранной работе с расширениями. До публикации отсутствие
возвращает `vscode_cli_required`, а неисправный launcher или сбой production
inventory — `vscode_cli_unavailable`. Structured Preview сохраняет эти условия
как warnings, чтобы readiness мог вернуть типизированную предпосылку.
Пояснения Desktop и Check Again пока планируются. Работающий CLI должен уже
существовать до публикации, в том числе если в плане выбран cask VS Code.

Обычный `--install-extension <ID>` устанавливает отсутствующие IDs; удовлетворённые
пропускаются, без force, update-all, uninstall и новых правил версий. Обработка
зависимостей и extension packs самим CLI сохраняет production-поведение.
Действуют существующие owned stdin/TTY/process semantics и mutation boundary;
сбой Marketplace или сети — ошибка выполнения, а не предварительный отказ
в поддержке возможности. Production inspection проверяет installed IDs, а не
версии, enablement или runtime расширений. VS Code settings и PATH-поведение
human CLI не меняются. Отдельные inventory и verifier не создаются.

## Восстановление Git-репозиториев в режиме приложения

Выбранные репозитории используют существующую конфигурацию Workspace, перенос
путей source-HOME → target-HOME, Preview, clone/branch consumer и Global
Verification. Восстановление выполняет clone сохранённого remote, а не перенос
рабочего дерева или `.git`. Существующие репозитории не получают pull/update
или новый remote. Для чистого репозитория сохраняется production checkout;
tracked/staged изменения блокируют переключение ветки.

Git требуется только выбранной работе с репозиториями. Readiness возвращает
`git_required`, `git_unavailable` или `repository_target_conflict` до публикации.
Чужие файлы, несовпадающий origin и небезопасное переключение ветки сохраняются.
Structured Preview оставляет эти условия как warnings для типизированного gate.
Некорректный или небезопасный ввод блокируется. Проверок сети и авторизации
при readiness нет.

Application clone отключает terminal/askpass prompts и credential helpers только
для этой команды; Macseed не передаёт credentials. Публичный HTTPS remote может
клонироваться; авторизованный remote завершится ошибкой, если доступ недоступен
в этом ограниченном режиме. SSH использует существующую конфигурацию и ключи ssh-agent с BatchMode, StrictHostKeyChecking=yes, UpdateHostKeys=no и
CheckHostIP=no. Неизвестные или изменённые host keys не принимаются и не
добавляются. Явные параметры SSH приложения имеют приоритет над Git SSH launcher
overrides. Глобальная конфигурация Git/SSH не меняется. HTTP(S) URLs с credentials
и URL query/fragment отклоняются; вывод clone подавляется, чтобы remote не попал
в логи. Сохраняются owned stdin, отмена процессов и mutation boundary.

Ошибки remote, сети, авторизации или trust являются execution failures после
возможного начала мутаций. Частичный каталог не удаляется автоматически;
rollback нет. Повторный запуск заново строит Preview и наблюдает состояние.
Global Verification сохраняет predicates worktree/origin/branch. Human CLI clone
не изменён; Secure Restore требует отдельного канала секретов.

## Восстановление приложений Mac App Store в режиме приложения

Выбранные приложения используют существующие numeric IDs, Preview, MAS consumer
и Global Verification. Для выбранной работы требуется работающий `mas` из PATH:
production `mas list` служит также источником проверки установленного состояния.
Другой inventory не добавляется. Без выбранных приложений предпосылки MAS нет.
Установленные IDs пропускаются; отсутствующие устанавливаются через
`mas install <ID>`, без force, purchase/get или глобального upgrade.

До публикации readiness возвращает `mas_required` при отсутствии CLI и
`mas_unavailable` при неисправном executable/version command или сбое inventory.
Structured Preview сохраняет ошибки inventory как warnings для типизированного
readiness gate. Установка `mas` через Homebrew остаётся внешней предпосылкой,
даже если эта formula выбрана в плане. Второго прохода установки пакетов и
автоматического Homebrew bootstrap нет. Desktop может объяснить предпосылку и
предложить Check Again после внешней подготовки.

Текущий mas требует root privileges и уже выполненного входа в App Store Apple
Account. Application install использует `sudo -n`, найденный CLI и
`MAS_NO_AUTO_INDEX=1`: сохраняется контекст вызывающего пользователя mas,
password fallback исключён при истечении локальной авторизации. Существующий
локальный authorization gate сохранён. Надёжная поддерживаемая проверка
account/entitlement до установки не используется; Macseed не читает частные
account databases и не управляет Apple ID login. Ошибки account, purchase,
storefront или сети являются runtime execution failures. Независимые GUI-диалоги
macOS/App Store не подавляются. Вывод mas и stderr inventory скрыты в режиме
приложения, чтобы account information не попадала в логи.

Сохраняются owned stdin/TTY/cancellation и mutation boundary. Ошибка установки
оставляет `target_mutation_may_have_started=true`, без rollback или uninstall.
Production post-install inspection и Global Verification проверяют наличие IDs
с существующими ограничениями Spotlight. Повторный Restore пропускает
удовлетворённые IDs. Human CLI MAS не изменён; Secure Restore требует отдельного канала секретов.

## Предпосылки Restore

Принятая модель Core/Desktop различает неподдерживаемое действие Restore и
поддерживаемую возможность с отсутствующей предпосылкой. Проверка зависит от
выбранного плана: если предпосылка выполнена — продолжить; если Core умеет
безопасно её удовлетворить — выполнить, проверить и продолжить; иначе вернуть
типизированное условие для пояснения Desktop и внешнего действия пользователя.
Повторный вход использует **re-inspect → recompute Preview → rerun idempotent
work**, без транзакционного resume. Это принятый контракт развития, а не
утверждение, что все эти сценарии уже реализованы.

Homebrew не должен требоваться только для запуска Macseed, осмотра Bundle,
Preview, Restore других категорий, Verify или Compare. Он нужен только выбранной
работе, которая от него зависит. Сейчас работающий Homebrew позволяет
восстановление поддерживаемых formulae; отсутствие возвращает
`homebrew_installation_requires_interaction` до публикации, а неисправная или
частичная установка — `homebrew_unavailable`. Baseline 4.0 требует, чтобы Desktop
объяснял необходимость Homebrew для выбранной работы и предлагал инструкции и
**Check Again**. Автоматическая установка необязательна до оценки авторизации
Desktop; создавать privileged helper/XPC только ради неё сейчас не требуется.

`age` — предпосылка только выбранного Secure Restore, которому он нужен.
При корректном канале секретов readiness возвращает `age_required`, если `age`
отсутствует, и `age_unavailable`, если он неработоспособен, до публикации.
Режим приложения не устанавливает его интерактивно. Подсказки Desktop и возможная
безопасная установка через formula path остаются будущей работой. Command Line Tools аналогично
относятся к операциям, которым они нужны; внешняя установка должна вести к
пояснению и повторной проверке. Текущий CLI preflight проверяет CLT широко;
зависимость проверки от плана описывает целевое поведение.

Внешняя установка предпосылки допустима, когда автоматизация потребовала бы
несоразмерной сложности привилегированной подсистемы. Это не сужает покрытие
Restore: casks, MAS apps, VS Code extensions, Git-репозитории и Secure SSH Restore
остаются ответственностью Macseed по мере подготовки их application-safe paths.

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
Keyboard, Trackpad и Screenshots. Выбранные SSH identities Secure Restore используют terminal evidence importer.
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

Secure Restore добавляет `identity_pair_matches_package` на основе evidence,
сформированного после проверки или rollback importer. Predicate подтверждает
побайтное равенство валидированной паре package, соответствие private/public и
существующие проверки безопасности файлов на момент наблюдения importer.
Аутентификация, agent, Keychain и сеть не проверяются. Bootstrap/Workflow без
Secure Restore не имеют managed identity requirement.

Opt-in importer публикует versioned non-secret terminal records в private
каталог 0700 / файл 0600. Строгий reader проверяет владельца, идентичность файла,
формат, привязку к попытке и child status, удаляет transport и передаёт records
через выделенный fd существующему collector. Records содержат target basenames,
conformity, timestamps и typed reasons; ключей, fingerprints, passphrases,
hashes и plaintext paths в них нет. Collector не читает private keys и не
расшифровывает package. Отсутствующий или невалидный evidence оставляет coverage
unresolved и report incomplete, не меняя exit code importer. Rollback отменяет
предварительный положительный evidence. Интервал наблюдения учитывает timestamps
importer; последующие изменения target не перепроверяются. Прежние ограничения
cleanup Secure Migration при сигналах и отключении питания сохраняются.

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
Человекочитаемый отчёт начинается с одного из четырёх verdicts:
`Verification incomplete`, если run неполон либо selected requirements остались
unverified/unresolved; `Differences detected` при подтверждённом mismatch в
полном run (с отдельным указанием неполного coverage, если оно есть);
`Selected requirements verified`, когда все разрешённые выбранные predicates
verified и нет unresolved references; `No managed requirements`, когда coverage
подтверждает пустой выбранный scope. Пустой inventory с неизвестной provenance
не доказывает отсутствие исходного состояния. Legacy provenance остаётся unknown
и показывается как ограничение scope, не блокируя verdict по выбранным требованиям.
Diagnostics и результаты операций выводятся отдельно от conformity.
`Selected requirements verified` относится только к выбранным поддерживаемым
требованиям Macseed, наблюдавшимся во время этого run. Это не подтверждение
идентичности всего Mac, работоспособности приложений, визуального применения
настроек macOS, удалённого SSH или неизменности target после последовательного
прохода. Публичные exit codes сохраняют семантику выполнения
команды и не доказывают соответствие окружения. Verifier не запускает Discovery
publication, установку, clone/checkout, запись preferences или restart процессов.
Временные файлы для валидации допустимы.

## Environment Comparison

Неизменяющая операция Comparison доступна явно через `bs compare` и
`./bootstrap.sh --compare`. Она сравнивает выбранное эталонное окружение с
текущим Mac, используя production inspectors и process-local
Verification/Coverage facts. Для разрешённого
predicate она выводит `matching`, `missing`, `differing` или `unverified`.
Mismatch становится `missing` либо `differing` только при typed observation от
inspector; неизвестный тип различия остаётся unverified для Comparison.
Unsupported остаётся подмножеством unverified, а unresolved selection — пробелом
Coverage. Результат операции не определяет категорию сравнения.

Собственный verdict Comparison — `Differences detected`, `Comparison incomplete`,
`No differences detected` или `No comparable requirements`. Подтверждённое
различие в полном run имеет приоритет, а неполный coverage указывается отдельно.
Сравнение extra использует полные captured inventories Homebrew casks, App Store
IDs и VS Code extension IDs с digest-bound marker для каждого domain. Элементы,
захваченные, но исключённые Blueprint, не становятся extra. Отсутствующий или
устаревший marker означает неизвестную полноту source: extra недоступен, а не
равен нулю. Formula Discovery экспортирует только requested formulae; для
scalar/payload/Workspace domains extra неприменим. SSH identities сравниваются
только по trusted evidence importer
во время Restore. Обычный отчёт показывает typed differences без expected/actual
values, приватного содержимого или remote URLs. Comparison не выполняет Apply,
удаление или планирование cleanup и не запускается автоматически в Bootstrap,
Workflow и Restore. Её facts остаются временными; постоянного интерфейса
Comparison нет.

## Планируемая граница Core/GUI

Нативное приложение macOS, предположительно на SwiftUI, будет слоем
представления и оркестрации над существующим Core. Оно использует стабильный
машиночитаемый интерфейс для Discovery, выбранного окружения, Preview,
Verification, Comparison и результатов операций,
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
