# Один сервер: Docker и GitHub Actions

Конкретный план для `univc.duckdns.org` → `84.200.80.13`: [VPS, DuckDNS,
первый запуск, ежедневный backup и восстановление](VPS.md).

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

## Подготовка VPS и Actions

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

`prototype.yml` запускает серверные/Flutter-проверки и выпускает **debug APK** обычного приложения. Публичные URL берутся из `PUBLIC_URL`; без него APK предназначен для локального Docker-стенда :7360 (на эмуляторе нужны adb reverse). Это не подписанный production-релиз Android: стабильный release-keystore и отдельная release-подпись ещё не настроены.

`deploy.yml` запускается вручную. Параметр `deploy=false` выполняет проверки, публикует образы и release artifact без подключения к VPS; это позволяет подготовить GHCR до настройки SMTP. Образы связаны с репозиторием OCI label `org.opencontainers.image.source`. Полный запуск с `deploy=true` включает выкладку: проверки, локальные crypto/QR assets без CDN, обычный web, multiarch amd64/arm64 Docker-образы. Все внешние Actions и базовые образы закреплены SHA/digest. Release manifest содержит commit, публичный origin, версию совместимости схемы и **image digests**, не плавающие tags. Артефакт release не содержит runtime/секретов. SSH доставляет его в отдельный `releases/<commit>`; старый каталог не перезаписывается. Сборка/deploy на GitHub и реальный VPS в этой среде пока не запускались. Репозиторий: `kerbermeister/voicechat`; домен и IP указаны в VPS.md, SSH и SMTP ещё требуют настройки.

## Обновление, backup и откат

`deploy.py` блокирует параллельный deploy через flock, проверяет manifest/origin, скачивает образы **до** остановки, останавливает пишущие сервисы и создаёт согласованный snapshot: `pg_dump --format=custom`, Synapse signing/config/media, control SQLite (включая зашифрованное расписание), media-config с публичными лимитами, Caddy certificates/config, runtime env и активный release с manifest. Отдельный пароль Restic в snapshot не включается. Обычный copy живого PostgreSQL-тома не используется. Snapshot шифрует закреплённый Restic, затем выполняется `restic check`; только после этого стартуют новые сервисы с ожиданием healthchecks.

Пароль Restic хранится отдельно от репозитория backup в `runtime/backup-password` (0600). Его нужно сохранить **вне VPS**; без него backup не расшифровать. Для backup без обновления предусмотрен `deploy.py --root /srv/voicechat --backup-only`; systemd timer и внешнее копирование описаны в [VPS.md](VPS.md). Сами копии по умолчанию остаются на этом VPS и не защищают от его потери: внешнее хранилище ещё не подключено. Скрипт не перезаписывает пропавший пароль поверх существующего backup-репозитория и не удаляет прежние snapshots автоматически.

При ошибке backup/update запускаются предыдущие совместимые образы из `current.json`; manifest не продвигается. Данные автоматически не откатываются к старому snapshot, чтобы не потерять новые записи. Смена Synapse/PostgreSQL/schema требует отдельного плана миграции; значение `schema: 1` допустимо только для совместимых обновлений этого набора. Успешный deploy сохраняет `previous.json`; для совместимого ручного отката запустите прежний release снова:

```sh
python3 /srv/voicechat/releases/PREVIOUS_COMMIT/infra/deploy.py \
  --root /srv/voicechat --release /srv/voicechat/releases/PREVIOUS_COMMIT
```

Восстановление проверяйте на отдельной VPS с отключённой реальной почтой/push: фиксированное имя проекта `voicechat` не позволяет изолировать restore просто другим каталогом. Через официальный Restic восстановите snapshot, проверьте signing key и конфиги, восстановите dump в пустой PostgreSQL, файлы — в новые тома, затем проверьте вход/историю/файлы/звонок. Не восстанавливайте поверх работающих пользовательских данных. Полная аварийная приёмка восстановления ещё не завершена; наличие backup не означает принятую процедуру восстановления.


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

Android onStop/lock/background, внешняя сеть, полный restore приложения и нагрузка
остаются в [матрице приёмки](../docs/screen-sharing-acceptance.md); сборка образа их не заменяет.
