# VoiceChat на VPS 84.200.80.13

План для нового сервера: `https://univc.duckdns.org`, Matrix server_name
`univc.duckdns.org`, каталог `/srv/voicechat`, проект Compose `voicechat`.
В сообщении было `univc..duckdns.org`; здесь исправлена двойная точка.
До создания пользователей проверьте, что имя `univc` принадлежит вам.
SSH-доступ проверен 23 октября 2026. На VPS уже работает Avito Helper, поэтому
80/443 остаются за его Caddy. Для VoiceChat используется `compose.proxy.yaml`
в shared `runtime/compose.override.yaml`: web доступен только через сеть
`deploy_default`, alias `voicechat-web`, доверенный proxy subnet `172.18.0.0/16`.
`deploy.py` применяет этот override также при backup и откате. Новый маршрут
`univc.duckdns.org { reverse_proxy voicechat-web:80 }` добавляется во внешний
Caddy после подготовки приложения. Внешний Caddy обслуживает HTTPS и хранит
сертификаты в `deploy_caddy_data`: этот том надо резервировать отдельно от VoiceChat.
При восстановлении override находится в `snapshot/database/compose.override.yaml`;
до запуска верните его в общий runtime и восстановите внешнюю proxy-сеть/маршрут.
Для ручных Compose-команд ниже на этой VPS добавляйте
`-f infra/runtime/compose.override.yaml` после `-f infra/compose.yaml`.
В GitHub создан environment `production` и четыре variables; SSH secrets ещё
требуют настройки. Развёртывание использует уже предоставленного `root`;
при установке backup service здесь замените `User=voicechat` на `User=root`.
Существующие данные лаборатории этим процессом не переносятся.
Повторная проверка DNS resolver 1.1.1.1 от 23 октября 2026: A возвращает
`84.200.80.13`, AAAA отсутствует.

## 1. DuckDNS и HTTPS

1. Войдите в [DuckDNS](https://www.duckdns.org/) через свой аккаунт.
2. Добавьте поддомен `univc` (без `.duckdns.org`). Если он уже есть в вашем
   аккаунте, используйте существующую запись. Чужое занятое имя использовать нельзя.
3. В поле IPv4/current IP укажите `84.200.80.13` и нажмите обновление IP.
   Автоопределение из браузера может подставить адрес домашней сети.
4. Не задавайте IPv6/AAAA, пока IPv6 VPS и firewall не настроены. Удалите устаревшую
   AAAA, если она есть: она может мешать HTTPS и клиентам.
5. Проверьте с внешнего компьютера:

```sh
dig +short A univc.duckdns.org @1.1.1.1
dig +short AAAA univc.duckdns.org @1.1.1.1
```

A должна вернуть `84.200.80.13`, AAAA — ничего для этого IPv4-развёртывания.
При постоянном IP периодическое обновление DuckDNS не требуется. Токен DuckDNS
не передавайте в чат, Git или Compose: Caddy использует HTTP/TLS challenge.
Если IP VPS изменится, обновите и DNS, и `PUBLIC_IP` в приватном env, затем
пересоздайте configure/control/turn в окно обслуживания. Matrix server_name сохраните.
Формат обновлений описан в [официальной спецификации DuckDNS](https://www.duckdns.org/spec.jsp).

После запуска Caddy сам получает и продлевает сертификат, перенаправляет HTTP
на HTTPS. Для этого нужны DNS и входящие TCP 80/443; данные ACME сохраняются в
`voicechat_certificates`. Подробности: [Caddy HTTPS](https://caddyserver.com/docs/quick-starts/https).
Отдельные nginx, certbot и сертификат DuckDNS не нужны.

## 2. VPS, порты и хранилище

На Linux VPS установите Docker Engine с Compose v2, Python >=3.9 и curl по
[официальной инструкции Docker](https://docs.docker.com/engine/install/).
У пользователя развёртывания `voicechat` должен работать `docker info` без sudo.
Доступ к Docker равносилен административному доступу; SSH разрешите только по ключу.
Проверьте время/NTP, свободный диск и резерв места под полный SQL dump плюс backup.
Минимальная проверка deploy в 2 GiB не оценивает размер ваших данных.

В firewall провайдера разрешите следующий входящий трафик:

| Порт | Назначение | Источник |
| --- | --- | --- |
| TCP 22 (или ваш SSH-порт) | SSH/deploy | Адреса администратора и runner, выполняющего deploy |
| TCP 80, 443 | Caddy, HTTPS и WebSocket сигнализация | Интернет |
| TCP 7981 | SFU ICE TCP | Интернет |
| UDP 50300–50400 | SFU media | Интернет |
| TCP и UDP 3488 | TURN | Интернет |
| UDP 49300–49400 | TURN relay | Интернет |

Не публикуйте 5432, 7880, 8008, 8090 и 8125. Compose оставляет администраторский
Matrix endpoint только на `127.0.0.1:8088`. Убедитесь, что 80/443 свободны.
Исходящие DNS, HTTPS (ACME/GHCR), SMTP и медиатрафик должны быть доступны.
UFW сам по себе не гарантирует фильтрацию опубликованных Docker-портов:
используйте firewall провайдера и правила Docker для выбранного backend.
См. [Docker и firewall](https://docs.docker.com/engine/network/packet-filtering-firewalls/).
Не отключайте управление iptables Docker ради UFW.

TURN/TLS на 443 в этом Compose отсутствует: TCP 443 занят Caddy. В сетях,
пропускающих только HTTPS, звонки могут не работать. Обычный HTTPS не является TURN.

Тома `voicechat_postgres`, `voicechat_synapse`, `voicechat_control` хранят БД,
Matrix identity/media и SQLite соответственно. `voicechat_media-config` хранит
политику и SFU config, `voicechat_turn-config` — TURN config, `voicechat_certificates`
и `voicechat_caddy-config` — Caddy. Не меняйте имя проекта и не используйте `down -v`.

## 3. Секреты и первый release

Нужен SMTP с STARTTLS, обычно порт 587. DuckDNS не предоставляет почтовый ящик:
разрешённый SMTP sender надо согласовать с провайдером почты. По умолчанию код
использует `noreply@univc.duckdns.org`; если SMTP не разрешает этот адрес,
задайте `SMTP_FROM` при bootstrap (пример ниже). До запуска проверьте доставку
писем подтверждения, иначе регистрация пользователей не завершится.

Администратор предварительно создаёт `/srv/voicechat` с владельцем пользователя
развёртывания (например, `sudo install -d -m 700 -o voicechat -g voicechat /srv/voicechat`).
В проверенном checkout **на VPS**, в Bash от пользователя развёртывания:

```sh
umask 077
mkdir -p /srv/voicechat/runtime /srv/voicechat/releases
chmod 700 /srv/voicechat/runtime
# Заполните собственными значениями, пароль вводите скрыто, без shell history.
export SMTP_HOST='smtp.YOUR-PROVIDER.example' SMTP_PORT=587
export SMTP_USER='YOUR-SMTP-LOGIN'
export SMTP_FROM='VoiceChat <YOUR-VERIFIED-SENDER@example.com>'
read -r -s -p 'SMTP password: ' SMTP_PASSWORD; echo
export SMTP_PASSWORD
python3 infra/bootstrap.py --url https://univc.duckdns.org \
  --ip 84.200.80.13 --server-name univc.duckdns.org
unset SMTP_PASSWORD
# Только для нового VPS: не заменяйте существующий файл с секретами.
test ! -e /srv/voicechat/runtime/stand.env && \
  cp -p infra/runtime/stand.env /srv/voicechat/runtime/stand.env
```

Bootstrap создаёт пароли один раз. Повторный запуск сохраняет существующую
конфигурацию: если в checkout уже был локальный runtime, не переносите его вслепую.
В приватном env должны быть `LOCAL_STAND=0`, `BIND=0.0.0.0`, `HTTP_PORT=80`,
`HTTPS_PORT=443`, `SITE=univc.duckdns.org`, пустой `COMPOSE_PROFILES`.
Файл имеет права 0600, runtime — 0700. Не публикуйте вывод `docker compose config`:
он содержит секреты. `config -q` проверяет конфигурацию без их печати.

В GitHub → Settings → Environments → `production` задайте:

| Variable | Значение |
| --- | --- |
| PUBLIC_URL | `https://univc.duckdns.org` |
| DEPLOY_HOST | `84.200.80.13` |
| DEPLOY_USER | `root` (текущий предоставленный SSH-доступ) |
| DEPLOY_ROOT | `/srv/voicechat` |

Secrets: `DEPLOY_SSH_KEY` — отдельный SSH-ключ deploy; `DEPLOY_KNOWN_HOSTS` —
ключ VPS, сверенный через консоль провайдера. На VPS выполните `docker login ghcr.io`
с отдельным credential, имеющим только право чтения private packages этого проекта.
SMTP/Matrix/Restic secrets остаются на VPS, в GitHub их переносить не нужно.

После коммита и push согласованного release запустите workflow **Build and deploy**.
Он доставляет образы по digest, immutable release и запускает `deploy.py`.
Повторная доставка в уже существующий каталог commit завершается отказом;
это защищает файлы работающего release от перезаписи. Для повторного запуска
уже доставленного полного release запускайте его deploy.py вручную.
Незавершённую доставку сначала исследуйте; не удаляйте текущий/предыдущий release.

Из каталога активного release команды Compose требуют image digests из manifest:

```sh
cd /srv/voicechat/releases/RELEASE_COMMIT
export CONTROL_IMAGE="$(python3 -c 'import json; print(json.load(open("release.json"))["control"])')"
export WEB_IMAGE="$(python3 -c 'import json; print(json.load(open("release.json"))["web"])')"
docker compose --env-file infra/runtime/stand.env -f infra/compose.yaml config -q
docker compose --env-file infra/runtime/stand.env -f infra/compose.yaml ps
curl --fail https://univc.duckdns.org/_matrix/client/versions
```

Проверьте HTTP→HTTPS, валидный сертификат, 404 для `/api/internal/test` и
`/_synapse/admin/v1/server_version`, регистрацию с реальным письмом, вход,
сообщения и файл после перезапуска. Затем звонок между двумя физическими
устройствами в разных сетях, включая мобильную сеть и принудительный relay.
Проверка `health` не доказывает ICE/TURN, расшифровку медиапотока или работу Android.

### Яндекс Почта на этой VPS

Создайте пароль приложения типа «Почта» в [Яндекс ID](https://id.yandex.ru/security/app-passwords)
и включите пароли приложений в настройках почтовых программ.
В своём терминале выполните:

```sh
ssh -t root@84.200.80.13 'python3 /srv/voicechat/bootstrap/infra/setup_yandex.py --url https://univc.duckdns.org --ip 84.200.80.13 --server-name univc.duckdns.org'
```

Скрипт запросит адрес и скрытый пароль, проверит SMTP STARTTLS/login без отправки
письма и создаст постоянный env через bootstrap. Он отказывается заменять
существующие секреты. Используется `smtp.yandex.ru:587`, отправитель — введённый
ящик. См. [настройки Яндекса](https://yandex.ru/support/yandex-360/customers/mail/ru/mail-clients/others.html).

## 4. Screen API и SQLite

Для нового control volume файл `screen-enabled` отсутствует: экран выключен.
При переносе существующего тома выключите его атомарно от runtime UID 10001:

```sh
docker compose --env-file infra/runtime/stand.env -f infra/compose.yaml exec -T control python3 - <<'PY'
import os
from pathlib import Path
os.umask(0o077)
p = Path('/work/.prototype/screen-enabled')
t = p.with_name('screen-disabled.pending')
t.write_text('0\n')
t.chmod(0o600)
t.replace(p)
PY
docker compose --env-file infra/runtime/stand.env -f infra/compose.yaml exec -T control python3 prototype/screen_status.py
```

Authenticated `GET /api/screen/capabilities` должен вернуть `protocol_version: 1`
и `screen: false`. Перед обслуживанием дождитесь отсутствия pending commands,
retired rooms и активных sessions. Не включайте флаг в bootstrap/Compose.

Контракты взяты из `prototype/screen_http.py`, `screen_protocol.py`,
`screen_control.py`: API protocol v1, SQLite `screen_schema.version=2`, общая БД
`/work/.prototype/calls/calls.sqlite`. SQL и API этой подготовкой не меняются.
`schema: 1` в release manifest — отдельный маркер совместимости развёртывания,
а не версия screen-таблиц. Он не доказывает, что произвольный старый образ умеет
читать screen v2. Откат к коду, не поддерживающему текущую SQLite, запрещён без
отдельного плана; согласуйте его с изменениями приложения. Не редактируйте версии
в БД вручную и не восстанавливайте только calls.sqlite из другого snapshot.

## 5. Backup, расписание и внешняя копия

После первого запуска и затем ежедневно можно выполнить без обновления образов:

```sh
python3 /srv/voicechat/releases/RELEASE_COMMIT/infra/deploy.py \
  --root /srv/voicechat --backup-only
```

Скрипт выбирает текущий release под deploy lock, останавливает пишущие сервисы,
делает pg_dump и snapshot всех control SQLite вместе с WAL/SHM, Synapse identity
и media, client policy, Caddy, runtime env и исходниками активного release.
TURN config пересоздаётся из env. Это прерывает звонки и сайт на время backup.
При ошибке он пытается вернуть текущие сервисы и завершает работу с ошибкой.
Manifest текущего/предыдущего release не меняется. Backup перед обновлением
использует конфигурацию предыдущего release; пароль не включается в snapshot.

Сохраните `/srv/voicechat/runtime/backup-password` отдельно **вне VPS** после
первого backup. Restic repo находится в `/srv/voicechat/backups/repository`.
Потеря единственного пароля делает восстановление невозможным.

Для systemd установите поставляемые `voicechat-backup.service` и `.timer` в
`/etc/systemd/system/`, проверив `User=voicechat` и `/srv/voicechat`.
`systemctl enable --now voicechat-backup.timer` включает backup в **03:30 UTC**.
`Persistent=true` запускает пропущенную копию после включения VPS, тоже с простоем.
Выберите подходящее окно. Проверяйте `systemctl status voicechat-backup.service`,
`journalctl -u voicechat-backup.service` и свободный диск; автоматического удаления
старых snapshots нет. Ошибка конкурирующего deploy/backup требует повторного запуска.

Без внешней копии потеря VPS означает потерю данных. Например, с отдельного
доверенного backup-хоста забирайте зашифрованный репозиторий по SSH под общей
блокировкой (пользователь должен иметь чтение backups и доступ к deploy.lock):

```sh
rsync -a --rsync-path='flock -s /srv/voicechat/deploy.lock rsync' \
  BACKUP_SSH_USER@84.200.80.13:/srv/voicechat/backups/repository/ /SAFE-BACKUP/voicechat/
```

Назначение `/SAFE-BACKUP/voicechat` замените на реальное внешнее хранилище;
`BACKUP_SSH_USER` — на учётную запись с чтением root-owned файлов Restic (контейнер
создаёт их от root). При необходимости используйте ограниченную sudo-команду
для rsync; не делайте backup общедоступным через chmod.
автоматизируйте эту команду на backup-хосте после локальной копии. Не используйте
`--delete` и не копируйте незашифрованный runtime вместе с репозиторием.
Проверяйте внешнюю копию через `restic check --read-data` с отдельно сохранённым
паролем. Локальный `restic check` проверяет структуру, но не читает все data packs.

## 6. Откат и аварийное восстановление

Перед обновлением оставьте screen выключенным, проверьте совместимость SQL/API,
сохранность предыдущего release и возможность pull его digest. После неудачного
обновления deploy пытается запустить прежние образы; обратной миграции данных нет.
Для совместимого ручного отката возьмите путь из `/srv/voicechat/previous.json`:

```sh
python3 /srv/voicechat/releases/PREVIOUS_COMMIT/infra/deploy.py \
  --root /srv/voicechat --release /srv/voicechat/releases/PREVIOUS_COMMIT
```

Восстановление сначала отрепетируйте на **отдельной VPS** с закрытым входом,
отключённой реальной почтой и push. Встроенное имя Compose и volume mounts backup
фиксированы: просто другой рабочий каталог на том же хосте не изолирует данные.

1. Закреплённым Restic из `infra/deploy.py` выполните `snapshots`, затем
   `restore SNAPSHOT_ID --target /restore` с внешним repo и сохранённым паролем.
   Не используйте `latest` без проверки времени нужного snapshot.
2. Из `/restore/snapshot` возьмите `release`, `current.json`, `runtime/stand.env`,
   `database/postgres.dump`, `synapse`, `control`, `media-config`, `certificates`,
   `caddy-config`. Верните release в `/srv/voicechat/releases/<commit>`, а env
   в runtime с 0600/0700. Пересоздайте `infra/runtime` symlink на общий runtime.
   Пароль Restic верните из отдельного хранения. При другом root исправьте только
   путь release в current.json, сохранив manifest/digests и Matrix identity.
3. На чистой машине создайте пустые именованные тома через `docker compose create`.
   Восстановите файловые каталоги в соответствующие тома с сохранением numeric
   UID/GID и прав: Synapse 991, control/media-config 10001. Не запускайте пока
   synapse/control/web/turn. Сохраните Matrix signing key и server_name без изменений.
4. До запуска control атомарно запишите `0` в корень его тома как `screen-enabled`
   (10001:10001, 0600). Проверьте `PRAGMA integrity_check` каждой восстановленной
   SQLite, включая calls и scheduled, и screen schema v2. Сохраните WAL/SHM вместе
   с БД до открытия; не создавайте новую SQLite вместо отсутствующей.
5. Запустите только postgres с **тем же закреплённым образом**, дождитесь готовности.
   В пустую БД восстановите dump:

   ```sh
   docker compose --env-file infra/runtime/stand.env -f infra/compose.yaml exec -T postgres \
     pg_restore -U synapse -d synapse --exit-on-error --single-transaction \
     < /restore/snapshot/database/postgres.dump
   ```

6. Запустите configure для восстановления TURN/SFU config из env, затем весь стек
   с `up -d --wait`. В изоляции настройте тестовые DNS/доступ и почтовый sink;
   не допускайте отправку восстановленных scheduled jobs реальным пользователям.
   Проверьте вход, историю, файлы, клиентские ключи и звонок. Recovery control
   отзывает старые screen leases; убедитесь, что active/retired очередь пуста и
   capability=false. Backup серверов не заменяет пользовательские E2EE recovery keys.
7. Только после приёмки восстановления переключайте DNS/трафик. Не включайте
   два сервера с одной Matrix identity одновременно. Откат данных к snapshot
   теряет записи после его даты и требует отдельного решения.

Восстановление описано как процедура оператора, но ещё не принято реальным
restore drill. Фактические DNS, SMTP, ACME, TURN и физические устройства требуют
проверки после предоставления доступа к VPS.
