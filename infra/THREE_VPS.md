# Подготовка отдельных core/edge ролей

Текущий production — один физический A с отдельными core/edge-a после
[release51](../docs/iterations/three-vps-evidence/2026-10-29-production-initial-postcheck.json).
Ordinary managed/full53 выполнен и проверен. Build-only core54/web55 также
проверены по скачанным source artifacts и read-only postchecks production. Наличие команд ниже не означает выполненную физическую приёмку.
Текущая [точка продолжения](../docs/iterations/19-three-vps-resume.md) и единый
[реестр пользовательской приёмки](../docs/user-acceptance.md) имеют приоритет над
историческими отметками этапов ниже. Старый `deploy.py` не получает role bundles.

## Обычный managed release

GitHub Actions → **Build and deploy**, `rollout=managed`. Для первой миграции
legacy используется отдельный `rollout=initial`, а не ordinary full.

| `mode` | Сборка артефактов | Изменение приложений |
| --- | --- | --- |
| `full` | control + web | core и все входы, последовательно |
| `web` | web, deployed control digest повторно | web выбранных входов, `--no-deps`; core и остальные edge-процессы сохраняются |
| `edge` | web, deployed control digest повторно | полная роль выбранных входов |
| `core` | control, каждый deployed web digest сохраняется | только core; edge-процессы сохраняются |

`edges` — необязательные ID через пробел только для web/edge. Пустое значение
выбирает все существующие входы. Core/full требуют полной согласованной baseline.
Неизвестные ID, несовместимые contracts, смена DB engine и изменение конфигурации
за пределами scope отклоняются. Protected fingerprint не ослабляется ради web/edge.
Даже build-only частичный релиз читает baseline A для reuse digests.
`deploy=false` публикует артефакты и **не продолжает** pending release на VPS.
Server/client tests сохраняются во всех режимах. Core пропускает сборку web/crypto;
независимый Prototype checks по push/PR по-прежнему может собирать Android.

**Кандидат усиленного core guard (ещё не production):** общий `backend.sha256`
сохраняет прежний полный охват. Дополнительный `core-scope.sha256` исключает только
явно перечисленные core application files и Python test files. Shared/edge operator,
workflow, vendor и неизвестные пути остаются защищены. SHA проверяется с clean Git
до SSH и с exact metadata bytes на узле. Full сохраняет guard в baseline schema2;
историческая schema1 читается, но новый backend delta через core без guard отвергается.
При core-only backend delta guard должен совпасть с записанным; иначе нужен full.
Web/edge прежний backend guard не ослабляют. Совпадение generated edge bundle само
по себе недостаточно: operator scripts могут не входить в этот bundle.
Unit/source/journal checks прошли; перед новой production baseline нужна реальная
VM проверка full schema1→2, core delta, отказа shared operator delta и rollback.

Перед новым build/deploy возобновляется имеющийся journal из **его исходного
immutable source**, затем сверяются actual role state, host pins, boot receipts,
здоровье и data identity. На все участвующие хосты заранее доставляются публичные
исходники и скачиваются immutable образы. Только затем создаётся общий attempt,
по ролям берутся maintenance fences, core получает stopped-writer consistent
backup, роли применяются/проверяются и A атомарно сохраняет новый typed pointer.
Backend restart при core/full может прервать звонок; бесшовный rollout A не обещается.

Подтверждённая ошибка applying/verifying возвращает затронутые роли к exact previous
bundles и исходной private policy. Базы и пользовательские записи после snapshot
не восстанавливаются поверх текущих. Неопределённый результат SSH или busy сохраняет
attempt для retry; ошибка fencing также сохраняет его, поскольку peer мог ещё не
получить intent. После общего commit путь только вперёд. Owned backup/TLS/neighbor
manager delegates обновляются после release fences, их собственные journals
идемпотентны. Чужие службы, файлы и listeners не присваиваются.

### Доступы и команды оператора

`SERVER_ROLE_CONFIG` сохраняет существующие root/public/inventory/subnet;
`DEPLOY_ROOT=/srv/voicechat-managed`. Для одного A используется прежний
`DEPLOY_SSH_KEY`. Дополнительный secret **DEPLOY_NODE_SSH_KEYS** — JSON object:
ключи `edge-b`, `edge-c`, `edge-d`… и значения — соответствующие private SSH keys.
`core` можно задать этим же object для явной ротации. Каждый physical node получает
отдельный ключ; cohost edge-a использует core. Ключи пишутся только в приватный
каталог CI, не в archive/cache/runtime edge. Host keys берутся из inventory,
TOFU и agent forwarding отключены. Требуется root SSH на подготовленном Linux
host; установка OS packages не входит в ordinary release.

Локальный оператор может использовать ту же точку входа из clean checkout,
с готовым проверенным CI archive и окружением production:

```sh
# Только чтение metadata для выбора артефактов; это не runtime health proof:
python3 infra/managed_ssh.py --read-build-hints --scope full --output /tmp/reuse.json
# Реально продолжает прерванную операцию и может перезапускать её службы:
python3 infra/managed_ssh.py --resume-only
# Реальный scoped deploy, CI вызывает этот же entrypoint:
python3 infra/managed_ssh.py --scope web --edges a --archive /private/release.tar.gz
```

Для нескольких машин передать `--identity-map /private/identities.json`:
JSON `physical node ID → путь к его private key`. Для одного A достаточно
`--identity /private/core-key`; default — `~/.ssh/id_ed25519`. Требуются
`SERVER_ROLE_CONFIG`, `PUBLIC_URL`, `DEPLOY_ROOT`, при новом release — `GITHUB_SHA`.
После завершённого rollback новый attempt требует `retry_managed=true` в Actions
или `--retry` локально. Это не удаляет прежний журнал и не повторяет failed attempt
бесконечно. Никогда не править вручную fingerprint/current/previous/fence файлы,
не убивать Restic и не удалять locks ради продолжения.

Ordinary release не добавляет и не заменяет physical hosts, не меняет DNS,
постоянную Matrix identity, tunnel generation или signed catalog. Такие изменения
требуют отдельной подготовки/revocation, проверки нового входа и публикации нового
каталога. Клиенты24 уже поддерживают signed discovery без обновления приложения;
наличие одного A пока не даёт физической отказоустойчивости. Offsite backup и свой
DNS API остаются отдельными целевыми задачами, DuckDNS сохраняется.

## История подготовки компонентов

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

Профиль подготовки чистого хоста — Debian12 amd64. Host-local установка и reboot
проверены отдельно ниже; общий onboarding ещё открыт. Другие ОС/архитектуры
и текущий A требуют отдельной адаптации без переустановки. Порог свободного места
2 GiB совпадает с действующим deploy guard; рекомендации 4/2 GiB RAM и 20/10 GiB
свободного диска для core/edge выдаются предупреждениями. Они не оценивают размер
рабочих данных, snapshot и фактическую нагрузку. Отсутствующие Docker/WireGuard
отмечаются как зависимости для последующей установки, а не устанавливаются.

**Установка зависимостей, проверено 30.10:** `host_packages.py` выполняет host-local
шаг для чистого Debian12 amd64. Проверенный [VM proof](../docs/iterations/three-vps-evidence/2026-10-30-vm-host-packages.json)
включает настоящий apt, lost base/commit replies, repeat без apt/рестарта Docker,
reboot/autostart, сохранение SSH identity и посторонней nft-таблицы после base-фазы.
Это отдельный компонент; единый SSH onboarding/replacement ещё не завершён.

На выбранном новом хосте из проверенного source package, через SSH с заранее
проверенным host key:

```sh
python3 -B infra/host_packages.py --inventory inventory.json --node edge-d
python3 -B infra/host_packages.py --inventory inventory.json --node edge-d --execute
```

С рабочего компьютера тот же шаг доступен через проверенный SSH transport:

```sh
python3 -B infra/host_prepare.py --inventory inventory.next.json --node edge-d
python3 -B infra/host_prepare.py --inventory inventory.next.json --node edge-d \
  --identity "$SSH_IDENTITY" --commit "$SOURCE_COMMIT" --archive release.tar.gz \
  --execute --initialize-key
```

`release.tar.gz` — полный immutable source bundle из сборки согласованного commit;
локальный Git checkout должен быть чистым и соответствовать этому commit. Plan не
открывает SSH. Execute требует root SSH, точного pinned Ed25519 host key и owner-only
identity file. Исходники доставляются в `/var/lib/voicechat-host-source`; подготовка
не выбирает production release. При неопределённом результате SSH повторить тот же
вызов: package journal и tunnel identity сохраняются на новом узле.

Опциональный `--initialize-key` создаёт `/var/lib/voicechat-host/network.key` только
на новом узле. В ответе `tunnel_identity` содержатся service/node/generation и
публичный ключ; приватный ключ не передаётся. Утерянный committed private key не
регенерируется автоматически. Fresh apt + source delivery/repeat, создание ключа,
штатные SSH options через fixture NAT и сохранение ключа после reboot прошли
[VM проверку](../docs/iterations/three-vps-evidence/2026-10-30-vm-host-prepare-identity.json).
Это **не полное подключение входа**: peer/egress registration, role/TLS readiness,
DNS/catalog cutover и приёмка остаются следующими шагами.

`host_registration.registry(previous_inventory, inventory, previous_keys, identity)`
готовит новый публичный WG registry из `tunnel_identity`: один новый/заменённый
physical entry за операцию, core и остальные assignments/keys сохраняются.
Замена требует нового SSH host key, большего generation и нового tunnel key;
старый сервер для подготовки реестра не нужен. CLI `host_registration.py` принимает
bare identity JSON через `--node-identity`, оба inventory и прежний `--public-keys`;
`--output` создаётся только как новый файл. Реестр не применяется автоматически.

Начальная сеть нового узла оформлена отдельным `host_network.py`. Из проверенного
bundle на destination передать по stdin JSON с `schema=1`, `inventory`, `public_keys`,
`node`, `edge_subnet`. Модуль требует готовые dependency/identity receipts, читает
приватный ключ только локально, проверяет registry и отказывается менять другой
существующий intent либо хост с любыми контейнерами (включая stopped). Он применяет
существующий `network_runtime`, затем ставит штатный `network_bootstrap` boot gate.
Повтор допустим до установки ролей; исходный intent/key сохраняются при сбое.
Это не peer update на действующем A: для него нужен coordinated lifecycle.
На30.10 новый wrapper прошёл unit/fault checks и [настоящую VM проверку](../docs/iterations/three-vps-evidence/2026-10-30-vm-host-network-bootstrap.json):
apply/repeat без рестарта Docker, точные boot files, peerless WG identity; после
reboot сеть готова до Docker, ключ/receipt сохранены. Это не проверка внешних peers.

После получения публичного ключа нового узла и подготовки полного registry можно
выполнить единый SSH bootstrap (зависимости → прежний node-local key → initial network):

```sh
python3 -B infra/host_prepare.py --inventory inventory.next.json --node edge-d \
  --identity "$SSH_IDENTITY" --commit "$SOURCE_COMMIT" --archive release.tar.gz \
  --execute --public-keys tunnel-public-keys.next.json
```

`--public-keys` подразумевает проверку/инициализацию ключа; его фактический public
key должен уже совпадать с registry. При несовпадении сетевых команд не будет.
Для нестандартного bridge subnet передать существующий `--edge-subnet`.
Объединённый путь прошёл43 host unit checks и [настоящий SSH repeat](../docs/iterations/three-vps-evidence/2026-10-30-vm-unified-host-bootstrap.json)
на уже подготовленной peerless VM: dependency/key/network receipt совпадают, ключ
и точные boot files сохранены, Docker не перезапускался. Начальная установка и
reboot приведены в отдельных evidence выше; role/TLS/catalog deployment ещё открыт.

Первый вызов печатает профиль без изменений; второй требует root и сверяет
фактический SSH host key с inventory. Конкретный physical node `edge-d` должен
существовать в inventory; cohost использует `core`. Зависимости закреплены в коде:
Docker29.8.1, Compose5.5.1, containerd2.4.2, Debian версии OpenSSL/WireGuard/nftables.
Используется [официальный Docker apt repository](https://docs.docker.com/engine/install/debian/)
с отдельными `voicechat-docker.sources`/`voicechat-docker.asc` и проверкой SHA256 ключа.
Пакеты не устанавливаются convenience script. Buildx на хосте не нужен: роли получают
готовые immutable образы.

Private journal находится в `/var/lib/voicechat-host`; повтор должен использовать
тот же inventory, node и профиль. Установщик не принимает чужой Docker/containerd,
Docker repository, незавершённый dpkg или появившиеся container data. Активную
`nftables.service` он сохраняет через отказ: её нужно адаптировать отдельно, без
автоматического stop/restart/flush. Возобновление dpkg ограничено записанным apt
closure. При изменении установленного профиля требуется отдельный проверенный
upgrade. Глобальные apt/dpkg locks не удаляются. Завершённый повтор сверяет версии
и rootful Docker, сохраняя запущенные службы. Этот шаг не создаёт WireGuard keys,
role data, registry credentials, DNS или TLS; далее нужны соответствующие этапы
bootstrap. Существующий production A через этот clean-host installer не обновляется.


Проверка намеренно предназначена для **чистого** хоста: занятый собственным старым
релизом порт также блокируется. Она не останавливает службы и не является режимом
миграции или повторного deploy. Provider firewall, доступность снаружи, DNS/TLS и
поддержка WireGuard ядром требуют отдельных проверок. Шесть unit-тестов прошли;
настоящий isolated Linux collector обнаружил UDP socket и route, а отсутствие
systemd/NTP/SSH host identity оставил ошибками. Сам collector не заменяет полный
bootstrap/role acceptance; package VM proof выше имеет отдельный ограниченный охват.

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
Docker host. Host-local установка пакетов проверена выше; общий SSH bootstrap ещё не завершён.

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
Runtime-каталог должен существовать по каноническому пути, принадлежать deploy
owner и запрещать запись другим пользователям. На macOS `/tmp` — alias;
используйте соответствующий `/private/tmp` либо заранее разрешённый `Path.resolve()`.
Publisher отвергает symlink/FIFO вместо каталога, lock или прежнего документа;
lock остаётся owner-only, публичный `routes.json` имеет 0644.

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

### Миграция существующих pushers при core rollout

`push_route_migration.py` — внутренний транзакционный шаг core maintenance,
включённый в core bundle. Он заменяет только точный canonical callback URL у
`dev.voicechat.web` HTTP pushers, сохраняя ID, pushkey, позицию обработки и остальные
поля. Приватный journal хранит ID и прежний/новый JSON data; это не backup.
Intent сохраняется до UPDATE, поэтому повтор после обрыва между PostgreSQL commit
и записью receipt завершает ту же операцию. Откат не создаёт удалённые подписки и
отказывается перезаписывать независимо изменённые записи; конфликт откатывает всю
транзакцию. Ожидание lock ограничено 5 секундами, SQL — 30 секундами.

Обязательные условия вызывающего core deploy: общий lock, остановленные Synapse и
control writers, проверенный согласованный backup и restart Synapse после commit
для сброса его pusher cache. Пока этот шаг **не подключён** к production rollout;
standalone CLI намеренно отсутствует. Журнал ограничен общим лимитом managed state
64 KiB: превышение останавливает миграцию до изменений БД, требуется отдельный
план для большего набора подписок. PostgreSQL probe:
`prototype/check_push_route_migration.py`, только disposable база с префиксом
`voicechat_push_migration_fixture_`, libpq `PG*` environment и psycopg2 из pinned
Synapse image. Это проверка транзакций на синтетической таблице, не приёмка полной
миграции настоящей Synapse БД.

### Согласованный backup core

Внутренний `deploy.backup(root, release, env, core=True)` переиспользует существующий
Restic pipeline и pg_dump. Сохраняются тома synapse/control/media-config/turn-config,
stand.env, immutable release и state.json роли; пароль Restic остаётся вне snapshot.
Core Compose не принимает legacy override. Исходный backup без `core=True` сохраняет
прежний состав и current.json. Это не добавляет production CLI scope `core` или
`backend`: orchestration с остановкой writers, backup, миграцией и rollback ещё нужен.

`prototype/check_core_backup.py` поднимает только изолированные fixtures, создаёт
копию, выполняет check и restore, проверяет синтетические identity/media/SQLite,
state/runtime, отсутствие backup key в snapshot и читаемость pg_dump. Затем удаляет
свои контейнеры, сеть и тома. Проверка выполнена в Debian VM; результат:
`docs/iterations/three-vps-evidence/2026-10-28-vm-core-backup.json`.
Полный запуск восстановленного приложения отдельно ещё не принят.

Core bundle берёт неизменённые определения четырёх служб из canonical compose.yaml,
но исключает web/turn/mailpit перед наследованием: Compose интерполирует даже
неиспользуемые service blocks. Поэтому WEB_IMAGE/SITE/web-порты на core не нужны.
Renderer проверяет ожидаемую структуру исходного файла, а реальный Compose probe
проверяет итоговое наследование и повторную инициализацию.

### Подготовленный core и восстановление роли

После `role_prepare.py`, подготовки приватного runtime и применения network intent
установить per-role systemd operator из того же проверенного набора исходников:

```sh
python3 -B infra/role_bootstrap.py --root /srv/voicechat-core --role core
python3 -B infra/core_deploy.py --root /srv/voicechat-core \
  --topology topology.json --inventory inventory.json --manifest core-release.json
# Для уже подготовленного edge:
python3 -B infra/role_bootstrap.py --root /srv/voicechat-edge-a --role edge --edge a
```

Это команды для управляемого fixture/нового хоста, не миграция существующего VPS.
Core controller отказывается присваивать неизвестные volumes, containers и network.
Для существующего production с данными нужен отдельный согласованный adoption/full
controller. Пароли БД и физическая идентичность не меняются обычным core deploy;
смена PostgreSQL/Synapse image требует отдельной процедуры совместимости.

Core journal `state.json` хранит current/previous/pending, runtime hash, PostgreSQL
system identifier и hash Matrix signing key. Фазы: prepared → stopping → backed-up
→ applying; rollback остаётся pending до успешного восстановления прежнего кода,
policy, health и data identity. Образы скачиваются до maintenance. После остановки
Synapse/control создаётся проверенная копия; данные не восстанавливаются поверх
новых записей при откате кода. Прерванный apply завершается только тем же target.
Неизвестные/пропавшие volumes не должны приводить к созданию пустой БД. Metadata
probes используют read-only mounts без сети и без запуска PostgreSQL entrypoint.

У управляемых core/edge контейнеров Docker restart policy — `no`. За восстановление
отвечают `voicechat-core.service`/`voicechat-edge-ID.service`: Type=notify,
Restart=on-failure, Requires/After network и Docker, PartOf Docker. Monitor запускает
только committed роль после проверки источников/identity и следит за её контейнерами.
Maintenance с unsafe pending не возобновляется автоматически; повторить controller
с тем же target. Контроллер активирует monitor после освобождения locks. При
штатной остановке monitor останавливает только свою роль; pending maintenance
остаётся под управлением controller. Установка operator обновляет immutable source
package и unit, включает unit, но сама не перезапускает Docker или приложения.

На хосте с соседними приложениями после миграции VoiceChat restart policies и
установки owned boot gates можно использовать:

```sh
python3 -B infra/network_bootstrap.py --upgrade --shared-host
```

Тогда Docker использует Wants/After VoiceChat network: отказ этой сети блокирует
VoiceChat per-role units, сохраняя запуск посторонних workloads. Режим сохраняется
при последующих source upgrades. Guard отказывает, если обнаружит управляемые
контейнеры с autorestart или без boot gates. Применять на прежний production до
подготовленной миграции нельзя. Dedicated clean host сохраняет строгую зависимость
Docker Requires; вариант с `on-failure` для контейнеров отклонён реальным negative
reboot-тестом и заменён на `no`.

Control supervisor даёт 30s до первой готовности, затем сохраняет 5s cutoff при
потере health; умерший дочерний процесс завершает общий lifecycle сразу. Docker
healthcheck имеет соответствующий start_period=30s. Реальные core lifecycle,
negative network reboot, systemd crash recovery, Docker restart и cold reboot
нового control image с NRestarts=0 прошли в disposable VM с прежним synthetic
account/device/data identity. См. [core lifecycle](../docs/iterations/three-vps-evidence/2026-10-28-vm-core-monitor-rollout.json)
и [role boot](../docs/iterations/three-vps-evidence/2026-10-28-vm-core-role-boot.json).
Это не production adoption или приёмка медиапотоков.

### Общий TLS-вход на совмещённом VPS

`shared-node-inventory.example.json` добавляет co-located edge профиль `shared_tls`:
отдельная private /29, имя bridge и точные адреса прежнего Caddy/shared-front.
Renderer создаёт дополнительно `compose.shared-front.json`; edge не содержит
собственного ingress и использует persistent external bridge shared-front.
Shared-front имеет Docker restart unless-stopped и не зависит от VoiceChat network;
он хранит только SNI routes и не монтирует TLS/TURN credentials или данные.
Dedicated edge без профиля сохраняет собственный ingress.

Полный rollout обязан отдельно владеть shared-front и его сетями. Web-only не
меняет эти файлы; edge stop/down не должен удалять listener или соседний сайт.
Прежний Caddy требует точного PROXY v2 trust и strict SNI/Host, сохранения HTTP-01
и сертификатов. Перенос порта 443 в общий front ещё не реализован; первоначальный
перенос прежнего Caddy на управляемый directory mount проверен отдельно ниже.
Один offline bundle не разрешает занимать порт 443.
Изолированный `prototype/check_shared_front.py` проверяет маршрутизацию на HAProxy
и публичном Caddy 2.8; это синтетические TLS endpoints, без TURN allocation/media.
`edge_config.shared_legacy_proxy` генерирует следующий Caddy config из reviewed
business routes: точный PROXY trust, strict SNI и VoiceChat certificate sinks с
отключённым TLS-ALPN challenge. Это оставляет HTTP-01 на прежнем порту 80; config
прошёл stock Caddy 2.8 validate без сети. Реальный выпуск/renewal и доставка этих
сертификатов в edge пока не приняты.

`shared_ingress.stage(...)` подготавливает immutable candidate config/override и
reviewed source package без runtime activation. `compose_override` использует
Compose !override для портов и volumes: иначе прежний leaf mount может закрыть
новый Caddyfile в каталоге, а прежний 443 конфликтует с shared-front. Имена Caddy
volumes и определения остальных сервисов проверены через настоящий Compose 5.5.1.
`inspect_legacy_plan(...)` сверяет host key, private plan/operator package,
Git main/HEAD/dirty paths, Compose dotenv и активную Caddy-конфигурацию. Pinned
image, ports, networks, volumes и mounts должны совпадать; неизвестные изменения
не принимаются. В результат входят только hashes/IDs, dotenv не выводится.

`adopt_legacy(...)` выполняет только начальный переход на directory mount:
сохраняет private server-local `.env` snapshot, добавляет canonical `COMPOSE_FILE`
и запускает только `up --no-deps --no-build --pull never caddy`. Runtime overlay
находится вне соседнего Git. До/после проверяются HTTPS обоих сайтов с доверенным
CA и неизменность процессов соседей. При сбое старый leaf mount и dotenv bytes
восстанавливаются с явным прежним image pin. Process death оставляет durable
pending: следующий вызов сначала восстанавливает прежний ingress и требует
повторить adoption. Нельзя изменять `current.json`/`pending.json`, чтобы обойти
guard. Эти операции прошли [реальную VM проверку](../docs/iterations/three-vps-evidence/2026-10-29-vm-shared-legacy-adopt.json)
с синтетическими upstreams и internal CA; production ещё не переведён.

Следующий слой — `shared_update.install(...)` и установленная команда
`/usr/local/sbin/voicechat-shared-deploy avito-update`. Hook соседнего workflow
подключать только после её проверки и успешного adoption. Команда использует
тот же global lock, проверяет origin/рабочие изменения, fetch + fast-forward
конкретной revision и сохраняет overlay. Она восстанавливает только известный
custom `deploy/Caddyfile` перед merge, без глобального checkout/reset. Перед
checkout Compose и Caddy validate проверяют candidate; ingress identity/ports/
mounts/environment остаются защищёнными. Workflow/docs-only update не запускает
application pull/up и не reload Caddy. Business Caddy routes reload без restart;
прочие business changes идут через обычные pull/up с управляемым override.
Application schema/data не откатываются этим контроллером. При ошибке target
остаётся pending для повторения той же revision; не делается новый fetch поверх
незавершённого deploy. Ошибка reload возвращает известные routes, сохраняя pending.
Wrapper запускает sealed Python package с `-B`, чтобы не писать `__pycache__` в
проверяемый неизменяемый каталог. [Реальная CLI проверка в VM](../docs/iterations/three-vps-evidence/2026-10-29-vm-shared-business-update.json)
подтвердила workflow-only, Caddy reload, process-death recovery после Git merge
и сохранение HTTPS/процессов/окружения. [Расширенный повтор](../docs/iterations/three-vps-evidence/2026-10-29-vm-shared-business-update-full.json)
проверил lost reload response recovery и настоящий public-image pull/application
up с health wait: изменился только frontend после его config change. Прикладная
schema migration и shared port cutover этим fixture не проверялись.

### Подготовка сертификатов совмещённого A

Для начального cohost с `edge.origin == canonical_origin` есть plan mode
`legacy-certs`: прежний VoiceChat upstream сохраняется, добавляется TURN HTTPS
certificate sink с ответом 421. У обоих VoiceChat имён выключен TLS-ALPN challenge;
HTTP-01 остаётся на Caddy port80, который сохранится после общего SNI cutover.
Поэтому для текущего A не требуется DuckDNS API token или предварительная смена
DNS, если оба имени уже разрешаются на него. Для других схем/SAN на dedicated
входах остаётся отдельный DNS-01 issuer path; не считать его настроенным без token.
Основание: [Caddy Automatic HTTPS](https://caddyserver.com/docs/automatic-https),
[TLS challenge options](https://caddyserver.com/docs/caddyfile/directives/tls).

Сначала `shared_update.install(...)` обновляет code ownership и wrapper: это
разрешено только при byte-identical результате renderer и не reload службы.
Между pointer/wrapper/receipt replacements несовпадающий прежний CLI отказывает
до Git fetch; повтор install завершает прерванное обновление. Исторические sealed
packages сохраняются. [Настоящая VM проба 27 → 28](../docs/iterations/three-vps-evidence/2026-10-29-vm-shared-manager-source-upgrade.json)
использовала фактический прежний production package, сохранила все процессы и
повторила installed CLI/application deploy/recovery после upgrade.

`shared_config.prepare_certificates(root, plan)` держит тот же lock, требует новый
проверенный manager, делает Caddy validate без сети и reload только известного
config. Durable `configuration.json` блокирует business update/adoption.
Source/host/env/ports/mounts остаются неизменными. Успех требует HTTPS обоих прежних
сайтов, настоящих trusted TLS handshakes canonical + TURN и тех же процессов всех
контейнеров. ACME readiness ограничена 180s; hostname/CA проверки не отключаются.
Ошибка возвращает прежние routes, interrupted apply продолжает тот же plan,
interrupted rollback сначала возвращает рабочий старый config. Это ещё не перенос
443 в HAProxy и не доставка ключей в edge. [Stock Caddy 2.8 parser proof](../docs/iterations/three-vps-evidence/2026-10-29-vm-cohost-certificates-parser.json)
прошёл без сети. [Настоящий production HTTP-01 выпуск](../docs/iterations/three-vps-evidence/2026-10-29-production-cohost-certificates.json)
29 октября прошёл на текущем A: trusted SNI обоих имён, прежний canonical cert,
те же container processes, внешний TURN TLS verify=0/HTTP421. Последний статус
означает только готовый certificate sink; TURN/TLS relay443 ещё не включён.
Доставка ключей в edge и автоматический activation/renewal ещё остаются.

Для начальной миграции старого A можно явно добавить `legacy_turn: true` к
`{"id":"a","host":"core"}`: host3488 TCP/UDP направляется на авторизованный
listener3478. Флаг отсутствует по умолчанию и запрещён для dedicated edge. Он
нужен при сохранении старых client TURN URI с TTL1h; shared secret при переносе
должен совпадать с прежним. Удалять aliases можно после принятого перехода и
истечения кешей, отдельным edge scope. Unit и coturn fixture прошли, но настоящий
production host3488 и пользовательские звонки этим ещё не приняты.

### Согласованный перенос public443

`shared_front.prepare` копирует frontend из проверенного edge bundle в отдельный
owned plan. `warm` запускает только loopback19443 и переиспользует cached immutable
image. Соседний Caddy и приложения этим шагом не меняются. Отдельный sealed
`compose.public.json` добавляет public443, сохраняя loopback для TLS renewal.

`shared_cutover.activate` принимает подготовленные ingress/frontend plans и
committed edge. Под общими ingress/front/edge/TLS locks проверяются source/host,
environment, mounts, volumes, ports, bridge addresses и active Caddy JSON.
Private `configuration.json` фиксирует фазы caddy/front/verify/rollback. После
trusted warm TLS/API проверки Caddy получает только port80 и strict PROXY listener,
HAProxy получает443. Указатель commit записывается после public edge и business
HTTPS проверок. Ошибка сначала возвращает HAProxy на loopback, затем восстанавливает
Caddy443. Неизвестные внешние правки сохраняются, журнал остаётся для диагностики.

Компонент подключается к полному координатору после готовности core/edge; перенос
legacy данных, общий rollback и production workflow интегрируются отдельно.
Настоящий port cutover/resume/rollback и manager no-op после перехода прошли на
marked disposable VM: [evidence](../docs/iterations/three-vps-evidence/2026-10-29-vm-shared-port-cutover.json).
Проба использует synthetic API/TURN TLS и не подтверждает media/core DB/reboot.

Для общего перехода координатор удерживает ingress lock от начала core maintenance
до проверки HTTPS и вызывает внутренний `shared_cutover._activate_locked`.
Самостоятельный `activate` берёт этот lock сам; параллельный business deploy
отказывает до изменений. Порядок child locks остаётся front → edge → TLS.

### Backup уже управляемого core

`core_deploy.py --root <core-root> --topology <public.json> --inventory <inventory.json>
--backup-only` делает согласованный локальный encrypted backup текущего core.
`--manifest` и `--backup-only` взаимоисключающие. Сначала проверяются immutable
bundle, runtime digest, data identity, boot/network ownership и готовность служб;
Restic скачивается до остановки writers. Core/network locks удерживаются до конца.

Private `runtime/backup.json` фиксирует stopping/resuming и результат snapshot.
Останавливаются только Synapse/control, PostgreSQL остаётся для pg_dump. Существующий
backup сохраняет database/media/control/runtime и проверяет Restic repository.
После snapshot возвращаются только postgres/synapse/control текущего release с
`--no-deps`; configure, смена policy и current/previous pointers не выполняются.
Ошибка snapshot возвращает доступность и сообщает ошибку. Неудачный запуск или
прерывание оставляют journal; boot/deploy отказывают до продолжения той же операции.
Прерванный незавершённый snapshot повторяется, завершённый — только возобновляет
writers. Замена data identity запрещает автоматический запуск.

Это операция backup; установка нового timer и согласованное отключение прежнего
`voicechat-backup.timer` входят в legacy-to-core migration. На production старый
timer пока сохранён. Данные и Restic password остаются на A; независимое offsite
хранилище и восстановление после потери A по-прежнему целевая задача.

`core_backup_bootstrap.py --root <core-root> --topology <public.json> --inventory
<inventory.json>` устанавливает отдельные `voicechat-core-backup.service/.timer`
после commit общего перехода и проверки public HTTPS. Требует committed core,
актуальный sealed boot operator, неизменный runtime и неактивные прежние
`voicechat-backup.timer/.service`. Старые units этим installer не изменяются.

Собственные unit/config files проверяются по private receipt; прерванная установка
продолжает только тот же target, неизвестные правки не перезаписываются. Timer
ежедневный, 03:30 UTC, Persistent; пропущенный запуск может начаться после enable,
поэтому запускать installer посреди full migration нельзя. Service выполняет
только новый `core_deploy --backup-only`, повторяет процесс при ошибке с ограничением
частоты и не зависит от состояния notify monitor, который выходит при maintenance.
После reboot с оставшимся backup journal оператор явно запускает этот service
для завершения recovery; до этого core boot остаётся закрыт. Это fail-closed
поведение сохраняет данные, но требует вмешательства при прерывании питания.

Backup из sealed operator не требует repository checkout: записанные файлы
committed release перепроверяются по принятому manifest, переданные topology/node
должны совпасть с его fingerprints. Это не проверка нового candidate; deploy и
prepare сохраняют полную реконструкцию ожидаемых source/config files. Монитор
core распознаёт backup journal и выходит штатно при остановке writers, не создавая
systemd restart loop; после recovery оператор запускает его снова.

### Откат первой peerless сети при legacy adoption

`network_bootstrap.py --retire-initial <fingerprint>` предназначен только для
возврата первой одноузловой установки: physical nodes строго core без удалённых
peers, exact source/intent fingerprint и SSH host identity, все core/edge containers
удалены, role monitors остановлены. Проверяются собственные unit/source files,
child intents, nft owner и live WG key; неизвестные изменения сохраняются.
Если Docker через Requires/BindsTo зависит от этой сети, операция запрещена.

Private `boot-install/initial-rollback.json` фиксирует retiring/retired/restoring.
Удаляются только собственные WG interface, nft table и systemd unit/drop-in;
Docker, соседние службы, data volumes, private intent/key и source cache сохраняются.
Interrupted retirement сначала завершается тем же вызовом. Обычные network resume,
source upgrade и role deploy блокируются. `--restore-initial <тот же fingerprint>`
восстанавливает только тот же peerless intent и снимает fence после completed
network receipt. Нормальные replacement/revocation этим путём не откатываются.
Обе операции исполняются из того же frozen deployment artifact с canonical network
service templates; boot-only source cache не заменяет полный deployment artifact.

Реальный kernel/systemd proof прошёл на marked VM: потеря ответа после удаления
WG и после network start, same-intent resume, неизменные key/private intent,
Docker PID, neighbor container/HTTP и чужие nft tables.
[Evidence](../docs/iterations/three-vps-evidence/2026-10-29-vm-initial-network-rollback.json).
Это компонент полного rollback; сам production legacy adoption ещё не выполнен.


### Read-only preflight и push SQL bridge для первоначального core adoption

`legacy_core.inspect(root)` берёт существующий `deploy.lock`, не меняет pointer,
Compose, конфигурацию или контейнеры. Он сверяет immutable legacy manifest и
recorded backend/config baseline, ровно шесть служб, семь именованных томов,
image IDs, mount permissions, capabilities, restart policy, tmpfs, ports и сети.
Неизвестные данные и контейнеры нельзя автоматически принять или удалить.
`require_running=False` допускает остановленные writers при продолжении maintenance;
PostgreSQL всё равно должен быть healthy. Результат содержит только fingerprints,
идентичность данных и публичную метаинформацию, без runtime credentials.
`require_compatible` запрещает менять Matrix/public identity и версии PG/Synapse
во время adoption; upgrade engines требует отдельной процедуры.

Закреплённый coturn image дополнительно создаёт anonymous `/var/lib/coturn`.
Он допускается только с точным Docker image declaration, local anonymous label,
проверенными mount/permissions и исходным 64-символьным volume ID. При возврате
legacy после `down` **без `--volumes`** временный extra Compose из
`legacy_core.rollback_override` подключает именно этот external volume. Исходные
Compose, current.json и backend fingerprint при этом не переписываются.

`core_deploy.migrate_push_routes` — maintenance bridge, не самостоятельный full
deploy. Вызывать под общим migration lock и legacy deploy.lock после остановки
Synapse/control и проверенного backup. Он дополнительно берёт core lock, проверяет
prepared source/config, runtime hash, точный healthy PG image/data mount/network,
останавливает работу при active writers и сверяет PG/Matrix identity до/после SQL.
Reader UID991 без сети читает только свою private generated homeserver config;
он не получает доступ к root-private operator tree. PG password передаётся SQL
контейнеру через stdin, не argv/env, public logs или файлы. Остальные master secrets
не читаются. Driver использует проверенный pinned Synapse image и существующий
URL-only primitive. После SQL Synapse должен быть перезапущен вызывающей стороной.

Forward и reverse используют отдельные private journals в
`runtime/adoption-push/<attempt>/`. Повтор той же interrupted операции сохраняет
attempt; новая попытка после завершённого rollback обязана получить новый случайный
attempt. Reverse обрабатывает **актуальные** pushers и сохраняет новые metadata и
подписки; старый database snapshot поверх пользовательских записей не восстанавливается.
Общий core/edge coordinator и production adoption пока не подключены.


[Реальный VM proof](../docs/iterations/three-vps-evidence/2026-10-29-vm-legacy-core-preflight.json)
проверил этот bridge на настоящей Synapse/PostgreSQL с синтетическим аккаунтом:
backup/check, отказ от foreign DB/active writer, forward/resume и current-row reverse,
recreate legacy с теми же account/device/PG/signing/coturn identities и subsequent
обычный legacy up. Все fixture volumes/containers/network удалены. Это current-source
synthetic legacy baseline, а не применение к production release или full transition.


### Fence прежнего backup scheduler во время adoption

`legacy_backup.retire(attempt_directory, legacy_root)` вызывается под общим migration
и старым deploy.lock. Он принимает только штатные service/timer файлы для этого root
с User=root либо voicechat, без чужих drop-ins. Private durable receipt сохраняет
исходные enabled/active flags. Owned `ConditionPathExists=!<receipt>` drop-in запрещает
новые старты старого backup, затем timer отключается. Уже начавшийся backup не
завершается принудительно: операция оставляет fence и требует отпустить deploy.lock,
дождаться штатного завершения и повторить её до любого изменения data services.

`restore` вызывается после готовности восстановленных legacy служб. Он удаляет
только свой drop-in, возвращает исходное enabled/active состояние timer и продолжает
потерянный ответ systemctl по тому же receipt. После завершённого rollback новая
попытка adoption использует новый attempt directory. Исходные units не переписываются,
Docker и приложения этим helper не рестартуются. Сам helper ещё не заменяет общий
full coordinator. [Реальный systemd VM proof](../docs/iterations/three-vps-evidence/2026-10-29-vm-legacy-backup-fence.json)
подтвердил отказ от исполнения backup по condition, repeat и restore после потерянного
ответа запуска timer. Гонка с in-flight backup проверена отдельным unit test;
настоящий backup в этом proof не прерывался и не имитируется как проверенный случай.


### Co-host TLS refresh и owned scheduler

`cohost_tls.py --root <shared-root>` сохраняет прежний capture-only режим.
`--refresh` требует committed edge и свой frontend: current ingress mode должен
совпасть с running/public phase frontend, а его plan, image, bind mounts, networks
и loopback binding проверяются до активации. Lock order: ingress → front → edge →
TLS writer каждого сервиса. Full caller может переиспользовать уже удерживаемый
ingress lock через `_refresh_locked` / `_capture_locked`.

Обе пары проверяются на `127.0.0.1:<owned warm port>` с точным доверенным leaf,
SNI и hostname. Public443 перед takeover отвечает старым Caddy, поэтому он не
доказывает активацию edge. Cache/key bytes остаются на A. Перезапуск контейнера
считается ошибкой; pending activation receipt допускает повтор, неизменные пары
проверяются без новых сигналов. Web и TURN имеют независимые TLS receipts: успех
одного сервиса не выдаётся за успех обоих, сбой требует повторить весь refresh.

Docker сохраняет lexical Source bind mount из `<release>/infra/runtime`, хотя
prepared release направляет runtime symlink на постоянный каталог. TLS activation
теперь сравнивает его разрешённый путь с точным canonical service directory.
Чужой target, read-write mount, image/role mismatch по-прежнему запрещены.

`cohost_tls_bootstrap.py --root <shared-root>` устанавливает owned timer только
после committed shared public ingress, при committed edge без pending deploy и
из текущего reviewed sealed operator. Первая проверка через5min после активации
timer, последующие каждые15min с jitter до60s. Он использует существующий Caddy
HTTP-01 issuer и вызывает `cohost_tls.py --refresh`; DNS credentials не нужны.
Private install journal продолжает тот же target после сбоя; неизвестные units
не заменяются. Этот installer запускается из полного deployment artifact; runtime
service использует уже установленный immutable operator package.

Локальные guards и crash-resume проверены unit tests.
[Сквозной VM proof PASS](../docs/iterations/three-vps-evidence/2026-10-29-vm-cohost-refresh.json):
настоящие Caddy/coturn из prepared edge Compose, rotation, потеря ответа reload,
повтор без сигналов для неизменных пар, возврат прежнего trusted leaf и сохранение
процессов. Установленный sealed systemd service тоже выполнился успешно; временная
fixture CA и ресурсы удалены. ACME storage был синтетическим, core и реальные
аккаунты/медиапотоки не запускались. Это не production renewal и не выпуск клиентов.


### Общий maintenance fence initial/full transaction

Private `runtime/full-rollout.json` привязывает staged роль к canonical root,
role owner, случайному attempt и SHA конкретного target manifest. Пока он есть,
обычные deploy/backup/boot/push SQL/periodic TLS refresh запрещены. Full caller
передаёт свой attempt только для точного target. Runtime monitor при известном
maintenance не запускает/не останавливает приложения; перезапуск после child commit
не разрешён до завершения общего coordinator. Снятие fence не подменяет public
readiness или проверку общего commit.

`legacy_core.fence_restart` нужен до остановки writers и backup: старые контейнеры
не должны возобновить запись при reboot незавершённой adoption. Меняется только
restart policy captured IDs, без recreate. Потеря ответа/частичный update повторяются
по точному source/runtime/data baseline. `fencing` принимает только прежнюю/no policy,
`fenced` — только no; оба являются явными read-only recovery profiles. Обычный
preflight сохраняет strict policy/healthy PG contract. Запуск PG перед SQL проверяется
отдельно; разрешение metadata probe остановленной PG не означает её готовность.

[Реальный VM proof](../docs/iterations/three-vps-evidence/2026-10-29-vm-legacy-rollout-fence.json)
прошёл update/lost reply/resume без смены процессов, stopped PG metadata, actual
Type=notify maintenance success/NRestarts=0, nonce-owned SQL и legacy recreation
с прежними account/device/PG/signing/coturn identity. Это отдельные компоненты,
общий production full coordinator ещё не подключён.

### Общий первоначальный legacy → core/cohost переход

`initial_cohost.py` объединяет компоненты для одного data host и его canonical
cohost edge с `legacy_turn` и `shared_tls`. Обычный полный сценарий прошёл на
marked VM с точными исходниками legacy 8bcbd91, синтетическими account/CA/catalog
key: [evidence](../docs/iterations/three-vps-evidence/2026-10-29-vm-initial-cohost.json).
Account/device/account data, PG/signing identity и legacy pointer сохранились.
Failure drills ещё выполняются; workflow и production переход не завершены.

Контракт будущего CI entry point (не обход действующего routed-deploy gate):

```sh
python3 -B infra/initial_cohost.py \
  --root /srv/voicechat-managed --legacy-root /srv/voicechat \
  --shared-root /var/lib/voicechat-shared-ingress \
  --topology /private/topology.json --inventory /private/inventory.json \
  --candidate release.json --backend-file backend.sha256 \
  --catalog /private/routes.json --catalog-key-file /private/catalog-public.txt
```

`catalog-public.txt` содержит одну base64 строку публичного Ed25519 key, как
`CLIENT_ROUTE_CATALOG_KEY`, а не PEM и не приватный signing key. Подписанный
каталог выпускается offline; приватный ключ не нужен и не передаётся VPS.
Runtime/data остаются на A; edge получает TURN secret и публичные артефакты.
Копирование архива обновления заранее проверяет запас 2 GiB для рабочей БД.

В private `initial.json` сохраняются exact target/source hashes, nonce и фаза.
Обычный повтор продолжает тот же frozen artifact; `--retry` разрешён только после
завершённого rollback и создаёт новый nonce. Legacy labels могут сохранять путь
к recovery override предыдущей попытки: принимается только её owned private файл,
равный override с прежним anonymous TURN volume. Чужие `-f` не принимаются.
Boot/scheduler slots и shared-front ownership проверяются до остановки writers;
boot units устанавливаются после network unit, до запуска нового core.

До public commit ошибка восстанавливает legacy и прежний timer без восстановления
старой БД поверх свежих записей. После фактического public commit выполняется
только forward recovery. При прерывании процесса/reboot посреди full fence нужен
повтор того же frozen entry point: незавершённую миграцию boot monitor не обходит.
Новый revision после завершённой adoption требует обычного managed rollout;
initial controller не выдаётся за реализацию всех scopes.

### Immutable доставка CI исходников

`release_delivery.py` — standalone stdlib receiver для private SSH stdin. Он
проверяет SHA256 архива и candidate commit до записи, ограничивает gzip/tar,
отвергает traversal, ссылки, runtime и неизвестные вложенные пути. Допустимы flat
`infra/*`, четыре policy-файла `prototype`, `release.json` и `backend.sha256`.
Получатель атомарно публикует `/ROOT/bundles/ARCHIVE_SHA256`; повтор сверяет весь
file set и содержимое, не перезаписывает неизвестный или изменённый каталог.

```sh
python3 -B /private/bootstrap/release_delivery.py --root /srv/voicechat-managed \
  --sha256 "$ARCHIVE_SHA256" --commit "$GITHUB_SHA" < /private/release.tar.gz
```

Bootstrap копируется через pinned SSH в отдельный private temporary directory;
receiver не требует ещё не установленных модулей проекта. Он не запускает службы,
не копирует runtime/credentials и не меняет current pointers. Build source-proof
по-прежнему обязан выполнить CI через `release_source.py` на clean checkout;
receiver не заменяет этот guard формально корректной строкой fingerprint.
[Linux stdin/repeat proof](../docs/iterations/three-vps-evidence/2026-10-29-vm-source-delivery.json),
7 negative/idempotence unit tests прошли; интеграция в release workflow впереди.

SSH source transport: `ssh_deploy.py receive` проверяет точные bytes архива по чистому
Git commit и backend fingerprint до обращения к хосту. Пinned host key обязателен;
bootstrap берётся из проверенного архива, передаётся stdin и удаляется после приёма.
`--output` создаёт новый private receipt, не перезаписывает существующий файл.
Проверки: 5 unit и Linux VM SSH/repeat (86 public files); workflow ещё не подключён.

### CI: первоначальный переход одного физического A

`Build and deploy`: `rollout=initial`, `mode=full`. При `deploy=false` только
сборка; при `deploy=true` обязательны проверенные environment variables:

- `SERVER_ROLE_CONFIG`: JSON с `schema=1`, `root`, `legacy_root`, `shared_root`,
  `public` (topology), `inventory`, `subnet`. Для первого перехода — ровно один
  canonical cohost edge с `legacy_turn=true` и shared TLS profile.
- `SIGNED_ROUTE_CATALOG`: публичный envelope от offline Ed25519 signer для
  точного `public`; `CLIENT_ROUTE_CATALOG_KEY` — существующий raw public key.
- `PUBLIC_URL`, `DEPLOY_HOST/USER/ROOT` и существующие pinned SSH secrets.

`initial_entry.py --check-environment` проверяет контракт до сборки. SSH transport
сверяет clean Git/archive/backend fingerprint, получает immutable source bundle
и вызывает entry point из него. JSON передаётся stdin; секреты runtime, registry
и private signing key не входят в этот контракт. На A ещё раз проверяются все
файлы receipt, подпись, хост и ограничения координатора. Host tools должны быть
подготовлены заранее; workflow не устанавливает пакеты автоматически.

После завершённого rollback новый attempt требует явного `retry_initial=true`.
Прерванный незавершённый attempt продолжается тем же source artifact; новый commit
вместо незавершённого не принимается. Public commit восстанавливается вперёд.
`rollout=legacy` сохраняет запрет routed deployment. Ordinary managed scopes
описаны в актуальном разделе выше; этот initial handler выполняет только первую миграцию.

CI initial handler выполнен на production в release51; независимый postcheck
сохранён по ссылке в начале документа. Ordinary release проходит отдельную проверку.

Pre-maintenance repair: Compose may retain config-files labels from historical
releases when it reuses containers. Initial namespace checks may use the current
legacy model only for the exact immutable IDs captured by the complete legacy
preflight. Image IDs, mounts, ports, networks and security checks remain mandatory;
this does not adopt an unknown container or trust a historical path as code.

If preparation failed before it created any role, network or backup/fence state,
`python3 -B infra/cancel_initial.py --root /srv/voicechat-managed --attempt <exact-nonce>`
can archive the original journal verbatim. The tool verifies the original source
receipt, unchanged healthy legacy baseline, legacy-certs ingress and an empty
attempt directory. It refuses prepared/fenced/public state. The corrected artifact
then starts a fresh attempt; never edit pending target/source/pointers manually.
