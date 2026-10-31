# Развёртывание VoiceChat: core и серверы входа

Конкретный план для `univc.duckdns.org` → `84.200.80.13`: [VPS, DuckDNS,
первый запуск, ежедневный backup и восстановление](VPS.md).

## Локальная подготовка нескольких входов

Production уже переведён на один физический A с отдельными `core` и `edge-a`:
[первоначальный release51 и postcheck](../docs/iterations/three-vps-evidence/2026-10-29-production-initial-postcheck.json).
Рабочие данные находятся в core; вход обслуживает HTTPS/API/WSS/TURN и установщики.
Обычный managed workflow с областями `full/web/core/edge` реализован, проходит
сквозную VM-проверку и пока не использовался для следующего production-релиза.
Актуальная [точка продолжения](../docs/iterations/19-three-vps-resume.md) отличает
опубликованное от проверенного только локально. Инструкции и ограничения:
[core/edge и normal release](THREE_VPS.md#обычный-managed-release).

Ниже сохранены команды offline render и прежнего локального/legacy стенда.
Они не заменяют managed rollout и не должны обновлять текущий production.

`three-vps.example.json` содержит публичные логические адреса. Отдельный
`node-inventory.example.json` описывает физические IPv4, private tunnel IP,
поколения и SSH host keys. В inventory намеренно стоят непригодные для запуска
placeholder-ключи: заменить их проверенными вне SSH-сеанса ключами новых машин.
Адреса `192.0.2.0/24` — только документационный пример. Приватные ключи и пароли
не входят ни в один из этих JSON. Реальный inventory хранить вне Git/runtime web.

После заполнения копий конфигурации локальный вызов из корня:

```sh
python3 infra/render_edge.py --topology topology.json --inventory inventory.json \
  --edge c --ingress-ip 10.241.0.2 --output /tmp/voicechat-edge-c-review
```

`--ingress-ip` — точный адрес контейнера HAProxy в будущей выделенной bridge-сети,
не публичный IP VPS. В текущем offline шаге он задаётся явно; перед deployment
нужна проверка пересечения подсетей. Генератор создаёт только `Caddyfile`,
`haproxy.cfg`, `known_hosts`, `node.json` в новом каталоге 0700, файлы 0600.
Он не устанавливает службы, не выполняет SSH и не меняет DNS. TLS файлы,
runtime/Compose/tunnel, сертификаты и renewal этим вызовом не создаются.

При замене узла добавить `--previous-inventory previous-inventory.json`:
изменение host assignment требует большего `generation` и нового проверенного
SSH host key. DNS-имена и tunnel IP прежнего логического C можно сохранить;
публичная клиентская конфигурация при смене только physical IP не меняется.
Для нового D добавить записи в topology и inventory и выпустить подписанный
каталог с большей revision после подготовки входа. Публикация каталога описана
в [журнале](../docs/iterations/19-three-vps.md). Добавление/замена physical node — отдельная
операция с generation/revocation и TLS; ordinary release не принимает новую topology.

## Флаг демонстрации экрана

По умолчанию screen API выключен. Проверка совместимости: authenticated
`GET /api/screen/capabilities`. Для локального прототипа оператор атомарно записывает
`1` в `.prototype/screen-enabled`, для выключения — `0` (либо удаляет файл).
В control-контейнере это `/work/.prototype/screen-enabled` в существующем постоянном
томе `control`; переопределение пути — `VOICECHAT_SCREEN_FLAG`. Сохранять права 0600
и владельца runtime 10001. Файл не содержит секретов и не добавляется в Git.
Worker замечает отключение примерно за секунду и отзывает экранные комнаты;
основные audio/video rooms не меняются. Повторное включение не оживляет старые
экранные bindings: для них нужен новый звонок. Включение API ещё не означает
готовности клиентского UI и производственной приёмки; см. [журнал](../docs/iterations/08-screen-sharing.md).

Это отдельное развёртывание. Оно **не переносит автоматически** данные прежнего `.prototype`-стенда. Не переключайте существующий аккаунт на пустую новую базу. Идентичность Matrix (`server_name`, signing key), PostgreSQL, media и control/contacts должны переноситься согласованно; для существующего стенда миграция ещё требует отдельной приёмки.

## Проверенный локальный запуск

Из корня репозитория:

```sh
python3 infra/bootstrap.py
python3 infra/client_config.py http://localhost:7360 .prototype/deploy-client.json
cd apps/client
flutter pub get --enforce-lockfile
# После установки закреплённых Rust/wasm-инструментов, как в deploy.yml:
python3 ../../prototype/build_web_assets.py
flutter build web --release --no-web-resources-cdn --target lib/main.dart --dart-define-from-file ../../.prototype/deploy-client.json
python3 tool/version_web_assets.py build/web
cd ../..
mkdir -p .prototype/web-image
cp -R apps/client/build/web .prototype/web-image/web
cp infra/Caddyfile .prototype/web-image/Caddyfile
docker build -f infra/control.Dockerfile -t voicechat-control:local .
docker build -f infra/web.Dockerfile -t voicechat-web:local .prototype/web-image
docker compose -f infra/compose.yaml --env-file infra/runtime/stand.env up -d --wait
```

После сборки последняя команда поднимает весь стенд. Веб: http://localhost:7360, Mailpit: http://localhost:8125. Старый стенд :7357/:8008 не затрагивается. Стенд новый: зарегистрируйте тестовый аккаунт через Mailpit. Лабораторные учётные записи не вшиваются в обычную сборку.

`bootstrap.py` создаёт секреты один раз, каталог 0700 и env 0600. Повторный вызов ничего не сбрасывает. `configure` хранит неизменяемый server_name в томе и отказывается менять его поверх данных. Docker-тома сохраняют PostgreSQL, ключ подписи Matrix, медиа, согласия контактов и leases. Никогда не выполняйте `down -v` при обновлении.

Caddy обслуживает web, `/_matrix`, `/api` и `/rtc` на одном origin. Административные и внутренние API, лабораторные отчёты закрыты на внешнем адресе. Служебный Matrix-порт 8088 доступен только loopback хоста для локальных проверок/администрирования. API и SFU работают одним непривилегированным контейнером под supervisor: падение/неисправность авторизатора завершает и SFU. Это обрывает звонки при обслуживании; бесшовный рестарт не обещается.

## Legacy: подготовка VPS и Actions

Нужен Linux VPS с Docker Compose, Python 3 и свободным местом под медиа/резервные копии. На хосте один экземпляр проекта Compose `voicechat`. DNS указывает на публичный IPv4 VPS. Порты: TCP 80/443 (Caddy), TCP 7981 и UDP 50300–50400 (SFU), TCP/UDP 3488 и UDP 49300–49400 (TURN). Сетевой план требует проверки с реального телефона и сети; TURN через TLS/443 пока не настроен.

В постоянном каталоге, например `/srv/voicechat`, создайте `runtime/stand.env` с помощью **однократного** bootstrap:

```sh
SMTP_HOST=smtp.example.com SMTP_PORT=587 SMTP_USER=voicechat SMTP_PASSWORD='...' \
python3 infra/bootstrap.py --url https://chat.example.com --ip 203.0.113.10 --server-name chat.example.com
```

Адрес в примере замените реальным публичным IPv4 (документальный `203.0.113.10` намеренно не проходит проверку). Полученный `infra/runtime` разместите как `/srv/voicechat/runtime` с сохранением прав; не добавляйте в Git. Секреты SMTP вводятся в окружении на VPS, не в workflow. Подтверждённый SMTP sender можно задать через `SMTP_FROM` (по умолчанию `VoiceChat <noreply@server_name>`). Пароль SMTP в env кодируется base64 только для сохранности спецсимволов, это не дополнительное шифрование. Публичный URL и server_name выберите до регистрации пользователей.

В GitHub нужны remote этого репозитория и environment `production`:

- Variables: `PUBLIC_URL`, `DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_ROOT` (например `/srv/voicechat`).
- Secrets: `DEPLOY_SSH_KEY`, `DEPLOY_KNOWN_HOSTS` с независимо проверенным ключом SSH-хоста. Host verification не отключается.
- VPS должен иметь право pull этих образов GHCR; для private registry настройте отдельный read-only credential на VPS. GitHub token из job туда не копируется.

`prototype.yml` запускает серверные/Flutter-проверки и выпускает **debug APK** обычного приложения. Публичные URL берутся из `PUBLIC_URL`; без него APK предназначен для локального Docker-стенда :7360 (на эмуляторе нужны adb reverse). Это debug-артефакт. Для подписанного кандидата с постоянным ключом используется отдельный **Android release**, описанный ниже.

`deploy.yml` запускается вручную. Параметр `deploy=false` выполняет проверки, публикует образы и release artifact без подключения к VPS; это позволяет подготовить GHCR до настройки SMTP. Образы связаны с репозиторием OCI label `org.opencontainers.image.source`. Полный запуск с `deploy=true` включает выкладку: проверки, локальные crypto/QR assets без CDN, обычный web, multiarch amd64/arm64 Docker-образы. Все внешние Actions и базовые образы закреплены SHA/digest. Release manifest содержит commit, публичный origin, версию совместимости схемы и **image digests**, не плавающие tags. Артефакт release не содержит runtime/секретов. SSH доставляет его в отдельный `releases/<commit>`; старый каталог не перезаписывается. Сборка/deploy на GitHub и реальный VPS в этой среде пока не запускались. Репозиторий: `kerbermeister/voicechat`; домен и IP указаны в VPS.md, SSH и SMTP ещё требуют настройки.

## Обновление, backup и откат

Для отдельной проверки доступа запустите вручную workflow `Check VPS SSH`.
Он использует SSH secrets и variables environment `production`, проверяет
закреплённый ключ хоста, пользователя и доступ к Docker/Compose без изменения VPS.
Почта, сборка образов и запуск приложения для этой проверки не требуются.

`deploy.py` блокирует параллельный deploy через flock, проверяет manifest/origin, скачивает образы **до** остановки, останавливает пишущие сервисы и создаёт согласованный snapshot: `pg_dump --format=custom`, Synapse signing/config/media, control SQLite (включая зашифрованное расписание), media-config с публичными лимитами, Caddy certificates/config, runtime env и активный release с manifest. Фактические имена файловых томов берутся из Compose config с учётом project/override; `voicechat_*` больше не зашиты в backup. Отдельный пароль Restic в snapshot не включается. Обычный copy живого PostgreSQL-тома не используется. Snapshot шифрует закреплённый Restic, затем выполняется `restic check`; только после этого стартуют новые сервисы с ожиданием healthchecks.

Пароль Restic хранится отдельно от репозитория backup в `runtime/backup-password` (0600). Его нужно сохранить **вне VPS**; без него backup не расшифровать. Для backup без обновления предусмотрен `deploy.py --root /srv/voicechat --backup-only`; systemd timer и внешнее копирование описаны в [VPS.md](VPS.md). Сами копии по умолчанию остаются на этом VPS и не защищают от его потери: внешнее хранилище ещё не подключено. Скрипт не перезаписывает пропавший пароль поверх существующего backup-репозитория и не удаляет прежние snapshots автоматически.

При ошибке backup/update запускаются предыдущие совместимые образы из `current.json`; manifest не продвигается. Данные автоматически не откатываются к старому snapshot, чтобы не потерять новые записи. Смена Synapse/PostgreSQL/schema требует отдельного плана миграции; значение `schema: 1` допустимо только для совместимых обновлений этого набора. Успешный deploy сохраняет `previous.json`; для совместимого ручного отката запустите прежний release снова:

```sh
python3 /srv/voicechat/releases/PREVIOUS_COMMIT/infra/deploy.py \
  --root /srv/voicechat --release /srv/voicechat/releases/PREVIOUS_COMMIT
```

Восстановление проверяйте на отдельной VPS с отключённой реальной почтой/push: фиксированное имя проекта `voicechat` не позволяет изолировать restore просто другим каталогом. Через официальный Restic восстановите snapshot, проверьте signing key и конфиги, восстановите dump в пустой PostgreSQL, файлы — в новые тома, затем проверьте вход/историю/файлы/звонок. Не восстанавливайте поверх работающих пользовательских данных. Полный локальный Compose drill принят: [отчёт](../prototype/verified-screen-security-restore-run.json). Registry/целевой upgrade/rollback и реальные DNS/SMTP/ACME/TURN этим не проверены. Серверный backup не заменяет клиентский E2EE vault/recovery keys.


### Изменение лимитов без сборки клиента

Control API читает `client-policy.json` при каждом запросе `/config` и перед постановкой задания; клиент обновляет политику каждые 30 секунд. В прототипе это `prototype/client-policy.json`. В Docker конфиг находится в постоянном томе `voicechat_media-config`, путь `/media/client-policy.json` в configure и `/config/client-policy.json` в control (`VOICECHAT_CLIENT_POLICY`). Первичная настройка добавляет новые значения по умолчанию и сохраняет уже заданные оператором лимиты. Обновление образа не должно сбрасывать их.

Администратор меняет JSON атомарной заменой файла в томе, сохраняя владельца `10001:10001` и права `0600`; control монтирует каталог только для чтения. Неверный тип, неизвестное поле или выход за границы даёт отказ, не тихое ослабление ограничений. `schedule_max_seconds=172800` задаёт максимум 48 часов; временные сообщения используют `temporary_min_seconds=10`, `temporary_max_seconds=600`, `temporary_step_seconds=10`. Фактическое время сравнивается по часам сервера. Восстанавливая backup, переносите и каталог snapshot/media-config в соответствующий новый том до запуска configure.

## Экран: диагностика, обновление и восстановление

Schema screen metadata — v2, additive в существующей `calls/calls.sqlite`. В ней
нет медиаключей/кадров. Существующий backup всего control volume включает binding,
receipt и retired очередь; отдельного volume/сервиса для экрана не добавлено.
При старте control аннулирует screen leases до HTTP и очищает retired rooms;
восстановление SQLite не возобновляет локальный capture.

Перед обновлением/откатом отключите flag, дождитесь пустой active/retired очереди
и проверьте базовый звонок. Восстанавливайте backup только в изолированный стенд,
до запуска запишите flag `0`; затем проверьте `integrity_check`, schema и отсутствие
активных screen sessions. Восстановленный flag `1` сам по себе не является приёмкой.
Не откатывайте общую БД поверх пользовательских данных ради отключения screen share.

Безопасные агрегаты (запуск внутри существующего control, никаких токенов в команде):

```sh
docker compose --env-file infra/runtime/stand.env -f infra/compose.yaml exec -T control python3 prototype/screen_status.py
```

Проверяйте `pending_commands`, `oldest_pending_seconds`, `retired_rooms` и состояния
sessions. CLI открывает SQLite read-only; identities, leases, SDP, source/window names,
JWT и ключи не печатает. Не включайте подробные SDK/raw HTTP логи для диагностики.

| Симптом | Проверка и действие |
| --- | --- |
| Нет кнопки или capability=false | Серверный flag off, несовместимый/старый клиент; после включения начните новый звонок. |
| Picker отменён/доступ запрещён | Повторите пользовательское действие и проверьте разрешение ОС; текущий ведущий сохраняется. |
| Замок вместо картинки | Проверьте доверие выбранным устройствам, HTTPS/worker/E2EE; plaintext fallback отсутствует. |
| Старый ведущий/завис переход | Проверьте revision и агрегаты pending/retired; не обходите DeleteRoom вручную выдачей JWT. При SFU-ошибке выключите flag и восстановите связь control↔SFU. |
| Пустой показ | Без SFU-публикации 15 с room отзывается, heartbeat не продлевает её бесконечно. |
| Слабая сеть | Выберите «Экран: Низкое»; проверьте реальные ICE/TURN порты, обычный HTTPS не заменяет TURN/TLS. |
| Нужно аварийно выключить | Атомарно flag=0, дождитесь cleanup и закройте screen UI; голос сохраняется при исправной инфраструктуре. Не удаляйте volumes. |

Android onStop/lock/background, внешняя сеть, target upgrade/rollback и нагрузка
остаются в [матрице приёмки](../docs/screen-sharing-acceptance.md); сборка образа их не заменяет.

## Быстрые повторные релизы

Workflow **Build and deploy** имеет два режима: `full` (по умолчанию) и `web`.
Первое обновление после внедрения этой возможности выполняется с `full`: оно
записывает fingerprint серверных исходников и конфигурации в `current.json`.
При `web` runner читает только метаданные текущего релиза по закреплённому SSH-ключу,
проверяет fingerprint и переиспользует точный digest control. VPS повторяет проверку
под общей deploy-блокировкой, включая origin/schema/control и конфигурацию backend.
Изменение Compose, политик, backend, схем БД или неизвестного runtime-файла требует
`full`; одного выбора `web` для обхода этого ограничения недостаточно.

`web` выполняет `compose pull web` и `compose up --no-deps --wait web`. До и после переключения проверяются наличие и здоровье backend. Backend и
БД не перезапускаются и не меняются, поэтому новое резервирование БД в этом режиме
не требуется; регулярный backup и полный backup перед `full` сохраняются.
Ошибка healthcheck возвращает прежний web; `current.json`/`previous.json` обновляются
только после успешной проверки. Релизы и их файлы не удаляются: работающие backend
контейнеры могут всё ещё использовать bind mounts предыдущего полного релиза.
Последующее полное обновление выполняет обычный backup и переключение всех служб.
Это не бесшовное обновление прокси: замена web/Caddy может кратко переподключить
проходящие через него WebSocket, хотя сами backend-контейнеры не перезапускаются.

Кеши GitHub Actions разделены: `.prototype/crypto-tools` содержит только закреплённые
бинарные инструменты, а кеш ассетов — только генерируемые worker/JS/WASM.
Runner закреплён на Ubuntu 24.04; его версия также входит в конфигурацию ключа.
Ключи включают ОС/архитектуру, `infra/crypto-tools.json`, скрипты генерации,
lock-файл клиента и исходники Matrix SDK. Изменения `lib/` не требуют пересборки
криптоассетов. При промахе кеша инструменты/ассеты строятся заново; все существующие
тесты и анализ выполняются в обоих режимах. Пользовательские данные, `.env`, SSH/GHCR
credentials, `.prototype/accounts.json` и runtime в эти кеши не входят.
Первый запуск заполнения кеша остаётся медленным. Холодный/тёплый запуск сравнивайте
по этапам Actions, не по одной скорости VPS. Статические файлы веба имеют
`Cache-Control: no-cache`: браузер проверяет актуальность, не удаляя локальную БД.

Проверки: `python3 -m unittest discover -s prototype -p 'test_deploy*.py'`.
Реальный изолированный Compose/health/rollback без публичных портов:
`VOICECHAT_DOCKER_DEPLOY_TEST=1 python3 -m unittest discover -s prototype -p 'test_web_deploy_docker.py'`.
Проверка использует отдельный временный проект Docker и не обращается к production.

### Локальный полный restore drill

`prototype/screen_restore_fixture.py` использует только новые проекты
`voicechat-screen-source-*` и `voicechat-screen-target-*`, новые тома и mail sink.
Source останавливается до запуска target с той же тестовой Matrix identity.
Release/runtime и SQL/файлы берутся из зашифрованного snapshot; перед startup
восстановленный screen flag=0. Оба проекта/тома удаляются в finally; существующие
`voicechat` и `voicechat-prototype` не останавливаются. Нужны свободные порты
локального Compose (7364/7365, 8088, 7981, 3488 и его UDP ranges) и lab web 7363.

Подготовьте обычные pinned web assets по client README, локальные образы
`voicechat-screen-control:test` и `voicechat-web:local`. В `apps/client` соберите
**только тестовый** target (его bridge нельзя публиковать):

```sh
flutter build web --release --target lib/lab_screen_security_main.dart --output=/tmp/voicechat-screen-restore-web
```

Из корня отдельно запустите web server, затем проверку с существующим NODE_PATH
для Playwright/pngjs:

```sh
python3 prototype/serve_web.py --port 7363 --directory /tmp/voicechat-screen-restore-web
```

```sh
NODE_PATH=/path/to/existing/node_modules node prototype/check_screen_security.cjs restore
```

Проверка читает encrypted history с сервера и действительно скачивает/decrypt файл,
сохраняя исходный client vault. После включения screen начинает **новый** звонок:
terminal call_session после restore повторно не допускается. Для JWT-проверки через
долгий restore используется test-only grant с expiry 600 с; production TTL=60 с не
меняется. Результат без ключей/credentials — `verified-screen-security-restore-run.json`.


### Локальная проверка обновления существующих томов

С тем же lab web на 7363 и NODE_PATH запустите
`node prototype/check_screen_security.cjs operations`. Дополнительно нужен baseline
`voicechat-screen-baseline:c3e3f43`, собранный через `infra/control.Dockerfile`
**из чистого git archive c3e3f43**. Fixture разрешает baseline/candidate/web tags
в фактические локальные image IDs; registry digest и production manifest не имитирует.

На baseline создаются реальные encrypted данные и voice/camera call, в его
существующей calls.sqlite — screen v1 fixture с terminal binding. Upgrade выполняется
на тех же named volumes, с остановкой writers и настоящим backup/check до смены образа.
Проверяются v2, signing key, SQL counts, terminal tombstone, старые text/file, off/on
и новые данные. Перед совместимым откатом screen выключается, active/pending/retired
должны стать 0, старая SFU room должна исчезнуть. Fixture отказывает раннему rollback;
**это проверка ручного runbook, не новый автоматический guard в deploy.py**.
После backup запускается baseline, общая БД не восстанавливается и схема не понижается.
Те же клиентские vaults читают данные до/после upgrade; voice/camera работают.

[Отчёт](../prototype/verified-screen-security-operations-run.json) относится к
изолированным локальным Compose-проектам. Проверки registry/deploy coordinator,
целевой конфигурации, точной старой версии клиента и публичной сети остаются отдельными.

## Ручные Android-обновления

Клиент проверяет `/updates/android/latest.json` только по кнопке в «О приложении».
Загрузка требует подтверждения, установка — отдельного подтверждения Android.
[Контракт и ограничения](../docs/android-apk-update-spec.md),
[версии](../docs/app-versioning.md), [история изменений](../docs/app-changelog.md).

Первое подключение раздачи требует **full**-релиза: меняются Compose и workflow.
Legacy `deploy.py` использует `runtime/android-updates`. После managed cutover
`DEPLOY_ROOT=/srv/voicechat-managed` указывает на координатор; действующие каналы
находятся в `edges/<id>/runtime/android-updates` **на хостах соответствующих edge**.
Издатель получает список из проверенной production baseline, сверяет публичный
подписанный каталог и проверяет actual read-only Docker mount каждого edge.
В coordinator `/runtime` или в старый legacy-каталог routed APK не публикуются.
Канал уже монтируется текущей edge-ролью: отдельный deploy/перезапуск для публикации
не нужен. Изменение самого Compose/mount по-прежнему требует штатного релиза.

Проверка без APK, release-ключа и физического телефона:

```sh
python3 infra/client_config.py --environment "$PUBLIC_URL" /tmp/client.json
python3 infra/publish_android_ssh.py --check --config /tmp/client.json
```

Нужны существующие `DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_ROOT`, `PUBLIC_URL`,
`CLIENT_ROUTE_CONFIG`, `CLIENT_ROUTE_CATALOG_KEY` и pinned SSH. В Actions выбрать
**Android release**, `check_channel=true`, `publish=false`: отдельный Python-job
проверяет канал, Android не собирается и теги/manifest не меняются.

GitHub environment `production`:

- Secrets: `ANDROID_KEYSTORE_BASE64` (base64 JKS), `ANDROID_STORE_PASSWORD`,
  `ANDROID_KEY_PASSWORD`, `ANDROID_KEY_ALIAS`; существующие SSH credentials.
- Variables: `ANDROID_SIGNING_SHA256` (SHA-256 сертификата, lowercase hex),
  `PUBLIC_URL`, `DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_ROOT`.
- `ANDROID_ACCEPTED_BUILD` и `ANDROID_ACCEPTED_SHA256` — номер и точный hash APK,
  для которого записана приёмка физического Android. Без них публикация заблокирована.

31.10.2026 существующий release-keystore/пароли и публичный signing fingerprint
настроены в production с разрешения владельца. CI-кандидат32 прошёл build/package;
[результат и точные байты](../docs/iterations/android-update-channel-2026-10-31.md).
Acceptance-переменные оставлены пустыми до физической приёмки.

Ключ подписи и пароль резервировать **вне этого компьютера и VPS**, в защищённом
хранилище. Не хранить их в Git, артефактах или кеше CI. При утрате ключа обычное
обновление ранее установленных APK новым ключом невозможно. Локально созданный
ключ ещё не означает настройки секретов GitHub или наличия внешней копии.

**Android release → Run workflow**, выбрать revision, `publish=false` для сборки
кандидата. Workflow проверяет клиент/сервер, собирает обычный `lib/main.dart`,
проверяет подпись, package/version/ABI и создаёт артефакт `android-<commit>`:
APK, `latest.json`, `release.json`, отчёт `apksigner`. После приёмки настроить
`ANDROID_ACCEPTED_BUILD`/`ANDROID_ACCEPTED_SHA256`, выбрать тот же revision и
запустить workflow с `publish=true`, `source_run=<ID запуска кандидата>`.
Он получает **тот же APK** через [gh run download](https://cli.github.com/manual/gh_run_download),
повторно проверяет подпись и metadata, публикует его и тег `app-v<version>+<build>`.
Для публикации повторная компиляция запрещена: приёмка относится к точным байтам.
Для уже проверенного локального clean-кандидата допустим прямой запуск
`python3 infra/publish_android_ssh.py /path/to/candidate` с теми же production
SSH-параметрами и точными `ANDROID_ACCEPTED_BUILD` / `ANDROID_ACCEPTED_SHA256`.
Публикуются прежние байты: каталог включает `client-config.json`, `release.json`,
`latest.json`, `voicechat.apk`; acceptance gate действует до SSH и повторно на edge.

Все действующие edge проверяются до первой публикации. У каждого собственный
`.publish.lock`, immutable APK, `previous.json` и атомарный `latest.json`.
Глобальной атомарности между разными VPS нет: при сетевой ошибке после частичного
успеха повторить тот же кандидат, уже опубликованные байты переписаны не будут.
После добавления нового edge повторно доставить действующий принятый кандидат
на все входы до объявления его канала готовым; admission пока не копирует APK.

Номер опубликованного APK неизменяем; другой файл требует следующего BUILD и
соответствующей записи истории. `source_run` должен принадлежать тому же commit.


Для локальной сборки экспортировать четыре переменные подписи из защищённого
хранилища, задать production `PUBLIC_URL`, сгенерировать конфигурацию через
`infra/client_config.py` и выполнить из `apps/client`:

```sh
flutter pub get --enforce-lockfile
flutter build apk --release --target lib/main.dart --dart-define-from-file /tmp/client.json
```

На macOS: `LC_ALL=en_US.UTF-8 LC_CTYPE=en_US.UTF-8 LANG=en_US.UTF-8` и существующий
Rust toolchain в PATH. Без ключа release-сборка завершается ошибкой, debug fallback
отсутствует. Проверка версии: `python3 infra/android_release.py check-version`.
Упаковка из корня (выходной каталог должен отсутствовать):

```sh
python3 infra/android_release.py package \
  --apk apps/client/build/app/outputs/flutter-apk/app-release.apk \
  --tools "$ANDROID_HOME/build-tools/36.0.0" \
  --certificate "$ANDROID_SIGNING_SHA256" --output /tmp/android-candidate
```

`release.json` фиксирует фактический commit, ожидаемый тег и `sourceDirty`.
Локальные сборки с незакоммиченными изменениями — кандидаты, workflow их не
публикует. Production всегда использует чистый выбранный revision.

Публикация сериализуется серверным `.publish.lock`: APK сначала размещается по
неизменяемому номеру, проверяется через публичный HTTPS, затем атомарно меняется
`latest.json`; прежний manifest сохраняется в `previous.json`. Ошибка до переключения
оставляет старый канал. Для отзыва на VPS:

```sh
python3 /srv/voicechat-managed/bundles/SOURCE_SHA/infra/android_release.py withdraw \
  --root /srv/voicechat-managed/edges/EDGE/runtime/android-updates --origin https://EDGE-PUBLIC-HOST
```

Отзывать на каждом действующем edge, используя его публичный origin; координаторный
и legacy runtime не менять. APK и manifest сначала проверить через этот же вход.
При первом выпуске без предыдущего manifest канал отключается (404), иначе
выбирается предыдущий. Отзыв не понижает версию на телефоне. Исправляющий APK
получает больший versionCode; хранившиеся APK и номера не удаляются и не используются
повторно. Не удалять release-каталоги, которые используются контейнерами.

Проверки: `python3 -m unittest prototype/test_android_release.py`;
`VOICECHAT_DOCKER_TESTS=1 python3 -m unittest prototype/test_android_caddy.py`
проверяет настоящий Caddy в изолированном контейнере. Fixture
`apps/client/integration_test/apk_update_fixture.dart` предназначен только для
эмулятора и требует `UPDATE_FIXTURE=true`: его HTTP transport заменён на loopback,
он не входит в обычный APK и не служит проверкой production TLS/физического телефона.

## Web Push для iPhone и браузеров

Кандидат реализации: [задачи MC-07/08 и проверки](../docs/iterations/14-mobile-calls-and-messaging.md).
Это изменение control и web: первый выпуск требует `mode=full`, а не web-only.
Production-доставка и физический iPhone ещё не приняты.

- На iPhone требуется iOS 16.4+, установка на домашний экран и разрешение по
  кнопке «Настройки → Включить уведомления». При отказе разрешение меняют в iOS.
- Web Push использует Matrix HTTP pusher с `format=event_id_only` и gateway
  `/_matrix/push/v1/notify`. Клиент регистрирует/отзывает свою подписку
  через `/api/push/subscribe` с действующим Matrix access token; user/device
  определяются сервером через whoami. `GET /api/push/config` отдаёт публичный VAPID key.
- Постоянный P-256 VAPID key автоматически создаётся один раз в control volume:
  `/work/.prototype/push/vapid.pem` (0600); там же `subscriptions.sqlite` (0600).
  Существующий согласованный full-backup включает весь control volume при
  остановленных writers. Не удалять ключ при обычном выпуске: его замена потребует
  переподписки устройств. Endpoint/auth подписок и приватный VAPID key не логировать.
- Control-образ устанавливает закреплённые зависимости из `infra/push-requirements.txt`.
  Они реализуют стандартные VAPID и RFC 8291; своя криптография не написана.
- Исходящий HTTPS разрешён только к push-провайдерам Apple, Google и Mozilla;
  redirects запрещены. Дубликаты event_id подавляются, ошибки доставки повторяет
  Synapse, 404/410 отзывают подписку. Push не содержит текста, отправителя, room_id,
  event_id или пользовательских E2EE-ключей. Уведомление нейтральное:
  «Новое сообщение или входящий звонок». Его binding проверяется worker для
  защиты от отложенного уведомления прежнего аккаунта.
- В фоне iOS воспроизводит системный звук уведомления по настройкам iPhone/Focus.
  Длинный пользовательский ringtone/экран CallKit web-приложению не предоставлен.
  Ringtone в открытом приложении воспроизводится через разблокированный Web Audio;
  в окне разговора есть кнопка «Включить звук» для восстановления web-аудио.
- Проверить после full-релиза: включение/отказ/выключение, сообщение и вызов при
  открытом/закрытом webapp и заблокированном iPhone, выход/смену аккаунта, отсутствие
  дублей, сохранность VAPID key после рестарта. Service worker не кеширует переписку;
  Flutter startup уже не запускает deprecated cache worker. Сохранить no-cache.

Для локального prototype, где Synapse находится в Docker, а control запущен на
host, задайте `VOICECHAT_PUSH_GATEWAY_URL=http://host.docker.internal:8090/_matrix/push/v1/notify`.
В локальном Synapse разрешите в `ip_range_whitelist` только конкретный IP этого
host callback; не переносите это исключение в production. Путь gateway должен быть
именно `/_matrix/push/v1/notify`: Synapse отвергает префикс `/api` в pusher URL.
Сквозная проверка на отдельных локальных тестовых аккаунтах:
`VOICECHAT_PUSH_SYNAPSE_TEST=1 .prototype/python/bin/python -m unittest discover -s prototype -p test_web_push_synapse.py`.
Она проверяет реальный pusher/callback/revoke, но подменяет внешний push provider.
