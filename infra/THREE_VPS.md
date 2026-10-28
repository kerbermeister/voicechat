# Подготовка отдельных core/edge ролей

Это локально проверенные описания служб и генераторы конфигурации. Существующий
production workflow остаётся single-host; новые bundle нельзя передавать старому
`deploy.py` как готовый релиз. Полный bootstrap, boot ordering, сертификаты/renewal,
интеграция role manifests в deploy/rollback ещё требуют реализации и приёмки.

Наглядные схемы: [один VPS, разнесённые роли, WireGuard и медиапути](../docs/architecture/network-topology.md).

## Проверка чистого хоста перед установкой

`host_preflight.py` запускается на целевом хосте через уже проверенное SSH-соединение.
Он только читает состояние, выдаёт JSON и exit code 1 при блокирующей проблеме:

```sh
python3 infra/host_preflight.py --inventory inventory.json --node edge-c
```

Для совмещённого A + edge-a указывается physical node `core`. Проверяются local
Ed25519 SSH host key относительно inventory, systemd/NTP, память/диск, TCP/UDP
порты, все IPv4 route tables и сети Docker. Published ports Docker проверяются
отдельно: DNAT может занимать порт без слушающего процесса. Конфликты с SSH port,
TURN/SFU ranges, remote tunnel /32 и edge bridge приводят к отказу. Ошибка
инспекции не заменяется пустым списком; команды ограничены по времени. Секреты и
полные container inspect/env не выводятся. При отдельном Docker data-root передать
`--disk-path` на соответствующем filesystem.

Начальный профиль проверки — Debian 12 amd64; это выбор для дальнейшего clean-host
bootstrap, не заявление о пройденной установке/перезагрузке VM. Другие ОС/архитектуры
и текущий A требуют отдельной адаптации без переустановки. Порог свободного места
2 GiB совпадает с действующим deploy guard; рекомендации 4/2 GiB RAM и 20/10 GiB
свободного диска для core/edge выдаются предупреждениями. Они не оценивают размер
рабочих данных, snapshot и фактическую нагрузку. Отсутствующие Docker/WireGuard
отмечаются как зависимости для последующей установки, а не устанавливаются.

Проверка намеренно предназначена для **чистого** хоста: занятый собственным старым
релизом порт также блокируется. Она не останавливает службы и не является режимом
миграции или повторного deploy. Provider firewall, доступность снаружи, DNS/TLS и
поддержка WireGuard ядром требуют отдельных проверок. Шесть unit-тестов прошли;
настоящий isolated Linux collector обнаружил UDP socket и route, а отсутствие
systemd/NTP/SSH host identity оставил ошибками. Это не clean VM acceptance.

## Scoped firewall и сохранённое состояние

`firewall_config.py` генерирует дополнительный nftables filter только для
VoiceChat. `firewall_runtime.py` проверяет владельца таблицы, валидирует batch
через `nft --check`, атомарно сохраняет intent и применяет delete+replacement
одной kernel transaction. Отсутствующая таблица восстанавливается через `--resume`.
Чужая/неучтённая таблица не присваивается даже при совпадающем имени.

```sh
python3 infra/firewall_config.py --inventory inventory.json --node core --output core.nft
# Следующие команды — только для подготовленного Linux host / тестовой VM:
python3 infra/firewall_runtime.py --directory /var/lib/voicechat-firewall \
  --inventory inventory.json --node core
python3 infra/firewall_runtime.py --directory /var/lib/voicechat-firewall --resume
```

При нестандартном bridge передать одинаковый `--edge-subnet` в renderer роли и
firewall. Compose задаёт стабильное имя bridge, вычисляемое из installation/edge ID;
preflight отклоняет уже занятое имя. Owner-only state/lock и atomic fsync/replace
переиспользуют `managed_state.py` с WireGuard runtime. Повтор после обрыва завершает
новое намерение; автоматического возврата отозванных peer permissions нет.

Правила INPUT и FORWARD разрешают private API/signaling только через `wg-vc` от
известных peer /32. Для совмещённой роли разрешены local web/health IP на её bridge,
но не coturn. Публичный SFU принимает media от edge public IP или локального coturn.
WireGuard UDP 51820 ограничен peer IP; произвольный транзит из туннеля запрещён,
даже если peer самостоятельно расширил AllowedIPs. FORWARD проверяет исходные
адрес/порт conntrack до DNAT и отличает reply direction. Другие host policy могут
дополнительно запретить трафик; filter не делает глобальный flush/accept и не
открывает порты в firewall провайдера. Семантика сверена с
[nftables manual](https://netfilter.org/projects/nftables/manpage.html).

Проверено на nft 1.0.6: эта версия не выводит table comment в JSON, поэтому runtime
строго проверяет начальные строки textual table header/comment. Тестовый nft parser
также потребовал `meta l4proto` перед conntrack port expressions.

`check_firewall_config.py --tools-image sha256:…` проверяет настоящие Linux
INPUT/FORWARD/DNAT, разрешённые и запрещённые HTTP/UDP пути, hostile peer transit,
co-located roles, повтор и восстановление таблицы, сохранение посторонних таблиц.
87 общих infra regressions прошли; после общего state helper повторный kernel
WireGuard probe тоже прошёл. Повторный TLS/SNI/role probe проверил стабильный bridge.

Это ещё не production boot/rollout. Требуются host packages/systemd, согласование
с существующим firewall/Docker, provider ACL и внешняя приёмка. Core bundle
закрепляет media binds за конкретным inventory IPv4, независимо от legacy BIND;
IPv6/вторичные адреса через эти публикации не открываются. Стабильный core bridge
дополнительно закрывает прямую маршрутизацию к контейнерам, сохраняя внутренние
соединения core. SFU-инициированные UDP потоки проверяются и в reply direction:
созданный сервером NAT mapping не открывает прямой клиентский доступ в обход edge.
Core containers резервируют UDP media range от автоматического назначения портов,
чтобы это правило не мешало исходящим DNS/client sockets; явный SFU bind сохранён.
Настройка относится только к namespace контейнеров, не к host sysctl; семантика:
[Linux ip_local_reserved_ports](https://docs.kernel.org/networking/ip-sysctl.html).
Существующий `voicechat_default` требует отдельной
миграции bridge: renderer не пересоздаёт сеть работающего A. У первоначального неудачного fixture
`voicechat-firewall-61bd4566a853_local` Docker оставил пустую сеть с ошибкой
`active endpoints`; адресная очистка отказала. Docker не перезапускался ради неё;
финальный исправленный fixture использует настоящий bridge без переименования
Docker-интерфейса и полностью очищен. В этой пробе нет опубликованных host-портов
или Internet requests; internal Docker bridges не подходят, поскольку сами
блокируют проверяемые routed packets ещё до нашего filter.

## Согласованное восстановление сети и порядок старта

Для нового управляемого хоста использовать общий `network_runtime.py`. Он хранит
одно authoritative desired state, проверяет оба компонента, применяет firewall
перед WireGuard и завершает тот же intent после сбоя между шагами:

```sh
python3 infra/network_runtime.py --directory /var/lib/voicechat-network \
  --inventory inventory.json --public-keys tunnel-public-keys.json \
  --node core --private-key /private/runtime/wireguard.key
python3 infra/network_runtime.py --directory /var/lib/voicechat-network --resume
```

Внутренние `firewall/` и `tunnel/` snapshots принадлежат coordinator; не обновлять
их отдельно. Весь каталог 0700 содержит node-local private key и не передаётся
другим узлам. Старый standalone tunnel directory автоматически не преобразуется:
для него нужна явная миграция. Invalid state/identity, foreign interface/table,
конфликтующие route и parallel apply отклоняются. Тест обрывает исполнение после
нового firewall, но до нового WireGuard, затем проверяет завершение отзыва peer.

`voicechat-network.service` вызывает общий resume до Docker. Drop-in
`voicechat-docker-network.conf` добавляет Docker `Requires`/`After` на этот unit;
невалидный/отсутствующий intent не должен пропускать старт контейнеров. На stop
правила и tunnel не удаляются. Обычное изменение peers выполняется coordinator,
а не restart systemd unit: остановка требуемого unit может остановить Docker.
Unit и drop-in входят в manifests обеих ролей. На подготовленном Linux host
`python3 infra/network_bootstrap.py` устанавливает их и immutable исходники в
`/opt/voicechat/network/<source-hash>`, затем проверяет unit, включает и запускает
сетевой сервис. До этого должны существовать dependencies и общий network state.
Проверяются SSH identity текущего хоста, рабочий systemd и необходимые команды.
Owner-only receipt позволяет продолжить оборванное копирование/activation; чужие
units/files/symlinks и изменённые установленные файлы не перезаписываются. Повтор
той же версии поддерживается. Для обновления **уже управляемой** установки:

```sh
python3 -B infra/network_bootstrap.py --upgrade
```

Обновление проверяет прежние immutable исходники и systemd units по receipt,
сохраняет journal, устанавливает новую версию и вызывает `ExecReload`. Docker
не перезапускается; PID/время старта проверяются до и после. Незавершённый upgrade
блокирует edge deploy; повторять нужно ту же версию исходников. Старые каталоги
сохраняются. Автоматического отката ACL нет: он мог бы вернуть отозванных peers.
Applied fingerprint включает inventory и код сетевой политики, поэтому receipt
старого кода не разрешает новый deploy. Изменять роль/идентичность этим способом нельзя.

Настоящие initial install/repeat/reboot/fail-closed проверки выполнены в disposable
Debian VM, см. `docs/iterations/three-vps-evidence/2026-10-28-vm-network-boot.json`.
Обновление source через reload, повтор и reboot также проверены:
`docs/iterations/three-vps-evidence/2026-10-28-vm-network-upgrade.json`.
Это не разрешает без миграции добавлять зависимость чужому или текущему production
Docker host. Установка пакетов и общий SSH bootstrap пока не завершены.

`check_network_service.py` использует настоящий Debian systemd 252 parser в
read-only контейнере без сети/capabilities: позитивная проверка units, отказ при
missing state и отрицательный dependency cycle прошли. Это не запуск PID 1 и не
доказательство reboot VM. Порядок зависит от
[systemd Requires/After semantics](https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html).
Реальный `check_tunnel_runtime.py --with-firewall` проверяет coordinated
B replacement, D addition, recreation interface, container restart from disk и
zero-peer A, сохраняя C и не перезапуская A при изменении peers.

## SSH к выбранному физическому узлу

`host_connection.execute(inventory, node, identity_file, argv, ...)` — общий
transport для дальнейшего bootstrap/rollout. Он использует отдельный временный
known_hosts только с проверенным Ed25519 key выбранного inventory node. Отключены
наследование user SSH config, connection multiplexing, agent forwarding и
автоматическое обновление host keys; включены StrictHostKeyChecking/BatchMode и
ограниченные timeouts. Файл client identity должен быть owner-only regular file.
Remote argv экранируется через shlex; credentials передавать через stdin, а не argv.
Captured output нельзя без разбора печатать: вызывающая операция может возвращать
конфиденциальные данные. Смена поколения хоста проверяется inventory orchestration.

Три unit tests и `check_host_connection.py --tools-image sha256:…` проверили
настоящий OpenSSH 9.2p1: verified login, отказ неизвестному/старому host key после
rotation, сохранение literal shell metacharacters и binary stdin. Непроверенная
команда не исполняется. Используются synthetic keys и internal bridge без host
ports; нет обращения к текущему VPS или изменения пользовательского known_hosts.
Это transport, не завершённая установка пакетов/TLS/role rollout.

## Подготовка WireGuard

`tunnel_config.py` генерирует ключ конкретного физического узла и его приватную
конфигурацию `wg-vc.conf`. Он не устанавливает пакеты, не создаёт интерфейс, не
меняет маршруты/firewall и не соединяется по SSH. Будущий bootstrap должен запускать
генерацию ключа на самом целевом хосте через проверенное SSH-соединение. Приватные
ключи других узлов не копируются на A, edge или orchestrator.

```sh
python3 infra/tunnel_config.py key --private-key /private/runtime/wireguard.key
python3 infra/tunnel_config.py render --inventory inventory.json \
  --public-keys tunnel-public-keys.json --node edge-c \
  --private-key /private/runtime/wireguard.key --output /private/runtime/wg-vc.conf
```

Родительский runtime-каталог предварительно создаётся с правами 0700. `key` выводит
только public key и сохраняет существующий исправный private key; неверные права,
владелец, symlink и повреждение приводят к отказу. OpenSSL создаёт X25519 key;
производные public keys дополнительно проверены настоящим Linux WireGuard.
Public registry строится по `tunnel-public-keys.example.json`, только после
проверенного получения ключей конкретных host generations из inventory.

Один физический core+edge требует только запись `core` в registry, без `edge-a`.
У core остаётся private /32 address и ноль peers. Для нескольких VPS каждый edge
получает только peer core и его /32; core получает отдельный peer каждого удалённого
edge. Endpoint — IP из inventory, UDP 51820; оба конца используют keepalive 25 с.
Это также инициирует новый handshake при восстановлении интерфейса A: правило
только на edge оставляло старые peer sessions до rekey. Поведение link-up сверено
с [Linux WireGuard](https://git.zx2c4.com/wireguard-linux/plain/drivers/net/wireguard/device.c).
Default route, DNS settings, чужие interfaces и произвольные shell hooks не меняются.
Ключи/generation/identity проходят строгую проверку перед записью; output-файл
создаётся 0600 без перезаписи существующего.

`tunnel_runtime.py` применяет желаемое состояние на подготовленном Linux host.
Все networking команды ниже относятся к будущему целевому хосту/тестовой VM;
на текущем VPS они не выполнялись.

```sh
python3 infra/tunnel_runtime.py --directory /var/lib/voicechat-network \
  --inventory inventory.json --public-keys tunnel-public-keys.json \
  --node core --private-key /private/runtime/wireguard.key
python3 infra/tunnel_runtime.py --directory /var/lib/voicechat-network --resume
```

Runtime управляет только `wg-vc`, его private /32 и peer /32 в main route table;
default routes, forwarding, firewall и чужие interfaces не меняет. Каталог 0700,
state/lock/temp config 0600, проверяются owner/regular file/symlink и exclusive
lock. `desired.json` содержит собственный private key и публичные данные peers;
его нельзя публиковать или копировать на другой узел. Intent сохраняется атомарно
с fsync **до** применения, поэтому после прерывания `--resume` доводит новое
состояние до конца, не возвращая автоматически отозванный peer.

До записи/изменений проверяются collisions, тип/ключ существующего интерфейса,
локальные адреса и main-table routes. Существующий чужой wg-vc не присваивается
проекту. Собственная host identity/address/key не меняется этим режимом: перенос A
требует отдельной процедуры. Peer key rotation требует нового поколения и
проверенного SSH host key в inventory. После syncconf добавляются недостающие
/32 и удаляются устаревшие маршруты только своего интерфейса; MTU установлен 1420,
проверка внешнего PMTU ещё нужна. Полный конфиг включает PrivateKey, чтобы syncconf
не очистил identity. Ошибка не объявляется успешной готовностью API.

Реальная проверка: `prototype/check_tunnel_runtime.py --tools-image sha256:…`.
Она подтвердила повтор, live replacement B с отказом прежнему ключу, добавление D
и маршрута, восстановление удалённого интерфейса, запуск остановленного контейнера
из persistent state, удаление peers/routes с сохранением private A. Это не reboot
полноценной VM: systemd installation/order, ACL и rollout остаются открытыми.
`tunnel_runtime.py` не устанавливает пакеты, не включает автозапуск и не обращается
по SSH. На boot он должен запускаться из закреплённых исходников до собственных
core/edge Compose units; интеграция ещё не реализована.

Локальная проверка использует отдельные Linux namespaces и внутреннюю Docker-сеть:

```sh
docker build -f prototype/tunnel.Dockerfile -t voicechat-tunnel-probe:local .
docker image inspect --format '{{.Id}}' voicechat-tunnel-probe:local
python3 prototype/check_tunnel_config.py --tools-image sha256:REPLACE_WITH_LOCAL_IMAGE_ID
```

Fixture image — только тестовые инструменты с закреплёнными Debian package
versions, не production bootstrap. Runner требует `NET_ADMIN` только внутри своих
контейнеров, не `--privileged`/host network; наружу порты не публикуются. В evidence
фиксируется конкретный image ID. Подтверждены B/C→A HTTP через WireGuard, отказ B,
смена его ключа, отказ старому ключу, восстановление новым, неизменный StartedAt A и
рабочий C; затем private API A с нулём peers. IP endpoints заменены внутренними
адресами тестовой сети. Это не проверка provider firewall, MTU внешнего пути,
Docker DOCKER-USER ACL, reboot или bootstrap чистой VM.

## Конфигурация сборок клиентов

Все существующие workflow сборки клиентов принимают необязательные публичные
variables `CLIENT_ROUTE_CONFIG` (JSON bootstrap topology) и
`CLIENT_ROUTE_CATALOG_KEY` (base64 Ed25519 public key). Указывать оба либо ни одного;
`canonical_origin` обязан совпадать с `PUBLIC_URL`. Это public values, не private
signing key. Значения должны описывать одну installation во всех используемых
repository/environment contexts. D/E затем добавляются каталогом без изменения
этих build variables и без новой сборки установленного клиента.

```sh
python3 infra/client_config.py --environment "$PUBLIC_URL" /tmp/client.json
```

Без variables команда сохраняет legacy single-host defines. Старый вызов без
`--environment` намеренно не читает окружение, в частности при серверном configure.
Ручной `--topology ... --catalog-key-file ...` также остаётся доступен.

Web build-only, Android preview/release candidate и macOS candidate подготовлены
к такому вводу. Реальные GitHub variables здесь не менялись и Actions не запускались.
Пока role rollout не подключён, workflow запрещает routed web deploy через legacy
`deploy.py` и публикацию routed APK. Это временный явный gate, а не готовый новый
режим развёртывания. Старые single-host сборки и проверки остаются доступны.

Android candidate сохраняет public `client-config.json`. Повторное использование
APK проверяет точное совпадение с его записанной конфигурацией до repackaging;
нельзя приписать уже собранному APK другой каталог или ключ. Legacy candidate без
этого файла разрешён только при legacy-конфигурации, без включения routes.

## Браузерные проверки

Общий route transport, coordinator, media recovery boundary и индикатор состояния
проверяются в настоящем Chrome с теми же JSON fixtures, что и native тесты:

```sh
python3 prototype/check_route_web.py --flutter .prototype/tools/flutter/bin/flutter
```

При необходимости задать `CHROME_EXECUTABLE` на установленный Chrome. Пройдено
29 тестов, включая раздельное переключение Matrix/control/WSS, отсутствие replay
мутаций, lifecycle/authorization guards и сохранение focus/draft в индикаторе.
`route_fixture.dart` получает исходные infra examples через test-only defines; они
не копируются в production assets. Это browser contracts с mock boundaries, не
реальный звонок или расшифровка потока. В widget-тесте сетевые stream callbacks
выполняются через runAsync вне fake clock; иначе браузерная проверка зависала.

Отдельный `prototype/check_route_catalog_web.py` проверяет настоящую WASM подпись,
loopback HTTP discovery и browser localStorage. Перед ним обязательно пересобрать
assets по `infra/crypto-tools.json` через `prototype/build_web_assets.py`.

```sh
python3 prototype/check_route_catalog_web.py \
  --flutter .prototype/tools/flutter/bin/flutter --node /absolute/path/to/node
```

Node должен находить уже установленный Playwright (при необходимости NODE_PATH);
Chrome задаётся CHROME_PATH. Создаётся отдельная JS release-сборка с entrypoint
`tool/route_catalog_web_probe.dart`, временный каталог и новый browser profile.
Проверяются подпись OpenSSL→browser crypto, получение D из каталога, rollback,
tamper, expiry, foreign identity, конфликт одинаковой revision и настоящее
перечитывание localStorage после перезагрузки страницы с недоступными входами.
Проверки используют явные условия, а не отключённые в release assert. Оба endpoints
слушают только loopback, профиль/подписывающий ключ синтетические. Все эти проверки
прошли; это не production release и не приёмка Matrix account recovery/media.

Используется обычный JS-путь, как у текущего web-клиента. Dart/Wasm сборка в
закреплённом flutter_rust_bridge имеет runtime incompatibility в decoder и не
считается поддержанной. CanvasKit test runner Flutter 3.47 также не проставляет
COEP на test iframe при отдельном isolation flag. Вместо изменения SDK или
отключения защиты standalone probe обслуживается с настоящими COOP/COEP.

## Манифесты отдельных ролей

`role_release.py` готовит и проверяет отдельный `role-manifest.json` schema 1.
Это другой формат, чем legacy manifest `deploy.py`; смешивать их нельзя.
В manifest входят immutable digests всех служб роли, commit, installation identity,
hash topology/host assignment, точные hashes всех файлов bundle и версии контрактов
route/config/core API/storage. Последние — версии совместимости данного release
tooling, не номера внутренних миграций PostgreSQL/Synapse. Несовместимые изменения
API/config/storage требуют явного повышения контракта и процедуры миграции.

Пример после review/commit исходников и получения digest из сборки:

```sh
python3 infra/role_release.py --topology topology.json --inventory inventory.json \
  --role edge --edge c --image "$WEB_IMAGE" \
  --bundle /tmp/voicechat-edge-c-review --output /tmp/edge-c-role-manifest.json
```

Команда не обращается к registry/SSH и ничего не развёртывает. Она требует чистое
дерево исходников, заново сверяет полный bundle с генератором и не перезаписывает
существующий manifest. Runtime secrets и TLS не входят в hashes исходников;
их пригодность проверяется отдельными deploy gates. Checksums сами по себе не
подтверждают происхождение образа: digest должен поступить из доверенной сборки.

`require_web_only` разрешает менять только web digest и commit существующего edge.
Изменения Caddy/security config, topology, host, TURN и остальных source files
требуют другого режима. `require_compatible` допускает разные topology revision
при поэтапном добавлении входа, но требует одинаковые installation identity и
поддерживаемые контракты. Неизвестные версии, теги вместо digests, missing baseline,
неполный/подменённый bundle и symlink files отклоняются. Существующий fingerprint
`release_source.py` и legacy production guards не изменены.

Пока это проверенный локальный контракт для V3-19. Он ещё не записывает отдельные
current/previous, не выполняет backup/pull/rollout/rollback и не подключён к CI.

## Входные данные и локальная генерация

Для старта с одним VPS используются `single-vps.example.json` и
`single-node-inventory.example.json`: единственный edge ссылается на `host: core`.
Генерируются две прежние роли (`--role core` и `--role edge --edge a`), а не
сливается runtime/Compose проекта A с входом. На хосте остаются проекты `voicechat`
и `voicechat-edge-a`; порты API привязаны к private core address, публичные 443/TURN
принадлежат edge. Нельзя одновременно запускать прежний single-host web/TURN на тех
же портах: production migration должен переключить службы и сохранить данные A.

Private `tunnel_ip` A должен реально существовать на хосте и быть доступен edge
контейнерам даже при отсутствии удалённых peers. Его подготовка относится к
bootstrap (например, WireGuard interface без peers на первом шаге); renderer не
создаёт интерфейсы. Удалённые входы позже используют этот же private API endpoint.

Для добавления B/C — новые записи public topology и physical inventory, подготовка
хостов/туннелей/TLS, проверка, новая signed revision. Для переноса edge-a на отдельный
VPS ссылка `host: core` заменяется полным assignment с большим generation и новым
SSH host key; renderer проверяет переход через `--previous-inventory`. Можно вместо
переноса добавить B/C, сохранить старый bootstrap hostname доступным, а затем
вывести edge-a из каталога и остановить только его проект. Core volumes/identity
не переносятся. Не допускаются две ссылки на core: они конфликтовали бы за порты.

Один физический VPS пока остаётся одной точкой отказа. Два Compose projects сами
по себе не защищают от потери/блокировки машины и не изолируют компрометацию root.

Публичный `three-vps.example.json` содержит постоянную Matrix identity, web origins
и список входов. `node-inventory.example.json` содержит отдельные host assignments:
public/tunnel IPv4, поколение, проверенный SSH host key. Примеры необходимо заполнить;
placeholder host keys и документационные IP не являются рабочими адресами.

```sh
python3 infra/render_roles.py --topology topology.json --inventory inventory.json \
  --role core --output /tmp/voicechat-core-review
python3 infra/render_roles.py --topology topology.json --inventory inventory.json \
  --role edge --edge c --output /tmp/voicechat-edge-c-review
```

Выходной каталог должен отсутствовать. Генерация не читает рабочие секреты и
не вызывает Docker, SSH или DNS. При replacement передать предыдущий inventory
через `--previous-inventory`: изменённый host assignment требует большего поколения
и нового проверенного SSH host key. Новые D/E используют тот же генератор.

Bridge subnet edge по умолчанию `10.241.0.0/28`, при конфликте — `--edge-subnet` с
другой RFC1918 `/28`. Адреса ingress `.2`, web `.3`, TURN `.4`, readiness `.5`,
configure `.6` фиксированы внутри выбранной подсети. Генератор проверяет пересечение
с известными tunnel IP; будущий host preflight обязан проверять все сети хоста.
Параметр bridge не попадает в подписанный публичный каталог.

Bundle содержит `infra/compose.core.json` либо `infra/compose.edge.json`, необходимые
скрипты/config и описание узла. `known_hosts` и `node.json` имеют 0600, корень — 0700.
Публичные source/config mounts — 0644 для чтения непривилегированными container UID.
Runtime-каталоги созданы пустыми. Это не установка и не готовая команда production `up`.

## Проверка и локальная публикация каталога

`route_catalog.py` подписывает offline и проверяет Ed25519 через OpenSSL 3.
`publish_catalog.py` принимает только подписанный документ, проверяя закреплённый
публичный ключ, service/Matrix identity, canonical origin, schema, размеры, сроки
и revision. Ключ берётся из заранее доверенного файла, не из каталога или сети.

После offline signing можно подготовить каталог в сгенерированном edge bundle:

```sh
python3 infra/publish_catalog.py --catalog routes-v1.json \
  --catalog-key-file public-key.txt --bootstrap-topology topology.json \
  --directory /tmp/voicechat-edge-c-review/infra/runtime/catalog --initialize
```

`--initialize` разрешён только для нового пустого runtime. Для следующих версий
в той же директории запускать без него. Публичный `routes.json` одновременно служит
проверенным high-water mark: уменьшение revision, другое содержимое той же revision,
повреждение или исчезновение прежнего файла прерывают публикацию. Истёкший прежний
файл сохраняет защиту от отката; новый документ обязан быть действующим. Повтор
того же подписанного payload идемпотентен. Файловый lock сериализует локальных
писателей; временный файл и atomic rename/fsync сохраняют целостность при сбое.
Монтируется директория каталога, поэтому Caddy видит замену без restart.

Это примитив публикации **на одном локальном filesystem**, не multi-host deploy.
Будущий orchestrator должен хранить runtime/high-water mark вне сменяемых release
директорий и сохранять его при rollback; новый bundle не является разрешением
сбросить состояние существующего входа. На все узлы передаётся один и тот же
проверенный release artifact, а не новая подпись с каждого узла. При частичном
успехе нужны per-node результаты и повтор распространения; глобальный lock,
readback по HTTPS и release manifest пока не реализованы.

Порядок добавления D: подготовить и проверить его proxy/TURN/TLS, расширить core
TURN/CORS и web origins известных входов, затем выпустить большую revision и
опубликовать её на известных входах. Публичный каталог не меняет сам runtime proxy.
При удалении входа сначала выпустить каталог без него, сохранить доступные
bootstrap-домены и только затем завершать его эксплуатацию. Для скомпрометированного
узла требуется немедленный отзыв доступа и отдельная процедура ротации, а не ожидание
плановой публикации. Реальные readiness/propagation/revocation ещё требуют приёмки.

## Границы ролей

| Роль | Службы | Постоянные данные |
| --- | --- | --- |
| Core A | PostgreSQL, Synapse, единый control/SFU, одноразовый configure | Прежние `voicechat_postgres`, `voicechat_synapse`, `voicechat_control`, `voicechat_media-config` |
| Edge B/C/D | HAProxy, Caddy/web assets, readiness, coturn, одноразовый configure | Только `voicechat-edge-ID_turn-config` с конфигурацией TURN; пользовательских БД/media нет |

Core использует `extends` существующего `compose.yaml`; image entrypoint сохраняет
совместный lifecycle control/SFU. Существующие политика доступа, signing key path,
media path и именование томов не переписаны. Унаследованный `turn-config` остаётся
объявленным на A для совместимости base configure mounts, но multi-route configure
его не заполняет, а TURN-службы в core нет. Старые тома нельзя удалять при миграции.
Реальная миграция обязана проверить установленные project/volume names и overrides:
имена выше подтверждены для стандартного проекта `voicechat`, не для произвольного A.

`VOICECHAT_ROUTE_CONFIG` задаётся сгенерированной core-role конфигурацией. Перед
записью `configure.py` сравнивает её identity/origin с существующим core env;
несовпадение отвергается. Из topology формируются Synapse TURN URLs (UDP/TCP 3478,
TLS TCP 443) и точный `VOICECHAT_ORIGINS`; canonical origin остаётся первым для push.
При отсутствии этой переменной старый single-host configure работает как прежде.

Core API ports 8088 (Matrix), 8090 (control) и 7880 (WSS) привязаны к tunnel IP.
Сохраняются прежние loopback Matrix port и media ports control 7981/TCP,
50300–50400/UDP. Tunnel binding сам по себе не заменяет firewall/peer ACL.
TURN relay направляется к публичным media candidates A: private peer destinations
запрещены. WireGuard здесь нужен для API, схема закрытого SFU ещё требует отдельной
проверки сетевой политики.

Edge публикует 443/TCP (SNI HTTPS/TURN TLS), 3478/TCP+UDP и 49300–49400/UDP.
Web и TURN требуют разных hostname/certificates. Upstream адреса взяты из inventory;
edge не зависит от локальных Synapse/control. Readiness проверяет путь до A,
состояние процесса Caddy отдельно проверяет container healthcheck.

## DuckDNS и подготовка сертификатов

По решению владельца от 28 октября 2026 сохраняем DuckDNS и действующий
`univc.duckdns.org`. Свой домен + Cloudflare **DNS only**, ограниченный зоной API
token и контролируемая миграция — невыполненная целевая задача V3-T04.
Новые DuckDNS имена для независимых входов ещё не выделены. Вложенные имена одного
DuckDNS имени не дают независимо управляемые IP всех входов; план имён нужно
проверить до внешнего запуска. Matrix identity и старый bootstrap сохраняются.

`acme.py` без `--execute` только проверяет topology/inventory и выводит план:

```sh
python3 infra/acme.py --topology /private/config/topology.json \
  --inventory /private/config/inventory.json --config infra/acme-duckdns.example.json \
  --edge b --service web
```

Example содержит только текущий DuckDNS domain, не готовую схему B/C. Имена topology
должны принадлежать явно перечисленным DuckDNS base domains. Контактный email
заменить перед выпуском. Основной и edge hostname включаются в web-сертификат;
TURN использует отдельный сертификат и ключ. Добавление нового поколения узла
создаёт отдельный certificate ID и новый ключ, даже если DNS имя осталось прежним.

Реальное выполнение требует `--execute --directory <private-controller-state>
--token-file <0600-token> --accept-tos`. Оно обращается к CA и **меняет DNS TXT**;
сейчас этот режим не запускался. Последним сообщением владелец разрешил необходимые
внешние работы, но перед выпуском нужны подготовленные реальные имена/credentials.
Один управляющий
host и один state directory используются для **всех** входов/плановых renewals этого
DuckDNS аккаунта. Staging и production имеют разные каталоги; receipt запрещает
смену окружения/email внутри существующего состояния. Не запускать независимые
контроллеры/ACME клиенты с тем же token: локальный flock не является распределённым.

Закреплённый digest lego 5.5.2 находится в `acme-tools.json`. Стандартный клиент
выполняет issuance/renewal с DNS-01 и проверкой propagation; wrapper не реализует
свой ACME протокол. Общий lock сериализует web/TURN/B/C, а DuckDNS provider lego
сериализует проверки имён внутри заказа. Token передаётся через отдельный приватный
временный file mount; он не включается в argv, role bundle, manifest или вывод.
Контейнер без capabilities, host ports, Docker socket и host networking; только
ACME state writable. CNAME delegation выключен, чтобы не менять чужие TXT цели.

При обрыве/неопределённом create или cleanup остаётся `inflight.json`; любой новый
job отказывается работать до reconciliation. Проверить указанный контейнер,
его mounts/image и отсутствие работающего DNS writer, завершить именно этот job;
только после этого удалить pending receipt и повторить операцию. Не удалять marker
для обхода ошибки. Нормальный failure останавливает/удаляет свой контейнер, скрывает
provider diagnostics (там возможен token-bearing URL) и сохраняет прежние staged
сертификаты. Raw Docker/lego stdout/stderr не публиковать в CI.

`tls_material.py` проверяет chain/key из снимка файлов: SAN для каждого имени,
совпадение ключа, serverAuth, доверенную полную цепочку и срок всей цепочки сейчас
и через 7 дней. CN fallback и encrypted key запрещены. Для изолированного стенда
есть `--ca-file` и `--minimum-validity-days`; production ACME не допускает override
системного trust store. Сертификаты Let's Encrypt staging не являются production
доверенными: нужен явный staging CA bundle, без добавления его в trust ОС.

Проверенная пара публикуется атомарно в отдельный каталог SHA-256, 0700/0600;
повтор не перезаписывает её, изменённые/неполные поколения отвергаются. Старые пары
сохраняются. Этот staging **не переключает** `/tls` работающего контейнера и не
является завершённой активацией/продлением службы.

Следующий шаг `tls_runtime.py` публикует проверенную пару в `runtime/tls`:

```sh
python3 infra/tls_runtime.py --root /private/edge/infra/runtime/tls \
  --topology /private/config/topology.json --edge b --service turn \
  --chain /private/candidate/turn.crt --key /private/candidate/turn.key
```

На целевом Linux publisher работает от root (обязательно для TURN). Он сохраняет
внутри стабильного mount каталоги `generations/<hash>` и атомарно меняет `current`;
постоянные `web.crt/key` или `turn.crt/key` — относительные aliases. Caddy получает
0600 root, coturn — 0640 root:10001 с каталогами 0750 root:10001. Весь родительский
runtime/tls и private verification store остаются 0700 root. TURN читает свой ключ,
не может его менять и не получает mount веб-ключа.

Receipt различает `prepared` и `selected` **на диске**, не заявляет успешную загрузку
сертификата процессом. Повтор завершает прерванное копирование/переключение той же
пары; другая пара до завершения pending intent запрещена. Existing real files,
чужие symlinks/identity и изменённые поколения не перезаписываются. Откат повторно
проверяет старую пару и срок действия. Новые renderer bundles сразу создают
runtime/tls с 0700; старый незавершённый bundle с другими правами не следует
автоматически присваивать publisher.

Для уже запущенного edge используется `tls_activation.py`: он удерживает тот же
writer lock от публикации до reload и проверки фактически отдаваемого сертификата.
Вызов требует полного container ID, immutable image digest из manifest и точного IP
нового узла (DNS менять не нужно):

```sh
python3 infra/tls_activation.py --root /private/edge/infra/runtime/tls \
  --topology /private/config/topology.json --edge b --service turn \
  --chain /private/candidate/turn.crt --key /private/candidate/turn.key \
  --container "$CONTAINER_ID" --image "$TURN_IMAGE_DIGEST" --address "$EDGE_IP"
```

Перед изменениями проверяются running state, Compose project/service и точный
read-only `/tls` bind mount. Caddy получает SIGUSR1, coturn SIGUSR2; fresh TLS
handshake проверяет CA, каждый обязательный SNI и точный leaf сертификат. После
проверки container ID/StartedAt/RestartCount должны совпасть. Только тогда отдельный
`<service>.activation.json` переходит из `pending` в `verified`. Повтор для той же
проверенной пары повторяет handshake без reload, чтобы не обрывать соединения.
Сбой оставляет `pending`, старые поколения не удаляются. Можно повторить ту же
пару либо явно передать предыдущую ещё действительную пару для отката; она заново
валидируется. Receipt — свидетельство проверки, а не постоянный монитор здоровья.
Первоначальное заполнение до старта контейнера выполняет disk publisher.

Это ещё не полный lifecycle: безопасная доставка, координация общего role deploy
с TLS writer lock, scheduler и внешний issuance/renewal drill остаются открыты.
Самостоятельный вызов disk publisher не заменяет активацию. Два активных PEM по
очереди не менять. Изменение сертификата Caddy может закрыть соединения: обещание
непрерывного WSS или звонка из этой TLS проверки не следует.

Локально проверены 5 TLS и 6 ACME tests, реальный TLS role probe
`voicechat-sni-5e605f23ed78` и CLI закреплённого lego с fake token в `--network none`.
Последняя проверка доказывает parsing/отказ сети/cleanup, **не выпуск сертификата**.
Дополнительный role fixture `voicechat-sni-fd60e4e81b97` проверяет атомарный
`current` symlink внутри стабильного bind-каталога, Caddy SIGUSR1 / coturn SIGUSR2
и откат к предыдущей ещё действительной паре. Новые TLS handshakes видят нужный
сертификат, TURN allocation на прежнем TLS connection сохраняется, ID/StartedAt/
RestartCount контейнеров не меняются. Это тестовый publisher, не production
activation tool. Первая проба обнаружила закрытие idle HTTPS keep-alive при Caddy
reload; непрерывность WSS и реального звонка не доказана. Свежий HTTPS работает.
Все новые контейнеры/сети очищены; VPS/DNS/CA API не использовались.
Источники: [DuckDNS API](https://www.duckdns.org/spec.jsp),
[lego DuckDNS provider](https://go-acme.github.io/lego/dns/duckdns/),
[lego certificate storage](https://go-acme.github.io/lego/obtain/index.html).

## Раздельный deploy подготовленного edge: текущий этап

`edge_deploy.py` реализует локальный на целевом узле controller для `edge` и `web`.
Он ещё не подключён к release workflow и не заменяет миграцию старого production.
Запускать из проверенного полного operator checkout; generated bundle содержит
runtime сервисов, а не весь orchestration toolkit.

Условия: подтверждённый core role manifest; подготовленная сеть и active
`voicechat-network.service`; `applied.json` с `phase=complete` для того же inventory;
private root `releases/<manifest-sha256>` и `runtime`; runtime каждого release — symlink
на общий `root/runtime`, TLS и TURN secret подготовлены заранее.
`role_prepare.py` создаёт эти paths из проверенного operator checkout: сверяет
manifest с текущими sources/config, сохраняет владельца роли в `role.json`,
атомарно публикует новый bundle. Секреты не создаёт и не копирует, службы не запускает.
ID каталога — SHA-256 полного manifest: конфигурационный релиз при прежнем Git
commit получает собственный каталог, а старые bind mounts остаются доступными.
Повторная подготовка проверяет существующий bundle, не перезаписывает его.
Чужой непустой root и подменённые files/symlinks автоматически не принимаются.

```sh
python3 infra/role_prepare.py --root /srv/voicechat-edges/b \
  --topology /private/config/topology.json --inventory /private/config/inventory.json \
  --manifest /private/candidate/release.json
```

```sh
python3 infra/edge_deploy.py --root /srv/voicechat-edges/b \
  --topology /private/config/topology.json --inventory /private/config/inventory.json \
  --manifest /private/candidate/release.json --core-manifest /private/current-core.json \
  --scope web --edge-subnet 10.241.0.0/28
```

Порядок lock: edge root → host network → TLS. Pull предшествует изменению
контейнеров; validated source bundle, immutable digests, существующая rollback
база, TLS и completed network intent проверяются до `up`. `web` допускается
только при совпадении всех остальных role inputs и использует `--no-deps web`;
ID/StartedAt/RestartCount ingress/TURN/readiness должны сохраниться. Команд к core
нет. Edge scope обновляет свой Compose project, не другие входы.

Один atomic `state.json` хранит current/previous/pending. Фазы prepared/applying/
rollback позволяют продолжить тот же target после прерывания; другая кандидатура
до завершения операции запрещена. После TLS CA/SNI/leaf и `/health/route` checks
committed pointer меняется атомарно. Ошибка откатывает прежний edge release;
неудачный rollback остаётся pending и повторяется следующим запуском. При первом
неудачном запуске controller останавливает только собственный project, не удаляя
volumes. Existing project без baseline автоматически не присваивается.

Проверка логики: fault-injected subprocess tests с настоящими source bundles и
файловым журналом. Дополнительно [реальный VM fixture](../docs/iterations/three-vps-evidence/2026-10-28-vm-edge-deploy.json)
прошёл initial edge deploy, web-only с прежними ingress/TURN/readiness процессами,
config-only на том же commit, rollback после HTTP 503 и resume после прерывания.
В нём настоящие Docker/network/TLS/controllers, синтетические Matrix/control
upstreams; это не приёмка core/БД/звонков или production migration.
Pull использует `--policy missing` только для immutable digests; существующий
image cache позволяет выполнить конфигурационный rollout без registry credential.
Открыты SSH доставка,
доставка секретов/host packages, core/full orchestration, coordinated multi-edge rollout,
workflow/build-only и legacy shared-ingress migration. Собственный controller
не является разрешением обойти существующие production release guards.

## Приватный server push callback

В core role новые push-подписки получают gateway
`http://<core.tunnel_ip>:8090/_matrix/push/v1/notify`. Запрос Synapse остаётся
внутри A, даже когда нет доступного публичного edge. Контакты/ссылки и browser
origin по-прежнему канонические; отправка к push provider остаётся HTTPS.

`configure.py` разрешает в Synapse только этот RFC1918 адрес `/32`, не меняя
стандартный `ip_range_blacklist`. Host ACL допускает к нему только TCP 8090
из принадлежащего core Docker bridge, включая исходный адрес/порт до DNAT.
Остальные private/metadata адреса и внутренние порты этим правилом не открываются.
[Linux INPUT/FORWARD/DNAT проверка](../docs/iterations/three-vps-evidence/2026-10-28-private-push-firewall.json)
прошла с прежними ACL и без перезапуска production служб.

Ограничение миграции: сохранённые ранее Matrix pushers имеют прежний URL.
До production rollout нужен контролируемый перенос этих записей под согласованным
backup и остановленными writers либо явно проверенная совместимая перерегистрация.
Нельзя объявлять старые подписки переведёнными одним изменением environment.

## Runtime и секреты

| Материал | Где нужен | Права/условия |
| --- | --- | --- |
| Существующий `stand.env`, DB/Matrix/control/SMTP secrets | Только core | 0600; сохранить identity и все рабочие значения |
| `CONTROL_IMAGE`, `WEB_IMAGE` | Соответствующая роль | При выпуске требуются проверенные immutable digests; генератор не заменяет release manifest guard |
| `runtime/turn-secret` | Только edge configure | 0600, root; один секрет либо два на время ротации, по 64 lowercase hex chars на строку; один из них соответствует текущему Synapse `TURN_SECRET` |
| `turn-config/turnserver.conf` | Только coturn | Создаётся initialize шагом, UID/GID 10001, 0600; volume dir 0700 |
| `runtime/tls/web/web.crt`, `web.key` | Только Caddy | Ключ 0600 root, каталог доступен UID 0; сертификат покрывает canonical и edge hostname |
| `runtime/tls/turn/turn.crt`, `turn.key` | Только coturn | Alias на immutable pair; ключ 0640 root:10001, serving dirs 0750 root:10001; родитель runtime/tls 0700 root |
| `runtime/catalog/routes.json` | Caddy | Только подписанный публичный документ; 0644, каталог 0755 |
| Android/macOS update assets | Caddy | Публичные подписанные release assets; каталоги 0755, файлы 0644 |
| Catalog signing private key | Offline signer | Никогда не включать в edge bundle/runtime/CI logs |
| SSH/WireGuard private keys | Отдельные для каждого узла | Подготовка и отзыв — в bootstrap/replacement, пока не реализованы |

TURN REST-модель текущего Matrix API использует общий HMAC secret на A и входах,
а не отдельный секрет для каждого TURN URI. Компрометация одного edge требует
ротации этого секрета на A и всех оставшихся edge, помимо отзыва tunnel/SSH ключей.
Initializer принимает один или два различных секрета. На закреплённом coturn
проверены принятие старого/нового в период перекрытия, отказ старого после удаления
и отказ просроченного credential. Повторные `static-auth-secret` поддерживаются
[coturn 4.18.0](https://github.com/coturn/coturn/blob/4.18.0/src/apps/relay/mainrelay.c).

Порядок плановой ротации для будущего role deploy:

1. Подготовить новый секрет отдельно от логов/артефактов. На каждом входе по одному
   установить старый+новый, выполнить configure и пересоздать только TURN;
   проверить credentials обоих поколений до перехода к следующему входу.
2. Переключить A на выдачу с новым секретом. Сохранить старый на входах до истечения
   максимального TTL ранее выданных credentials (сейчас 1 час) и принятого clock-skew.
3. По одному удалить старый секрет, пересоздать TURN и проверить отказ старых
   credentials и работу новых. Повторное появление старого секрета при rollback
   должно блокироваться orchestration state, который ещё не реализован.

При компрометации старый секрет нельзя оставлять на час ради совместимости:
его отзывают с контролируемым прерыванием сессий, выдачей свежих credentials,
отзывом peer/deploy доступа и обновлением подписанного каталога. Автоматизация этого
порядка на нескольких хостах и восстановление реальных звонков при ротации пока
не проверены. Локальная проба пересоздаёт coturn, а не обещает hot reload без паузы.

При постепенной публикации topology клиент использует пересечение выданного A
TURN-списка и своего проверенного каталога. Новый D не ломает старый список B/C;
credentials не передаются неизвестным клиенту TURN names. Если пересечение пустое,
подключение медиа завершается ошибкой. Порядок публикации и удаления узлов ещё должен
быть закреплён в deploy; хотя бы один известный bootstrap endpoint нужно сохранить.

На edge root FS read-only, рабочие временные каталоги — ограниченный tmpfs;
Docker logs ротируются по 10 MiB × 3 на службу. Caddy не сохраняет config и
request/error request logs с URI/заголовками. Readiness даёт диагностику доступности
без содержимого запросов. Coturn оставляет ограниченные эксплуатационные логи
адресов/сессий, без включения verbose и без медиасодержимого. Это не обещание
отсутствия любой сетевой метаинформации на edge.

## Локальные проверки

```sh
PYTHONPATH=prototype:infra python3 -m unittest test_route_catalog test_role_config test_edge_config test_node_inventory test_topology test_three_vps test_route_health test_deployment test_supervisor
python3 prototype/check_role_config.py
python3 prototype/check_route_tls.py --role-bundle
python3 prototype/check_role_config.py --single-entry
python3 prototype/check_route_tls.py --role-bundle --single-entry
```

Последние две команды требуют локальный Docker. Они используют только случайные
project names, синтетические secrets/identity и одноразовую CA. Реальные `stand.env`,
тома и сертификаты не читаются. TLS trust ОС не меняется; наружу опубликован лишь
случайный loopback-порт. Стенды удаляются в `finally`.

Core-проба проверяет нормализованный Compose и два запуска configure с сохранением
предсуществующих signing/media sentinel files. Это не полный запуск нового core с
реальной базой и не rehearsal production migration. Edge-проба запускает сгенерированные
службы, а A имитирует небольшой HTTP fixture на private Docker bridge. Только
в fixture upstream заменяется на этот адрес; реальная маршрутизация через host
WireGuard данным тестом не проверяется. Это также избегает наблюдавшегося в локальном
Docker runtime непостоянного подключения второго network interface.
Проверены readiness/failure, atomic update подписанного каталога без restart и
отказ отката revision, CORS, private routes, forwarded/PROXY trust,
TLS CA/hostname, TURN allocation с временными credentials, ротация/истечение
credentials и отказы private peers.
Она не доказывает расшифрованный звук приложения, TURN TLS throughput, внешний 443,
WireGuard или certificate renewal. Протокол тестовой пробы следует
[STUN message integrity](https://www.rfc-editor.org/rfc/rfc8489.html#section-14.5)
и [TURN permissions](https://www.rfc-editor.org/rfc/rfc8656.html#section-10.2);
настройка логов — [Caddy global logging](https://caddyserver.com/docs/caddyfile/options#log).
