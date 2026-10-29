# Точка продолжения: три и более VPS

Обновляется 29 октября 2026 после возобновления работы владельцем.
Исходная остановка перед reboot завершала inventory/render и TLS;
после неё добавлены отдельные core/edge роли и локальная публикация каталога.
Последние итерации: один physical host, LiveKit resume/full restart, role manifests,
node-local WireGuard configs, Linux peer replacement, CI build config и отдельный WSS failover.
Владелец просит продолжать все доступные локальные задачи без дополнительных
подтверждений; новая просьба — итоговая схема сети, не остановка реализации.

## Актуальное состояние: production ingress, 29 октября

Production приложение всё ещё **8bcbd91**, manager **e964…**, ingress plan **5b27…**.
В этой итерации production проверялся только read-only, под legacy deploy.lock;
службы, данные и DNS не менялись. Полный core/edge transition ещё не выполнен.
[Проверенный baseline](three-vps-evidence/2026-10-29-production-core-baseline.json):
manifest/release record совпали, службы работают; PostgreSQL cluster ID и hash
Matrix signing key зафиксированы без вывода ключа. Старый daily backup от root
active/enabled, последний03:30UTC status0; его надо согласованно заменить.

Последние завершённые commits: **94b9c3e** — reuse parent ingress lock в full
migration (VM port-cutover повторён), **1c08288** — durable core backup и boot fence.
Commit **4d07fa2** добавил owned `core_backup_bootstrap.py` и исправления,
выявленные фактическим запуском: monitor распознаёт backup как planned maintenance
и не запускает restart loop; sealed backup проверяет recorded committed bundle и
точные topology/node fingerprints без обращения к отсутствующему source checkout.
Новые candidate deploy/prepare сохраняют полный `verify_bundle`, guard не ослаблен.
Runtime/data identity и все хеши старого bundle по-прежнему перепроверяются.

Текущие проверки: **400 Python tests, OK, skipped=3** (явные opt-in Docker);
focused backup/timer **15 PASS**, monitor **6 PASS**, boot/bootstrap **11 PASS**,
cutover **11 PASS**. Sealed roster теперь **32 files**, старый31 PORT_SOURCES и
25/26/27/28/29 packages остаются допустимыми и неизменяемыми.

Новый daily03:30UTC Persistent timer устанавливается только после общего commit,
для committed core с актуальным boot operator и неактивными legacy backup units.
Owned units/config имеют private receipt и same-target install resume. Старые
units не переписываются. Backup service повторяет crash с ограничением частоты.
После power loss с backup journal требуется явный запуск backup service: до этого
core boot закрыт. Это известное fail-closed ограничение, не автоматическое recovery.

**Реальный VM backup + systemd proof PASS**:
[evidence](three-vps-evidence/2026-10-29-vm-core-backup-current.json).
Сохранены current/previous, аккаунт/device/account data и Matrix signing identity;
пройдены snapshot interruption, boot fence, повтор незавершённого backup,
продолжение завершённого без нового snapshot и возврат доступности при ошибке.
Монитор перед snapshots штатно inactive с NRestarts=0; installed sealed systemd
backup service выполнился успешно. Все fixture volumes/containers/units удалены.
Это synthetic account в **4vCPU/4GiB multi-thread TCG VM**, не production/device
acceptance. Предыдущие отказавшие прогоны не выдаются за успех; найденные monitor
и renderer-checkout дефекты исправлены и повторены в этом полном proof.

Initial peerless network rollback/restore завершён как отдельный компонент:
**8 focused tests PASS**, полный Python **408 tests, OK, skipped=3**;
[настоящий kernel/systemd VM proof PASS](three-vps-evidence/2026-10-29-vm-initial-network-rollback.json).
Потеря ответа после WG delete и network start продолжена тем же intent; private
key/state, Docker PID, соседний container/HTTP и чужие nft tables сохранены.
Нормальная отмена peer revocation запрещена; контейнеры core/edge и active role
monitors блокируют retirement. Обычный resume/source upgrade/role deploy не обходят
private fence. Обработка initial runtime failure до boot install тоже проверена.
VM сеть после proof восстановлена; соседний fixture удалён. Production этим кодом
не изменялся. Полный coordinator ещё должен связать этот шаг с возвратом legacy
служб и reverse migration текущих pushers, без восстановления старой БД.

Дополнительно read-only подтверждён закреплённый production edge_root:
`/srv/voicechat-managed/edges/a`, business repo `/opt/avito-helper`; one-A public
identity и node generation1/tunnel10.88.0.1 совпали. Использовать этот путь при
initial full, не менять его на новый вариант при source-only manager upgrade.

Следующий компонент подготовлен локально: `legacy_core.py` read-only preflight
старого Compose baseline и `core_deploy.migrate_push_routes` — private stdin SQL
bridge при остановленных writers, со сверкой реального PG и persistent identity.
Исходный coturn image создаёт anonymous `/var/lib/coturn`: теперь его identity
проверяется и сохраняется temporary external binding при rollback, без изменения
старого pointer/Compose fingerprint. 8 focused preflight +6 maintenance tests PASS;
полный suite: **422 tests OK, skipped=3**.
[Сквозной VM proof PASS](three-vps-evidence/2026-10-29-vm-legacy-core-preflight.json):
реальные шесть legacy служб и тома, healthy/read-only/stopped-writer preflight,
backup/check, запрет active writer и foreign DB, forward/resume и reverse актуальных
pushers с сохранением новых metadata. После down без volumes выполнены legacy
recreate с temporary original coturn binding и последующий обычный legacy up;
account/device, PG/signing identity, coturn runtime и pointer сохранены. Fixture
полностью очищен. Это synthetic current-source legacy baseline, не production
8bcbd91 и не full core/edge adoption. Рабочий VPS дополнительно read-only проверен: backup units
точно совпадают с штатными файлами, кроме User=root; нет drop-ins. Timer enabled/
active, service static/inactive. Деплой/службы/DNS не менялись.

`legacy_backup.py` завершён отдельно: **6 focused tests PASS**, полный suite
**428 tests OK, skipped=3**. Private receipt + owned condition drop-in блокируют
новые legacy backup starts, не убивают in-flight service и сохраняют прежний timer
state. [Реальный systemd VM proof PASS](three-vps-evidence/2026-10-29-vm-legacy-backup-fence.json):
ConditionResult=no/ExecMainStart=0, retirement repeat и восстановление enabled/active
после потерянного ответа actual timer start; исходные units не менялись, fixture
units/state удалены. В production это не установлено; общий caller обязан держать
full+legacy lock и завершить rollback data services до restore scheduler.

TLS refresh и owned scheduler завершены как отдельные компоненты:
`cohost_tls.refresh` / `--refresh` используют owned loopback19443 и общий порядок
locks; capture-only по умолчанию сохранён. Full caller переиспользует ingress lock
через `_capture_locked` / `_refresh_locked`. `cohost_tls_bootstrap.py` ставит timer
после committed shared public mode и без pending edge, из текущего reviewed sealed
operator. Первый запуск через5min после активации timer, затем каждые15min с jitter.
Установка same-target resumable; чужие units не заменяются.

**5 refresh +6 timer focused tests PASS**, **16 TLS activation tests PASS**;
полный suite **440 tests OK, skipped=3**.
[Сквозной VM proof PASS](three-vps-evidence/2026-10-29-vm-cohost-refresh.json):
повторён public cutover/rollback; затем запущены настоящие cached web Caddy и
pinned coturn из unmodified prepared edge Compose. Проверены activation обоих
leaf через owned loopback, реальная web rotation, потеря ответа actual SIGUSR1,
same-target resume, no signals на неизменных парах, возврат прежней trusted pair,
неизменные ID/StartedAt/RestartCount. Установленный sealed systemd renewal service
выполнился успешно, timer enabled/active. Временная fixture CA добавлялась только
в disposable VM trust и удалена вместе с fixture units/state/containers/wrapper.
Core в этом proof не запускался, ACME storage был синтетическим; реального ACME
renewal, аккаунта, allocation/media и production перехода этот proof не доказывает.
Унаследованный warm-stage scope flag исправлен в evidence и выводе helper; actual
executed source hashes сохранены. Runtime operator точно совпал с local32-file
plan: **2b978af938912d1e5e21001992201fd2c51437844443baf2f15b41737630821d**.

Ранний fs69jzpm proof выявил реальный дефект `tls_activation.inspect`: Docker
сохраняет lexical bind Source через release/infra/runtime symlink. Отдельная actual
Docker probe подтвердила это. Теперь actual Source разрешается в **точный canonical
TLS service root**; foreign retargeting всё ещё запрещён до публикации. Исправление
проверено новым regression и последующим полным proof r3x6g5mw. Первый harness
также был исправлен: в payload добавлены пропущенные public Caddyfile inputs.
Ни одного app deploy, service change или DNS update на production в этой итерации
не выполнялось. Завершены commits94cd2a5 (legacy preflight/SQL) и1d3f63a (backup fence).
[Source-only manager upgrade production28→32 PASS на VM](three-vps-evidence/2026-10-29-vm-manager-28-to-32.json):
точный прежний e964… пакет обновлён на2b978… без смены процессов; повторены
installed CLI, workflow-only deploy, business reload, lost reply/Git recovery и
application service recreate с сохранением соседей. Fixture очищен. Production
operator по-прежнему старый, не обновлялся этим proof.
Далее общий legacy→core/edge coordinator с rollback. Нужен общий maintenance fence для role
boot/monitor на весь multi-step transition, не только child apply locks; не допустить
возврата writers во время SQL/policy reversal или после reboot pending full.

Full maintenance fence завершён отдельно: `runtime/full-rollout.json` привязан к
canonical root, role owner, случайному attempt и SHA точного target manifest.
Отдельные core/edge deploy, backup, push SQL и TLS refresh не обходят его; full
caller передаёт свой nonce. Boot/monitor не запускают и не останавливают writers
за coordinator; planned Type=notify exit проходит без restart loop, monitor_after
отложен до снятия fence. `legacy_core.fence_restart` меняет только captured legacy
containers на restart=no до backup, повторяя потерянный/частичный update по точному
baseline. Явные fencing/fenced read-only profiles допускают остановленную PG при
recovery, обычный strict profile по-прежнему требует healthy PG и прежние политики.

**6 full fence +10 legacy preflight tests PASS**, refresh **6 PASS**; полный suite
**449 tests OK, skipped=3**.
[Реальный Docker/systemd VM proof PASS](three-vps-evidence/2026-10-29-vm-legacy-rollout-fence.json):
restart policy update/lost reply/resume сохранили все процессы; stopped PG metadata
прочитана и PG запущена; actual maintenance boot success с NRestarts=0. Затем вновь
выполнены backup/check, nonce-owned SQL forward/resume/reverse и legacy recreation
с сохранением account/device/PG/signing/coturn. Fixture удалён. Ранний failed probe
был assertion race: systemctl start возвращает до окончательного inactive; journal
подтвердил успешный exit. Harness теперь ждёт конечного состояния, runtime ради
этого не менялся. Текущий32-file operator hash **888ecfec49650211ca41de4b5efc6b8d2bfde5248a82384535669373247c7c96**;
предыдущий source-upgrade proof2b978… остаётся историческим точным тестом.

Для следующего integrated baseline proof подготовлен source-built control из
**точного production Git commit8bcbd91**:
[image provenance](three-vps-evidence/2026-10-29-vm-legacy-control-source-build.json),
`ghcr.io/voicechat-fixture/legacy-control@sha256:bc8327d779a99c7be95ae057a1d8f1a791c6bf52618fbf0317dfd08292376084`.
Это новый local VM digest, не production image export и не bit-for-bit claim.
Все18 runtime COPY inputs cached candidateABC совпали с текущим checkout:
[проверка](three-vps-evidence/2026-10-29-vm-candidate-control-source-match.json).
Никакие control registry credentials из production не вывозились. Старый8b supervisor
имеет5s startup budget, новый30s; при cold TCG проверке учитывать реальный старый
budget, не подменять код старого image и не скрывать его неудачные старты.

Следующий конкретный шаг — initial one-A coordinator, связывающий эти компоненты.
Нужны: source-only manager upgrade до parent ingress lock, immutable target/nonce
journal, legacy timer fence + restart=no до stopped-writer backup, policy snapshot,
URL-only migration, legacy down **без volumes**, node-local initial WG bootstrap,
explicit core adoption seed с captured data identity, core/edge warm deploy, TLS
activation, shared public cutover, catalog и timers. После фактического ingress
commit только finish-forward; rollback до commit делает current-row push reverse,
policy restore, удаляет только owned containers (без data volumes), retire initial
network и legacy recreate с original coturn anonymous volume. Public Mac/Android
artifacts тоже должны быть сохранены и обслуживаться edge; новые publish paths
обязательны. Не восстанавливать старый DB dump поверх новых записей и не подделывать
legacy current.json/backend fingerprint. Full markers оставлять на staged roles
после rollback, units отключать; новый attempt разрешён только по завершённому
rollback с явной заменой своего прежнего nonce. При committed child + reboot owner
должен уметь восстановить current core без повторного configure, пока full fence
ещё активен; обычный boot по-прежнему заблокирован.

Далее: explicit legacy core adoption/full coordinator и rollback, согласованная
замена scheduler, TLS delivery/renewal, CI scopes, обязательный macOS/Android release
и приёмка устройств. Helpers/VM параметры остаются в `.prototype/vm/active.json`.

### Ранее подтверждённые шаги и исторические пакеты

Завершён `shared_cutover.py`: общий private journal, Caddy→HAProxy public port
transfer, trusted TLS/API/neighbor health, rollback освобождает 443 до восстановления
Caddy. Unknown source/runtime/container layouts и active Caddy JSON не перезаписываются.
10 focused controller tests PASS; инфраструктурный regression — **246 PASS**.
Полный release Python suite — **382 tests, OK, skipped=3** (явные opt-in Docker
scenarios; native Mac проверки, доступные обычному suite, выполнены).

**Реальный VM port-cutover proof PASS**:
[свидетельство](three-vps-evidence/2026-10-29-vm-shared-port-cutover.json).
На VM ports80/443 выполнены потеря ответа после настоящего Caddy recreate и
HAProxy recreate, same-intent resume, принудительная ошибка после проверенного
public TLS/API и возврат старого HTTPS. Соседние synthetic upstream processes
сохранены. Успешный commit/repeat и shared-mode manager no-op прошли. Fixture
containers/networks/volumes и wrapper удалены; публичный sealed source package
сохранён как content-addressed artifact. Это synthetic API/TURN TLS, без настоящей
core DB, allocation/media и reboot; production этот controller ещё не использует.

Sealed operator roster — 31 files, SHA
`aebb25f2a0fd92e6151d11c6e44c7e4cd48a53b5ce5a2259e3adf5e775c1822c`.
Старые 25/26/27/28/29 packages остаются читаемыми и не изменяются. Public front
определение sealed отдельно, warm-up его не выбирает; после takeover сохраняется
loopback endpoint для TLS renewal. Warm-up переиспользует cached immutable image.
VM также выявила transient EOF HTTP после backend restart: `edge_deploy.healthy`
повторяет только transport errors с ограничением времени; wrong status/body/
identity/upstream metadata всё ещё немедленно завершают проверку ошибкой.

Production остаётся e964…/5b27… ingress и 8bcbd91 app.
Новый 31-file package прошёл **реальный VM source-only upgrade из точного прежнего
production 28-file e964… package**, с сохранением всех процессов; затем повторены
installed CLI, workflow/route/app deploy и interrupted reload/Git recovery.
[Evidence](three-vps-evidence/2026-10-29-vm-manager-28-to-31.json). Fixture очищен.
Production upgrade этим кодом ещё не запускался.

Fresh web discovery тоже завершено: текущий website origin служит только hint
для подписанного каталога, API доверяется после проверки pinned signature.
Нативный Mac test и настоящий browser JS/WASM proof прошли, включая реальную
перезагрузку страницы/localStorage, unsigned hint, контрольный cookie, credentials
omission, запрет redirects, oversized response и client.close до fetch.
Стандартный BrowserClient отправляет same-origin cookies; отдельный маленький web
Fetch adapter явно ставит credentials=omit, сохраняет потоковый лимит, AbortController,
Content-Length validation и timeout. Native HTTP путь остаётся стандартным.
[Evidence](three-vps-evidence/2026-10-29-website-catalog-discovery.json).
Assets пересобраны штатным генератором с pinned Flutter/Rust/nightly/tools и clean
upstream commit; готовые файлы не копировались вслепую из прежней сборки.
Все browser fixtures/tab закрыты, private signing fixtures удалены штатным finally.
Пользовательский browser storage не очищался; использовался synthetic marker.
Это ещё не новый client release и не проверка реального аккаунта/звонка/экрана.

Далее: legacy core adoption/full, TLS renewal, CI и обязательный client release.

Перед production publication усилены файловые границы `publish_catalog.py`:
canonical owned runtime без чужой записи, private regular no-follow lock и
bounded no-follow чтение прежнего signed high-water mark. Symlink, FIFO и
writable state отвергаются до замены документа. Anti-rollback/concurrency/crash
tests сохранены; 6 catalog tests PASS. Production catalog ещё не опубликован.

Новый `shared_front.py` подготавливает независимый HAProxy plan из проверенного
edge bundle и запускает только `127.0.0.1:19443`. Ни Caddy, ни public 443,
ни core/edge приложения он не меняет. Private journal, проверка SSH host,
immutable source/mount/image/network/port identity, отказ от чужих ресурсов,
same-plan resume и восстановление своего stopped listener. Web image/revision
не меняет frontend plan. В реальной Debian VM подтверждены lost-response после
Compose up, повтор без смены процесса, stop/recovery и полная очистка fixture.
[Evidence](three-vps-evidence/2026-10-29-vm-shared-front-warm.json).
Probe затем расширен: настоящие Caddy TLS backends с disposable CA, точный
проверенный leaf для web/TURN, strict PROXY source и API readiness через warm
port. Ответ с чужим service ID отвергнут после успешного TLS. `edge_deploy.healthy`
получил bounded `warm_port` только для shared role; обычные deploy/boot по-прежнему
проверяют публичный IP:443. Три focused tests проверяют оба endpoint, identity/age/
upstream failures и запрет warm override для dedicated edge. Реальных core/TURN
allocation/media в этом probe нет. Безопасное чтение source переиспользует
существующий `shared_ingress.read_environment`.
Public promotion/demotion и связанный Caddy rollback ещё не реализованы этим шагом.

Для полного отката добавлен `push_route_migration.restore_public`: отдельная
URL-only транзакция по актуальным private pushers, включая подписки, созданные
после запуска candidate. Прежний rollback точного forward journal оставлен для
своего узкого сценария. В настоящем PostgreSQL disposable VM проверены новые
подписки, сохранение свежих metadata/stream offsets/pushkeys, удалённые строки,
foreign app/kind, interruption после reverse commit и повтор. Fixture удалён.
[Evidence](three-vps-evidence/2026-10-29-vm-push-full-rollback.json).
Вызывать только под core lock, при остановленных writers и проверенном backup;
затем перезапустить Synapse. Общий production orchestrator ещё не подключён.

Manager теперь умеет сохранять уже committed `shared` mode при business update:
единый renderer для stage/install/preview, strict PROXY source, certificate sinks,
порт 80 и external bridge сохраняются. Legacy adoption/recovery по-прежнему
отвергает shared journal: автоматический возврат старого leaf mount не разрешён.
Три новых unit сценария покрывают workflow/route update, reload failure/resume
и разделение legacy recovery/manager. Это подготовка controller, ещё не реальный
port cutover; production manager пока не обновлялся этими исходниками.

Следующий завершённый блок: `cohost_tls.py`, 29-file reader package
`2b37777501e3bfc74de52b7ae55ef84ca3add991dc2432e0ea73f7fa01531ab7`.
На A дважды выполнен capture обеих реальных доверенных TLS-пар в закрытый
server-local cache. Receipt одинаковый; ключи A не покидали, edge activation
и renewal timer ещё не выполнены. Manager остаётся на прежнем e964… package.
Полный инфраструктурный regression: **218 PASS**, Flutter analyze PASS.
Нативный macOS integration test с настоящей Ed25519 проверкой и локальным HTTP
mirror прошёл: клиент получает D, затем E через известный bootstrap website,
когда все cached API недоступны; недействительная подпись не меняет revision.
Теперь discovery сохраняет bootstrap origins и использует web mirrors, с dedup.
Это не проверка звонка/экрана или полного Matrix восстановления.

CI repository variables `PUBLIC_URL`, `CLIENT_ROUTE_CONFIG` (один A) и
`CLIENT_ROUTE_CATALOG_KEY` сохранены и проверены через GitHub UI.
Постоянный Ed25519 signing key находится только на Mac вне Git/cache:
`/Users/anton/.config/voicechat/signing/route-catalog.pem` (0600, каталог 0700).
Public key: `UV1n2w5zyEhKBYq0Y4ORasu0CFvJCIBheWbhotiZDG8=`.
Не перевыпускать ключ; не отправлять private key в CI/VPS. Нужна отдельная
резервная копия владельца. Первый production signed catalog ещё не опубликован.
Docker Desktop full Matrix fixture завис до старта приложения; остановлен только
его Compose child, штатный finally удалил только fixture containers/volumes/network.
Standalone нативная catalog проверка выполнена успешно без Docker; основной
профиль/Keychain пользователя не очищались. [Evidence](three-vps-evidence/2026-10-29-catalog-and-cohost-capture.json).

Предыдущий ingress checkpoint — `60cb9aa`, ветка `codex/three-vps-rollout`.
На production уже manager package
`e9648a0be5de03eedd75dcd1e06d2b82d10d04f53f53927cf775ffb468f50696`,
current **legacy-certs** plan
`5b27dc08f1cc4ffb267fd06508ac47ece34a421cb2f090b70f70d71f1648f69f`.
Подготовительный HTTP-01 выпуск TURN сертификата прошёл за 8.65s без DNS change
и перезапуска контейнеров. Trusted SNI fingerprints проверены на A, внешняя
проверка TURN даёт verify=0/HTTP421 (certificate sink, ещё не TURN relay443).
Канонический cert остался прежним. Installed manager no-op после смены mode тоже
прошёл, все журналы clear. [Production certificate proof](three-vps-evidence/2026-10-29-production-cohost-certificates.json).
Далее — source certificate capture/fanout/renewal, shared-front/full/core migration.
`/srv/voicechat-managed` всё ещё не создавался; VoiceChat release остаётся 8bcbd91.
Ниже начальный ingress checkpoint, после него — подробная история. Старые
b5ab/e977/7b08 состояния не являются текущими.

**198 infrastructure tests PASS** и полная disposable VM проверка manager.
На production выполнен подготовительный legacy Caddy adoption: directory mount
и pinned прежний Caddy, private server-local dotenv snapshot/managed COMPOSE_FILE,
sealed manager package `b5ab0d0973e8c7e2f34d009abfb6aba89cbb32b69e2776e84b0dae2762f06b6b`.
Корень `/var/lib/voicechat-shared-ingress`, current plan
`e9776c9f36b4c2fb5a2149b24a2dfffcecda596affb7e723396843c6fef193f6`.
Wrapper `/usr/local/sbin/voicechat-shared-deploy avito-update` установлен/проверен.
Изменился только Caddy; все прочие процессы и volumes сохранены, оба внешних HTTPS
200. Это **не** общий shared-front cutover и **не** новый VoiceChat release.

Avito main теперь `e2c1f05de015b242e5b9ffd3e13d1fca5f9e9c66`: только workflow hook,
без изменений приложения. Branch `codex/preserve-shared-ingress` также опубликован;
PR не создавался. [Настоящий deploy run](https://github.com/kerbermeister/avito-helper/actions/runs/40799014967)
прошёл. Manager обновил Git, source Caddyfile теперь business-only/clean, runtime
VoiceChat routes сохранились вне Git. Ни соседние процессы, ни Caddy этим workflow
не перезапускались. Pending отсутствует. [Production evidence](three-vps-evidence/2026-10-29-production-legacy-ingress.json),
[shell hook contract](three-vps-evidence/2026-10-29-business-workflow-hook.json).

VoiceChat app/server baseline всё ещё `8bcbd91…`; VPS/DNS/WireGuard/core/edge ещё
не переводились на новые роли. `/srv/voicechat-managed` пока не создавался, только
задан как будущий edge_root в плане. Исходники — server-local lab
`/srv/voicechat-lab/shared-ingress-b5ab0d0973e8c7e2f34d009abfb6aba89cbb32b69e2776e84b0dae2762f06b6b/infra`;
истинный sealed package — `/opt/voicechat/operators/<digest>/infra`.
Private dotenv backup остаётся только на A; не копировать его в VM/CI/edge.

Следующее: certificate preparation/renewal для cohost через прежний Caddy HTTP-01
(сейчас turn.univc.duckdns.org уже указывает на A), shared-front cutover controller,
legacy core adoption/full orchestration/CI scopes, реальный role release и
обязательный подписанный macOS update. Не запускать ранние `.prototype` scripts,
которые утверждают Avito HEAD=83df69c: после workflow его HEAD уже e2c1f05.
Они оставлены как история preflight. Локальные SSH helpers `.prototype/prod-exec.py`
и `.prototype/vm-exec.py` используют строгие прежние known_hosts, без agent forwarding.

Ниже — последовательные технические checkpoint, включая исторические ограничения
до production ingress adoption; при расхождении ориентироваться на этот блок.

### Следующий checkpoint: cohost certificate preparation

Добавлены mode `legacy-certs`, `shared_config.py` и безопасный code-only upgrade
в `shared_update.install`. Legacy + manager source roster теперь 25/26/27/28,
старые packages не модифицируются. **210 infrastructure tests PASS**, включая
9 certificate journal/trust-boundary cases и 3 source-upgrade interruption cases.
Новый package `e9648a0be5de03eedd75dcd1e06d2b82d10d04f53f53927cf775ffb468f50696`
прошёл [реальный VM upgrade из фактического прежнего b5ab…](three-vps-evidence/2026-10-29-vm-shared-manager-source-upgrade.json)
без изменения процессов, затем повторен полный installed CLI/app deploy/recovery.
Fixture очищен. [Certificate config](three-vps-evidence/2026-10-29-vm-cohost-certificates-parser.json)
валидирован stock Caddy 2.8 без сети, TLS-ALPN disabled у обоих VoiceChat имён.

На момент локального certificate checkpoint production был на manager b5ab…/e977….
После commit 60cb9aa source-only upgrade и certificate preparation уже выполнены
(см. актуальный блок в начале), все container processes сохранены. Read-only preflight: canonical
и turn.univc.duckdns.org дают только 84.200.80.13, ACME directory HTTPS доступен,
текущий trusted canonical cert expires Jan21 2027, в Caddy volume есть одна его
пара (private key не читался/не экспортировался). Reviewed 28-file package доставлен, install upgrade и stage/apply `legacy-certs`
прошли с настоящим SNI/CA подтверждением. User permissions уже даны.
Дополнительный focused test бизнес-деплоя после certificate mode прошёл (10 tests
в test_shared_config); предыдущий полный regression — 210 PASS.

## Текущая рабочая копия после интеграции

Продолжать в `/Users/anton/.codex/worktrees/three-vps-rollout/VoiceChat`,
ветка `codex/three-vps-rollout`, база `2cca4d3ac7ffdb2355a39302f8fe93ec747e8b8d`.
Исходная грязная копия `/Users/anton/IdeaProjects/VoiceChat` сохранена;
не переносить её целиком поверх новой. Изменения задачи перенесены через
трёхсторонний merge; актуальные production-исправления звонков, экрана, P2P и UI
сохранены. Lifecycle conflict объединён: refresh маршрутов + poll экрана.
Flutter/Rust caches пока переиспользуются из `.prototype` исходной копии.

Фактический production: `8bcbd91b578fa7bc4dfe58a1f740980248fac1c9`,
Ubuntu 24.04.5 amd64. TCP 80/443 принадлежит Caddy соседнего Avito Helper;
он проксирует `univc.duckdns.org` в `voicechat-web:80` по общей Docker-сети.
Нельзя применять bootstrap чистого Debian или занимать 443 без отдельного
перехода shared ingress с откатом. DNS `turn.univc.duckdns.org` тоже указывает
на текущий VPS. DuckDNS token не найден в проверенных runtime-путях;
браузерная сессия DuckDNS не авторизована. Реального ACME issuance ещё нет.

Изолированный VPS role/TLS fixture `voicechat-sni-1c9eff7c06c0` прошёл:
рабочий publisher, rotation + rollback, проверенные сертификаты, сохранённая
TURN allocation и процессы. Контейнеры/сеть/том удалены; приватный каталог
`/srv/voicechat-lab/three-vps-20261028-93e52467dd` оставлен с исходниками/логом.
[Свидетельство](three-vps-evidence/2026-10-28-vps-tls-runtime.json).
Production не обновлялся и не перезапускался; API/Matrix HTTP 200.

После интеграции: 106 Python host/infra tests PASS, Flutter analyze PASS.
Полный Flutter запуск: 395 PASS, 3 SKIP, один FAIL из-за отсутствующего
`.prototype` для QR fixture; после подготовки каталога все 4 QR tests PASS.
Добавлена маршрутизация web push через общий transport; 2 HTTP tests и
8 JS bridge/worker tests PASS. Отдельная browser interop проверка PASS (скомпилированный Dart/JS, отдельный headless профиль).

### Последний завершённый блок: TLS activation

`tls_activation.py` держит общий TLS lock на publish → signal → trusted
CA/SNI/точный leaf → unchanged container ID/StartedAt/RestartCount. Журнал
pending/verified; retry и rollback к валидной старой паре. Повтор той же проверенной
пары без reload. В новом edge bundle включён controller. 121 общий Python test
PASS; отдельные manifest guards после этого — 7 PASS. Guard теперь отвергает
добавочные исходники (в том числе Python import shadowing), а не только проверяет
hashes перечисленных файлов.

Рабочий controller прошёл VPS fixture с rotation/rollback и прежней TURN allocation.
[Свидетельство](three-vps-evidence/2026-10-28-vps-tls-activation.json).
Все тестовые контейнеры/сети/тома удалены. Приватные исходники/логи остались в
подкаталогах `activation` и `activation-final` ранее созданного lab-каталога.
Production по-прежнему `8bcbd91`, HTTP 200; службы не перезапускались.

Следующий большой блок — V3-20: раздельный role deploy, durable current/previous,
общий lock с TLS, failure/resume/rollback, затем shared ingress migration.
Не выдавать TLS controller за уже готовый автоматический renewal scheduler или
завершённый deploy. Реальный DuckDNS DNS-01 пока требует недоступного account token.

### Текущая итерация: edge/web deploy и чистая VM

Основа сохранена локальным коммитом `35c7649` (без push/deploy). После него добавлены
`edge_deploy.py` + 11 tests: реальные private filesystem/source guards, имитация
Docker fault/up/rollback. 53 focused tests PASS. Настоящий Docker proof завершён ниже. Его prerequisites/ограничения: `infra/THREE_VPS.md`.
Добавлены completed network fingerprint и общий network lock до конца rollout;
частично применённый intent больше не считается готовой сетью. Persistence
отвергает oversized/NaN до замены предыдущего восстанавливаемого состояния.

Добавлен `role_prepare.py`: atomic source-verified bundle, private role identity,
shared runtime symlink, no secret copy/service start, idempotence and refusal of
foreign data. Releases теперь именуются SHA-256 полного manifest, а не только
Git commit: config-only изменения одной версии кода сохраняют отдельный rollback
bundle. 123 выбранных infrastructure tests PASS; из них 12 edge deploy,
5 role preparation и 4 boot installer tests. Лог `.prototype/three-vps-infra-tests.log`.

QEMU 11.1.2 установлен. Официальный Debian12 genericcloud amd64 `20261026-2643`,
SHA512 проверен; metadata `.prototype/debian-vm-image.json`, image `.prototype/vm/`.
Активная disposable VM: `.prototype/vm/active.json`, SSH helper
`.prototype/vm-exec.py`; только синтетические данные, 2 GiB/2 vCPU, amd64 TCG.
VM пока запущена для следующих проверок; остановить через её SSH `systemctl poweroff`
после завершения испытаний, не трогать Docker Desktop/production.

Реальные network bootstrap/repeat/reboot и fail-closed проверки PASS:
[свидетельство](three-vps-evidence/2026-10-28-vm-network-boot.json).
Docker 29.8.1, Compose 5.5.1, Debian nftables 1.0.6. Установщик не перезапустил
работающий Docker; после reboot firewall/WireGuard завершились до Docker.
Без desired intent сеть failed и Docker inactive; после восстановления intent
оба active. Исправлена обнаруженная только на настоящем Debian ошибка:
`systemctl list-unit-files <отсутствующая служба>` возвращает exit 1, теперь
проверяется успешный полный список и точное имя. Fixture scripts/logs находятся
в `.prototype/vm-network-*` и `/srv/voicechat-boot-fixture` внутри VM.

Настоящий edge deploy/rollback выполняется в этой VM. После отказа anonymous
GHCR pull auto-review отклонила получение производного токена из registry credentials
VPS. Владелец затем **явно разрешил repository:pull токен для VM**. Разрешённая
операция выполнена: исходные credentials остались на VPS, ограниченный токен
передан только в VM, существующий web digest `68739c97...` скачан, token config
удалён сразу после загрузки (проверено). Повторного разрешения на эту же операцию
не требуется. Helper `.prototype/vm-pull-private.py` не содержит самих secrets.

Реальный edge probe завершён: initial, web-only без перезапуска остальных служб,
config-only отдельный bundle, readiness failure rollback и interrupted apply resume.
[Свидетельство](three-vps-evidence/2026-10-28-vm-edge-deploy.json).
Все fixture containers/networks/volumes удалены. Synthetic upstream, не реальные
пользовательские данные или звонки. Исправлены сохранение TLS serving directories
в role_prepare и pull policy missing для immutable digest cache.

Приватный push: новый pusher получает URL core private IP:8090; Synapse разрешает
ровно этот /32, остальные private destinations остаются под SSRF blacklist.
Core bridge firewall допускает только этот callback. Реальный namespace proof
на VPS и настоящий Synapse в VM подтвердили доставку, блокировку другого
доступного private destination и отзыв pusher:
[firewall](three-vps-evidence/2026-10-28-private-push-firewall.json),
[Synapse](three-vps-evidence/2026-10-28-vm-private-push.json).
Существующие production pushers ещё требуют согласованной миграции URL.

Network applied receipt теперь включает hashes кода политики, а не только inventory.
`network_bootstrap.py --upgrade` обновляет owned immutable source через ExecReload,
не restart Docker; durable journal допускает retry только той же версии.
Незавершённый upgrade блокирует edge deploy. Unit tests: отказы, подмена исходников,
прерывание после замены unit, retry, no-op и отсутствующий applied receipt.
Настоящий upgrade, повтор и reboot новой версии в VM прошли: ключ сохранён,
новая политика восстановлена, network active предшествует старту Docker.
[Свидетельство](three-vps-evidence/2026-10-28-vm-network-upgrade.json).
Общий выбранный регрессионный набор: **150 tests PASS**.

### Следующий core блок: подготовлен миграционный примитив

Checkpoint `b0f1a7f` сохраняет edge/network/private-push proofs. После него добавлен
`push_route_migration.py` в core bundle: PostgreSQL transaction, exact URL-only
update, private journal до UPDATE, resume после DB commit, rollback без восстановления
удалённых/чужих изменённых подписок. 4 unit tests и реальный PostgreSQL probe PASS:
[свидетельство](three-vps-evidence/2026-10-28-vm-push-migration.json).
В core deploy пока **не интегрирован**. Caller обязан остановить всех writers,
проверить backup, удерживать общий lock и после commit перезапустить Synapse.
Не запускать этот примитив вручную на production как замену orchestrator.

Второй реальный Compose probe подтвердил repeat configure, сохранение signing key,
media и permissions, private push whitelist и отсутствие core secrets в edge:
[свидетельство](three-vps-evidence/2026-10-28-vm-core-config.json).
Исправлен отсутствовавший bind mount node_inventory.py в core configure service.
Fixture resources удалены. VM пока доступна для следующих core/backup испытаний.
Последний полный выбранный регрессионный набор: 154 tests PASS.
Далее: согласованный core backup/full controller + legacy baseline/shared ingress
migration, затем SSH/CI orchestration. Production не обновлён.

### Core backup и независимый Compose

Checkpoint `c397939` сохраняет pusher migration primitive и core configure mount.
После него исправлена выявленная настоящим Compose зависимость core от WEB_IMAGE,
SITE и web-портов: в core bundle наследуемый compose.yaml содержит только четыре
core service blocks из canonical legacy файла. Изменённый формат/дубликаты/пропуск
служб отвергаются; legacy compose.yaml в репозитории не изменялся. Реальная
повторная инициализация без web environment прошла, identity/media сохранены.

Существующий `deploy.backup(..., core=True)` теперь умеет сохранять core volumes,
stand.env, immutable release и state.json. Это внутренний backup primitive, не
новый production CLI mode. Legacy mode и его tests сохранены; core запрещает
унаследованный legacy compose override. 157 выбранных tests PASS.
`prototype/check_core_backup.py` прошёл на настоящих PostgreSQL/Restic в VM:
backup/check/restore, сохранение Matrix identity/media/control SQLite/runtime/state,
читаемый SQL dump, пароль Restic не попал в snapshot. Все fixture resources удалены.
[Свидетельство](three-vps-evidence/2026-10-28-vm-core-backup.json).
Это не полный запуск восстановленного приложения. Writers в fixture не запускались;
production orchestrator ещё должен обеспечить stop/backup/migration/start ordering.
Следующий блок — durable core/full controller, затем shared ingress/legacy adoption
и SSH/CI integration. Ни новый production релиз, ни DNS не применены.

## Продолжение core/full (текущая незавершённая итерация)

Работа продолжается после нового разрешения владельца довести core/full и production
без ожидания его ответов. Оценка общей готовности в начале этой итерации — около 60%.
Базовый commit этой итерации — `a7e37fc`; новые изменения пока не закоммичены.

Добавлены `core_deploy.py`, общие `role_deploy.py`, `role_boot.py` и
`role_bootstrap.py`. Core journal: prepared/stopping/backed-up/applying/rollback;
backup после остановки writers, сохранение/откат client policy, никаких pg_restore
поверх новых записей, current/previous и same-target resume. Runtime secrets,
host identity и engine upgrades закрыты guards. Core state дополнительно хранит
PostgreSQL system identifier и hash Matrix signing key; missing volumes/data identity
не должны запускать пустую замену. Legacy deploy отвергает role-deployment.json marker.

Реальный первоначальный core lifecycle (до boot gate) прошёл:
[historical proof](three-vps-evidence/2026-10-28-vm-core-rollout.json).
Initial/upgrade с настоящим backup, actual control stop → rollback, interrupted up →
resume, synthetic account/device/account data/signing key сохранены. Приватный
control image экспортировать с VPS **не удалось**: auto-review отклонила private
artifact transfer (предыдущее отдельное разрешение было для web). Экспорт не выполнялся.
Безопасная альтернатива завершена: control собран из локальных Dockerfile/COPY sources
в VM, `type=image,push=false,name-canonical=true`. Локальный непубликованный digest:
`ghcr.io/voicechat-fixture/control@sha256:9e871e3caa460028f14d09fef69cf474cccf383b1e2a0ac394fe55f9caa33c30`.
Ни production credentials, ни данные в VM не передавались.

**Важный найденный дефект:** реальный negative reboot с on-failure поднял PostgreSQL
в обход network gate. Этот тест провален и не засчитан. Старый fixture очищен;
после него также наблюдался DNS сбой postgres alias. Поэтому теперь все контейнеры
VoiceChat используют Docker restart=no, а отдельный systemd Type=notify monitor
восстанавливает committed роль. При maintenance он выходит без restart, чтобы
не вмешиваться в backup. Controllers активируют monitor после освобождения locks;
pending applying/rollback не поднимается автоматически. Prepared pull может
восстановить прежний committed current. Shared Docker ordering — Wants/After;
разрешён только с restart=no и enabled owned per-role --watch units. Соседние
workloads запускаются независимо. Повторный negative reboot **прошёл**: ни одного
running VoiceChat container, Docker active и соседний HTTP fixture доступен.
Аварийный docker kill control → systemd recovery и Docker daemon restart тоже
прошли с прежней account/device/data identity.

VM работает, helper `.prototype/vm-exec.py`, metadata `.prototype/vm/active.json`.
Текущий реальный новый No/monitor probe:
`.prototype/vm-core-rollout-probe.py` → VM `/srv/voicechat-edge-fixture/core-rollout-probe.py`,
лог `.prototype/vm-core-rollout-monitor-probe.log`, exec session 2915 завершена.
Initial/upgrade/actual failure rollback/interruption resume прошли. Fixture
оставлен для boot проверки, session/token только synthetic, VM file
`core-boot-session.json` mode600. Приватный boot probe:
`.prototype/vm-core-boot-probe.py`, modes prepare/runtime-failure/verify-restart/
verify-reboot/corrupt/verify-blocked/restore/verify-restored/cleanup.
Лог boot `.prototype/vm-core-boot-monitor.log`: negative reboot пройден; после
restore intent реальный reboot сначала **превысил 240s probe**, затем повтор
verify-restored прошёл с прежним аккаунтом/ключами. Первый cold start не принят.
Control supervisor имел общий 5s deadline на initial start и runtime outage;
под TCG холодный Python/SFU start мог не укладываться. Добавлен отдельный initial
30s budget только production supervisor entrypoint; после первой готовности
runtime cutoff остаётся 5s, crashed child завершается сразу. Unit tests это
проверяют, включая delayed first readiness и последующее короткое отключение.

`core_deploy.data_identity` read-only/no-network probes переданы в VM после
завершения journal; revision e + immutable operator source upgrade прошли.
Дополнительный guard теперь проверяет data identity и после rollback, оставляя
unsafe rollback pending при подмене данных (unit test PASS).

**Текущий активный шаг:** новый supervisor собран в VM из public repository sources,
локальный непубликованный control digest
`sha256:abc8e6e2f226aec43a3e59e0229b18b72070f4046f79e5a63b99ea410fd7b9d4`.
Все reviewed operator SOURCES синхронизированы в VM после completed journal.
Revision f core update с реальным backup и новым source package прошёл:
session 45484 завершена, log `.prototype/vm-core-startup-upgrade.log`.
Тот же synthetic account/device/account data/data identity подтверждены.
Cold reboot и bounded verify-restored прошли с **NRestarts=0**, session 22675
завершена. Дополнительно canonical control healthcheck получил start_period=30s,
чтобы не объявлять unhealthy до разрешённого startup budget. Это проверено ещё
одним реальным core upgrade (fixture revision `1`×40, тот же image), actual Docker
Healthcheck.StartPeriod=30000000000 и неизменная data identity. Cold proof — на
revision f перед этой health grace; дополнительный reboot grace-конфига не заявлен.
Cleanup завершён: core unit/containers/volumes/network/neighbor и synthetic token
удалены. Итоговые публичные отчёты (historical proof выше сохранён):
[core lifecycle](three-vps-evidence/2026-10-28-vm-core-monitor-rollout.json),
[role boot](three-vps-evidence/2026-10-28-vm-core-role-boot.json).
Hashes core/boot/supervisor/compose сверены с локальными исходниками.
Regression после final helper/grace изменений: **165 tests PASS** (session 31917
завершена). Scope — infra/role/network/TLS/supervisor, без повторной Flutter сборки.

`shared_legacy_proxy` renderer сохраняет business routes, точный PROXY trust,
strict SNI и HTTP-01-only certificate sinks без старого VoiceChat reverse_proxy.
5 edge config tests и настоящий Caddy 2.8 no-network validate прошли:
[parser evidence](three-vps-evidence/2026-10-28-vm-shared-caddy-acme-parser.json).
Это не ACME issuance. VM core operator не обновлялся последним неиспользуемым
для core helper, чтобы не менять installed package посреди теста.

В работе также config для общего TLS: optional co-located `shared_tls` /29 profile,
SNI legacy fallback, `shared-node-inventory.example.json`, unit tests passed.
Offline renderer уже исправлен: независимый shared-front HAProxy с public443 и
restart unless-stopped, persistent external edge bridge, без TLS/runtime secrets.
Shared edge не содержит ingress; dedicated edges сохраняют свой. Manifest guards
требуют ровно одну dedicated/shared definition; web-only не меняет front. Monitor
и snapshot не управляют внешним listener. `check_shared_front.py` прошёл в VM на
настоящих HAProxy/Caddy 2.8: три TLS routes, strict SNI/Host, stopped web/turn не
мешают neighbor и не перезапускают front; известные недоступные SNI не уходят в
legacy fallback. Все его resources удалены; [evidence](three-vps-evidence/2026-10-28-vm-shared-front.json).
Первый fixture не ждал готовности всех backends и был исправлен после диагностики;
провал не засчитан. Это не TURN allocation, shared-front reboot, ACME или production
migration. Global shared controller/port cutover и Avito deployment persistence
по-прежнему открыты. Топология/THREE_VPS.md обновлены.

Avito source cloned (no AGENTS.md) в `.prototype/avito-shared-ingress`.
Локальная ветка `codex/preserve-shared-ingress`, **без push/main changes**: draft
workflow делегирует `/usr/local/sbin/voicechat-shared-deploy avito-update`, если
installed; fallback отказывается при dirty tracked files вместо git checkout.
Shell fixture проверил delegation, propagation failure и сохранение dirty Caddy.
Сам managed CLI **ещё не реализован/не установлен**. Перед main push обязательно
поставить legacy-compatible protected config/CLI; сейчас production не менялся.
Repo `kerbermeister/avito-helper`; main push автоматически deploy. Его workflow
выполняет **git checkout -- .** и может стереть server-local VoiceChat Caddy changes!
Не push/merge main до установки защищённого legacy-compatible shared config/CLI.
Нужен workflow hook к managed ingress CLI + global lock; Caddy-only scope должен
сохранять backend/frontend/PostgreSQL IDs. Caddy config лучше directory mount,
чтобы atomic replace не оставлял старый inode bind mount. Production .env не
переносить в VM/CI/локальные fixtures.
Production Caddy public image digest:
`caddy@sha256:226d1f059b75399fe19182893c7184591c07b97afc8dfcf44eeb80c9a77a530f`,
DOMAIN `listing-helper.flashhub.net`, compose `/opt/avito-helper/deploy/docker-compose.yml`.
TCP80/443, UDP443 отсутствует. Изменений production/DNS по-прежнему нет.

### 29 октября: следующий блок shared ingress

Проверенный core checkpoint сохранён commit `4ca5f3a`, staging/legacy TURN —
`9c469ac`. `shared_ingress.py` содержит renderers legacy config/Compose override
и `stage(...)`: immutable планы по digest + тот же reviewed operator package,
без создания runtime/.env/Git checkout/systemd unit. Реальная VM staging проверка
прошла, включая идемпотентность обоих режимов и сохранение прежнего плана:
[evidence](three-vps-evidence/2026-10-29-vm-shared-ingress-stage.json).
`role_bootstrap` выделяет source-only staging и принимает ровно два известных
roster (до/после shared_ingress.py) для проверки прежних установок; ready по-прежнему
требует полный текущий target. Проверены unit upgrade и настоящий старый VM receipt.
Планы fixture удалены, content-addressed public source package оставлен в VM.

Compose 5.5.1 проверил !override для volumes/ports: leaf Caddyfile mount удалён,
старые deploy_caddy_data/config сохранены, business service definitions не меняются;
shared Caddy сохраняет TCP80 и отдаёт 443 внешнему front. Внешняя сеть нормализуется
Compose с пустым ipam mapping; fixture assertion уточнён после диагностики:
[evidence](three-vps-evidence/2026-10-28-vm-shared-ingress-compose.json).

Добавлен co-located `legacy_turn: true` (default false, dedicated edge не принимает
этот флаг): aliases 3488→3478 TCP/UDP сохраняют старые cached TURN URI. Host identity
и generation не меняются. Реальный `check_route_tls.py --role-bundle --single-entry
--cpus 1` прошёл в VM: TCP auth allocation/expiry/private peer denial, UDP binding,
signed catalog update, TLS rotation/rollback и secret overlap/retirement:
[evidence](three-vps-evidence/2026-10-29-vm-legacy-turn.json).
Публиковались random loopback ports, не настоящий host3488; это не UDP relay media
или E2EE/device acceptance. Первый TCG run с quota .25 hit readiness timeout, не
принят. Добавлены fixture CPU option (старый default сохранён) и retry временных
readiness OSError в прежнем bounded deadline. Обе попытки полностью очищены.

Итоговая infra regression **172 tests PASS**, Flutter повторно не собирался.
Production по-прежнему не менялся; свежая read-only проверка Avito:
main `83df69c3c5add7ae9c1b4a8370bb220ba9211b27`, dirty только deploy/Caddyfile,
repo/.git root:root 0755, .env и Caddyfile root:root 0644. Содержимое .env не
экспортировалось. Последний production VoiceChat — прежний 8bcbd91… release.

Следующее: controller фактического legacy adoption/rollback и `avito-update`
manager CLI ещё отсутствуют. Не устанавливать draft workflow hook/не push main
Avito до их готовности. Минимальный путь: prepared config вне Avito Git; directory
mount; persistent COMPOSE_FILE в server-local .env; тот же global apply.lock для
Avito update и VoiceChat migration. До mutation сверить pinned Caddy image,
mounted config/volumes/ports, adapted semantic config, Git HEAD/dirty paths и
neighbor container IDs. `.env` сохранять byte-for-byte кроме управляемой строки;
использовать Compose для dotenv interpolation/JSON config comparison, не писать
свой parser секретов. Config из старого Git HEAD и текущий custom Caddyfile должны
быть семантически одинаковы после добавления прежнего VoiceChat block. Затем
candidate validation, journal, targeted Caddy-only recreate/reload + HTTPS checks,
preserve neighbor IDs и автоматический возврат при ошибке. Публикация нового
shared-front/port443, ACME issuance/renewal/export в edge, legacy core adoption,
full/SSH/CI integration, production release и обязательный macOS update остаются.

### 29 октября: read-only проверка перед adoption

`inspect_legacy_plan` сверяет SSH identity, private immutable plan/operator,
Git main/HEAD/изменённые пути, native Compose dotenv interpolation, pinned Caddy
binary, restart policy, ports, mounts/volumes/networks. Adapted staged и on-disk
Caddy config должны совпадать с активным admin config. Результат содержит только
hashes/IDs; environment остаётся на сервере, соседние процессы не меняются.
Пять negative/positive tests и реальная disposable VM проверка прошли:
[evidence](three-vps-evidence/2026-10-29-vm-shared-legacy-inspect.json).
VM fixture использовал synthetic Git/env/upstreams/internal certificates; два
последовательных inspection дали одинаковый baseline, все его Docker resources
удалены. Это ещё не adoption, ACME или port cutover. Legacy operator source roster
зафиксирован явно, чтобы добавление следующих modules не меняло его задним числом.
Полная инфраструктурная regression — **177 tests PASS**. Production без изменений.

### 29 октября: настоящий legacy adoption/rollback в VM

`adopt_legacy` теперь использует тот же global lock/preflight и native Compose
comparison: могут измениться только pinned image и configuration directory mount
Caddy. Private server-local snapshot `.env`, durable pending/current journal,
CAS environment/source проверки; только `up --no-deps --no-build --pull never caddy`.
Секреты не попадают в journal/result/arguments. При ошибке восстанавливаются
исходные dotenv bytes и leaf mount с явным прежним immutable Caddy pin; данные и
Git не откатываются и не удаляются. После process death следующий запуск сначала
восстанавливает старый ingress. Незнакомые изменения среды/source/host блокируют
перезапись, незавершённый recovery остаётся pending. Проверяются volumes, ports,
networks, active semantic config, Git/env hashes, HTTPS обоих сайтов с проверкой
CA и неизменность процессов соседей до/после операции. Идемпотентный committed
retry не пересоздаёт Caddy. **186 infrastructure tests PASS**, включая 9 adoption.

Реальная VM проверка `check_shared_legacy_inspect.py --adopt` прошла все эти
переходы с настоящим Caddy/Docker Compose и synthetic upstreams:
[evidence](three-vps-evidence/2026-10-29-vm-shared-legacy-adopt.json).
Internal CA доверяется только fixture curl через отдельный файл; system trust
не менялся. Все fixture containers/networks/volumes удалены. Production всё ещё
не изменён. Это не shared-front 443 cutover, внешняя ACME issuance, Avito update
manager или full legacy core migration; эти блоки остаются следующими.

### 29 октября: установленный neighboring-deploy manager

`shared_update.py` добавлен в sealed operator package; проверяются ровно три
известных source roster (25/26/27), ready требует актуальный полный target.
`install(...)` после adoption устанавливает только owned wrapper/receipt.
`avito-update` под тем же lock проверяет private runtime, owner/origin/main,
previews native Compose + Caddy validate, journal конкретного fetched revision,
затем known-file restore/fast-forward. Глобального checkout/reset нет. CI/docs-only
не pull/up/reload рабочие службы; Caddy routes reload без process restart;
application changes сохраняют overlay в обычном pull/up. При failed reload
известные routes восстанавливаются, target остаётся pending. Прерванный merge
возобновляется без fetch другого target. Неизвестные edits не перезаписываются.

10 focused manager tests PASS; предыдущий полный regression 194 PASS до последних
двух новых negative cases. Реальный CLI fixture прошёл:
[evidence](three-vps-evidence/2026-10-29-vm-shared-business-update.json).
Исполнен именно установленный `/usr/local/sbin/voicechat-shared-deploy` из sealed
package: Git origin/fast-forward, workflow-only без restart, route header reload
с теми же процессами, process death после настоящего merge и recovery следующей
командой. HTTPS проверен fixture CA, dotenv bytes сохранены, Git clean. Wrapper и
Docker resources удалены; публичные source packages остались. Application image
deploy, shared-front cutover и production этим тестом не приняты.

Первая CLI попытка обнаружила `__pycache__` в sealed package и была отклонена
source-set guard. Wrapper исправлен на `python3 -B`; только повторная успешная
попытка засчитана. Production по-прежнему без изменений, draft Avito workflow не
push/merge. Следующее — проверить обычный application deploy/ошибку reload в VM,
подключить этот защищённый legacy этап на production и продолжить общий cutover/
core adoption/full orchestration/TLS renewal/client release.

GitHub Actions settings доступны через существующую браузерную сессию (read-only).
Production environment имеет прежние DEPLOY_HOST/ROOT/USER/PUBLIC_URL и secrets
DEPLOY_KNOWN_HOSTS/DEPLOY_SSH_KEY. Repository variables/secrets отсутствуют; route
catalog key/config там не настроены. Значения secrets не читались, настройки не
менялись. CI запуск и подготовку public routing config можно выполнить агентом.

Расширенный повтор manager VM fixture тоже PASS:
[полное свидетельство](three-vps-evidence/2026-10-29-vm-shared-business-update-full.json).
После принятого Caddy reload искусственно потерян ответ: прежние routes реально
возвращены, pending сохранён, установленный CLI успешно повторил target.
Настоящий public-image pull и application `up --no-build --pull never --wait`
пересоздали только frontend после изменения его CPU config; остальные процессы
и VoiceChat routes сохранились. Повтор без новой revision ничего не перезапустил.
Это не migration прикладной БД. Failed reload recovery дополнительно отказывается
исполнять Compose при внешнем dotenv/override/source edit. Всего **198 tests PASS**,
включая 12 manager tests. Контролируемый cache неудачной первой CLI пробы удалён
только после проверки content-addressed package hash; public sources сохранены.
Production read-only baseline повторно подтверждён: прежние commits/процессы,
оба HTTPS 200; manager и `/srv/voicechat-managed` ещё отсутствуют.

## Неизменные условия

- Продолжать по `docs/tasks/19-three-vps.md` и `docs/three-vps-spec.md`.
  Последним сообщением 28 октября владелец разрешил также необходимые deploy,
  VPS/DNS/production работы и самостоятельный выбор решений без новых вопросов.
  Прежнее ограничение «только локально» снято. Перед изменениями всё равно нужны
  проверенный host key, actual baseline, согласованный backup и рабочий откат;
  не выкладывать незавершённые role tools и не обходить release guards.
- A хранит все рабочие данные; B/C/D/... — входы и TURN. Добавление входов должно
  доходить до установленных клиентов через подписанный каталог без новой сборки.
- Разрешён начальный один VPS: core A + edge-a на одном physical host; затем
  разнести роли через inventory/deploy. Один хост всё ещё SPOF, не HA.
- Все поддерживаемые клиенты и будущий Windows подчиняются одному контракту.
  Написание Windows-клиента не входит в эту задачу. Внешний backup — после MVP.
- `/ponytail` и AGENTS.md действуют. Не создавать subagents без прямого запроса.
- Историческая исходная ветка `codex/calls-and-message-todos`, baseline
  `bca5b46f582cac1bee080736985950d039b46a0e`; её пользовательские изменения сохранены.
  Текущий worktree — `~/.codex/worktrees/three-vps-rollout/VoiceChat`, ветка
  `codex/three-vps-rollout`, checkpoint `4ca5f3a` плюс описанные выше изменения.
  Сначала прочитать `git status`; не сбрасывать чужие изменения.

## Где остановились

Рабочие реализации и результаты перечислены в `docs/iterations/19-three-vps.md`;
машинные сводки — историческая `three-vps-evidence/2026-10-28-local-checkpoint.json`
и `three-vps-evidence/2026-10-28-role-catalog.json` — исторические снимки;
актуальная следующая сводка: `three-vps-evidence/2026-10-28-single-livekit-tunnel.json`.

Завершены локальные подзадачи:

1. `role_config.py` / `render_roles.py`: самостоятельный edge без business data,
   core через extends существующего Compose, прежние volume names/identity,
   общий источник topology для TURN/CORS. `check_role_config.py` проверяет
   normalization и повторный core configure на одноразовых volumes.
2. `edge_turn.py`: bounded config/permissions, private peer denies, один/два
   TURN secrets. Настоящий coturn проверен на old/new overlap, retirement,
   expired credentials. Смена на A и coordinated multi-host rotation открыты.
3. `route_catalog.verify` / `publish_catalog.py`: signed bytes/identity/time/revision,
   local lock и atomic publication, строгий high-water mark. `--initialize` только
   для нового runtime; нельзя сбрасывать его при release rollback.
4. `check_route_tls.py --role-bundle`: generated edge, TLS/CORS/PROXY/readiness,
   подписанный каталог обновляется без proxy restart; rollback отклонён.
   Private upstream заменён fixture на одном bridge; это не WireGuard proof.
5. `route_io_test.dart` — настоящие loopback socket upload/lost-response проверки;
   `route_file_probe.dart` в native runner — truncated/tampered ciphertext, cache
   eviction и успешный явный повтор. Реальный Synapse upload/download/decrypt через D
   после отказа B/C и reopen профиля прошёл в `voicechat-routes-f908c90ffbbc`.
6. Android updater подключён через `RouteTransport.fork()` для своей installation.
   Ручной выбор копируется в fork без координатора; закрытие fork не закрывает чат.
   Metadata B / APK C проверяют прежний hash и удаление неполного/подменённого APK.
7. macOS updater получает verified route на check/download. `MacUpdateRoute.swift`
   проверяет canonical identity и пути; Sparkle delegates меняют только network URL.
   Signed feed/package guards сохранены. Swift mapper, Flutter bridge и macOS build
   проверены; native Matrix/file probe `voicechat-routes-f8eaeaec9123` прошла.
   Полный цикл реальной установки через B/C остаётся открытым.
8. Topology 1–32; inventory `host: core` для одного co-located edge. Примеры
   `single-vps.example.json` и `single-node-inventory.example.json`. Смена на
   отдельный host требует нового SSH key/generation. Real roles/TLS/Matrix
   probes с одним bootstrap entry прошли, включая discovered C/D и файл через D.
9. `RoutedLiveKitEngine`: awaited route/TURN before SDK resume/full restart,
   сохранение RTC options/Room/key provider, callback lifecycle guard call/screen.
   `mediaIceServers` также подключён к P2P. 47 route/media/call/screen regressions и analyze прошли после WSS feedback.
   Native probe `voicechat-livekit-0ed8730e0724`: 670 ms resume / 339 ms full restart,
   data delivery обоих путей, key provider сохраняется. Audio/video E2EE не доказана.
10. `role_release.py` + тесты: строгий отдельный manifest, полная проверка bundle,
    immutable images, identity/config/source hashes, compatibility и web-only guard.
    CLI требует committed clean source; текущие изменения не коммитились.
    Старому deploy.py эти manifests передавать нельзя; orchestration ещё нет.
11. `tunnel_config.py` + `tunnel-public-keys.example.json`: node-local keys,
    generation-bound public registry, private /32 configs для core/edge/one-host.
    Real kernel proof `voicechat-tunnel-e592e872e49b` прошёл: B/C→A, live B key
    replacement, отказ старому ключу, сохранение A/C, private A с нулём peers.
    51 Python regressions прошли после CI config и bounded JSON reader. Fixture tools image ID есть в evidence.
12. Запрошенная схема уже в `docs/architecture/network-topology.md` (Mermaid).
    В итоговом ответе дать ссылку/показать схему. Она различает API/WSS через WG
    и TURN→публичный SFU A; не рисовать весь медиапуть внутри WireGuard.

13. Все четыре client workflow принимают optional public CLIENT_ROUTE_CONFIG /
    CLIENT_ROUTE_CATALOG_KEY; Android candidate reuse сверяет сохранённый config.
    Только build/candidate: routed publish/deploy закрыт до role orchestration.
    Четыре YAML и 32 shell-шага проверены; Actions не запускались.
14. Coordinator отдельно учитывает реальные Matrix/control/signaling ошибки.
    LiveKit initial connect сообщает network/503, но не auth/rate-limit/pinning;
    CallProbe retry классифицирует эти ошибки. Native WSS-only failure при health B
    200: `voicechat-livekit-d21d703be13d`, resume 398 мс, full restart 265 мс.
    47 Flutter-тестов и analyze прошли. Подробности — итерация 14.

15. `host_preflight.py`: read-only initial clean-host inspection, physical node
    identity, Docker DNAT/socket ports, tunnel/bridge collisions, systemd/NTP/resources.
    Шесть новых unit-тестов и реальный отрицательный Linux collector proof прошли.
    Это не installer/VM bootstrap. Полный Flutter: 319 passed, 3 optional capture
    skipped. Логи final-preflight-tests.log / full-client-regressions.log.

16. `check_route_web.py` и общий test-only route_fixture: 29 Chrome contracts
    прошли, включая banner. Зависание fake clock исправлено tester.runAsync.
    Native изменённые тесты (21, затем 2 banner) и analyze также прошли.
17. Точный web toolchain установлен в .prototype: Rust 1.99.1, nightly-2026-10-24,
    rust-src/wasm target, три pinned crypto tools. build_web_assets.py успешно
    пересобрал vodozemac/E2EE worker/QR assets. Ничего не опубликовано.
    check_route_catalog_web.py + CJS/tool entrypoint: JS release + WASM crypto
    proof PASSED, browser-catalog-js-release.log. Реальный localStorage/page reload,
    discovered D/offline, reject rollback/tamper/expiry/foreign/conflicting revision.
    Не E2EE media или account recovery. CanvasKit test iframe isolation и Dart/Wasm
    bridge decoder оказались неподходящими; финальная проба использует JS build
    и свой loopback server с настоящими COOP/COEP, SDK не меняли.
    Runner требует --flutter и --node, NODE_PATH для существующего Playwright.

18. `tunnel_runtime.py`: atomic private intent, own wg-vc/address/routes apply,
    --resume after interruption/restart; collision/identity/permissions/lock guards.
    6 новых tests; всего 63 infra regressions. Реальный kernel fixture
    voicechat-managed-wg-3aecc890d684 PASSED, tunnel-runtime-native-final.log:
    B replacement/old key denied/C retained/D added, interface recreation,
    persistent-volume container restart, retirement to zero-peer A.
    Первый fixture выявил rekey delay; common renderer now keepalive 25 на обоих
    концах. Это НЕ systemd/full VM reboot/firewall/production proof.

19. Firewall renderer/runtime: scoped INPUT/FORWARD, conntrack original ports,
    peer/source ACL и запрет WG transit; co-located web/health/relay разделены.
    Atomic desired state/lock вынесены в managed_state.py для WG/firewall.
    76 infra tests passed; kernel firewall c12e424a3ece, repeated WG 1e81209070d4,
    TLS role 645435c3e90b и core config 1a8552851834 прошли/очищены.
    Нужны boot ordering/packages, IPv6/secondary binds/provider ACL и rollout.
    Из failed fixture осталась пустая Docker network
    voicechat-firewall-61bd4566a853_local (active endpoints, disconnect not found);
    не рестартовать Docker/чужие проекты ради очистки. Финальный harness исправлен.

20. Core IPv4 media bind и stable core bridge закрывают alternate-address/direct
    container-IP обходы. Final firewall d70f6a89fd35 и role ba713a730ba7 прошли.
    network_runtime.py координирует FW→WG из общего intent, в т.ч. crash между ними.
    80 infra tests; real combined network 59f4c47ec578 прошёл/очищен.
    systemd unit+Docker drop-in проверены systemd-analyze 252, missing state и
    dependency cycle; это не actual VM boot/installer. Network files входят в
    role manifests. tools image e2ac5ac00e116d277e0e41bebb580bee5dd8836c8ec2b8ab5a4b5b71e81ff83f.

21. host_connection.py: verified-only Ed25519 SSH, own temporary known_hosts,
    safe argv/stdin, no inherited config/multiplexing/agent forwarding. 3 tests +
    real OpenSSH fixture f371de388b81 passed (including server key replacement),
    cleaned. New tools image 1777dd22a8397fbc30730d03924dfffd770ad59f11a0fb53ee1820d8a656a477.
    network_bootstrap.py: prepared-host immutable code/unit installer, receipt
    resume, foreign-file guards, verify/enable/start, no Docker restart; 4 tests.
    Total 87 infrastructure tests passed. Actual VM install/boot still untested;
    package installation/full SSH orchestration/TLS/release upgrade remain.

22. Дополнительный regression воспроизвёл SFU-originated UDP reply bypass и
    исправлен: reply-direction media ACL также требует edge source. Final
    firewall 18f116093cb1 прошёл, в т.ч. co-located relay/retired B. Core namespace
    reserved ports исключают ephemeral DNS/client collision; kernel bind proof
    и role 36200cb78267 passed/cleaned. Host sysctls не менялись.

23. DuckDNS сохраняем по явному решению владельца; свой домен/Cloudflare DNS only
    записаны отдельной невыполненной целевой задачей V3-T04. tls_material.py
    проверяет chain/key/SAN/срок, immutable stage; 5 OpenSSL tests. Role TLS
    5e605f23ed78 прошёл/очищен. acme.py: centralized locked lego issuance/renewal,
    pinned 5.5.2 digest, token file, inflight guard, 6 injected failure tests.
    Actual CLI проверен в network none, fake token, clean; **не issuance proof**.
    Никаких DNS API вызовов/настоящих сертификатов без разрешения внешних изменений.

24. 98 инфраструктурных tests passed. TLS renewal/rollback fixture fd60e4e81b97
    прошёл/очищен: symlink внутри стабильного bind, SIGUSR1 Caddy2.11.7/SIGUSR2
    coturn, новые handshakes + existing TURN allocation, без container restart.
    Первый ed9db98c20d7 обнаружил закрытие idle HTTP на reload (ожидаемый drain);
    свежий HTTPS работает, непрерывность WSS/реального звонка ещё не доказана.
    Production TLS activation/publisher пока не реализован — только test fixture.

25. После этого добавлен рабочий disk publisher tls_runtime.py: atomic generation
    pointer внутри стабильного mount, persisted prepared/selected intent, resume,
    tamper/foreign guards, root:10001 0640 TURN keys. 5 tests и Linux UID proof
    прошли, общий инфраструктурный прогон 103 tests passed. Это ещё не общий
    deploy lock/reload/health/scheduler. Test harness ограничивает subprocess
    process groups по timeout (2 дополнительных теста прошли); Compose serial.
    Локальный Docker стал задерживать create/run: 149c6518426f остановлен точечно,
    очищен; 5718556d4df8/4958c7bee861 helper timeout, production не затронут.

26. Владелец затем разрешил VPS/DNS/deploy (см. условия выше). Read-only SSH по
    сохранённому Ed25519 key прошёл: root@84.200.80.13, ~/.ssh/id_ed25519,
    StrictHostKeyChecking=yes. Фактический production 8bcbd91b578fa7bc4dfe58a1f740980248fac1c9,
    Ubuntu24.04.5 amd64, Docker29.8.1/Compose5.5.1, рядом работает avito-helper.
    Требуется отдельный migration существующего Ubuntu host; не применять
    clean Debian12 bootstrap и не менять соседние службы. main GitHub
    2cca4d3ac7ffdb2355a39302f8fe93ec747e8b8d отличается от production только docs.
    GitHub SSH доступ есть, gh CLI отсутствует, remotes в checkout не настроены.
    Оба commit уже есть локально. Baseline/capacity сохранены приватно в
    .prototype/three-vps/production-{baseline,capacity}.json.
    Создан отдельный приватный /srv/voicechat-lab/three-vps-20261028-93e52467dd,
    туда переданы только source/public fixtures (151 файл), без runtime secrets.
    Сейчас там запущен TLS role probe (SSH exec session 85575), лог tls-role.log.
    Проверить завершение/cleanup/неизменность production. Fixture CPU/memory bounded,
    ingress только loopback, synthetic CA, host routes исключены из выбора subnet.
    Ни release, ни DNS ещё не изменялись; создание lab directory — уже изменение VPS.

Следующие крупные части: V3-07/08 полный bootstrap и TLS activation/scheduler,
V3-19/20 role release workflow/guarded deploy; V3-04/15/16 real app media/lease.
До изменения deployment читать `infra/deploy.py`, `release_source.py`, тесты и
`infra/THREE_VPS.md`. Не передавать новые role bundles старому deploy.py;
не ослаблять baseline/backup guards. Production baseline считана; см. факты в начале этого файла.

## Важные незавершённые части

- LiveKit adapter теперь покрывает живой reconnect. Он использует Engine injection
  и внутренние API закреплённого SDK 2.13.1; при обновлении SDK повторять probes.
  Сам `.pub-cache` не правили. Call/screen авторизацию по-прежнему ведут владельцы.
- Browser TURN proof использует синтетический звук и DTLS-SRTP; это не приёмка
  E2EE звонка приложения. TLS proof проверяет binding, auth/allocation/permission
  и TURN secret rotation, но не TURN/TLS audio.
- Не пройдены Android/web/внешние сети, реальные 443/firewall, call/screen E2EE,
  полная цель 15 секунд и lease/revocation под отказами.
- Основные upload/download fault cases проверены локально; открыты все размеры,
  avatars/links/платформы, остальные сетевые потребители (push, canonical
  links), динамические каталоги во всех web/native cache сценариях.
  Updater routing подготовлен для Android/macOS; настоящая установка с отказом
  entry ещё не принята. Snapshot маршрута не меняет уже начатый transfer.
- Подготовлены ACME issuance/renewal controller и TLS staging, но нет проверенной
  внешней issuance/renewal, scheduler и безопасной активации работающих служб.
  Нет полного host bootstrap, новых deploy
  scopes/pointers/rollback и полного replacement старого VPS. WireGuard renderer/
  keys/real kernel proof и role manifest уже есть; это не завершённый rollout.
  WireGuard syncconf должен включать PrivateKey (иначе может очистить ключ);
  изменение peers не меняет маршруты /32 автоматически. Atomic runtime persistence и revoke/routes уже проверены в отдельном Linux fixture;
  systemd, firewall/SSH orchestration и полная reboot VM acceptance ещё нужны.
- Замена hostname/IP не решает потерю единственного A. Внешний backup пока не сделан.
- Срок подписанного каталога максимум 30 дней; offline cache сохраняет ранее
  известные маршруты после истечения, но новый просроченный документ не принимается.
  Нужен эксплуатационный выпуск новых revision. Хотя бы один известный адрес должен
  оставаться доступен. Приватный signing key нельзя хранить на edge.
- Multi-route build config подключён к четырём workflow; routed production deploy
  и Android publish закрыты явным gate до role orchestration. Без variables
  сохраняется single-host режим. Production baseline считана (см. текущую рабочую копию выше); новый релиз не собран.

## Проверенные команды

Из корня репозитория, с уже установленными зависимостями:

```sh
PYTHONPATH=prototype:infra python3 -m unittest test_tunnel_config test_role_release test_route_catalog test_role_config test_node_inventory test_edge_config test_topology test_route_health test_three_vps test_deployment test_supervisor
PYTHONPATH=prototype:infra python3 -m unittest test_macos_update_route test_macos_release
python3 prototype/check_role_config.py
python3 prototype/check_route_tls.py --role-bundle
CARGO_HOME="$PWD/.prototype/cargo" RUSTUP_HOME="$PWD/.prototype/rustup" RUSTUP_TOOLCHAIN=stable PATH="$PWD/.prototype/cargo/bin:$PATH" python3 prototype/check_three_vps.py --flutter .prototype/tools/flutter/bin/flutter
CARGO_HOME="$PWD/.prototype/cargo" RUSTUP_HOME="$PWD/.prototype/rustup" RUSTUP_TOOLCHAIN=stable PATH="$PWD/.prototype/cargo/bin:$PATH" python3 prototype/check_route_livekit.py --flutter .prototype/tools/flutter/bin/flutter
docker build -f prototype/tunnel.Dockerfile -t voicechat-tunnel-probe:local .
docker image inspect --format '{{.Id}}' voicechat-tunnel-probe:local
python3 prototype/check_tunnel_config.py --tools-image sha256:RESOLVED_LOCAL_IMAGE_ID
```

Flutter из `apps/client`:

```sh
../../.prototype/tools/flutter/bin/flutter analyze
../../.prototype/tools/flutter/bin/flutter test --no-pub test/routed_livekit_engine_test.dart test/media_routes_test.dart test/media_routes_io_test.dart test/p2p_service_test.dart test/p2p_protocol_test.dart test/p2p_export_test.dart test/call_cleanup_test.dart test/call_key_sharing_test.dart test/direct_call_media_test.dart test/screen_protocol_test.dart test/screen_lifecycle_test.dart
../../.prototype/tools/flutter/bin/flutter test --no-pub test/app_update_test.dart test/macos_update_test.dart test/route_io_test.dart test/route_transport_test.dart test/route_coordinator_test.dart
../../.prototype/tools/flutter/bin/flutter test --no-pub test/route_io_test.dart test/route_transport_test.dart test/route_coordinator_test.dart test/route_status_banner_test.dart test/media_routes_test.dart test/session_preservation_test.dart test/call_cleanup_test.dart test/call_key_sharing_test.dart test/direct_call_media_test.dart test/screen_protocol_test.dart test/screen_lifecycle_test.dart test/chat_actions_test.dart
```

Native runner требует macOS/Xcode/Docker; он создаёт случайный Compose-проект,
синтетический профиль и удаляет только их. Логи в `.prototype/three-vps/` приватны.
Не перезапускать существующий `voicechat-prototype` ради этих проверок.
Flutter 3.47.7 / Dart 3.13.5; фактический Rust `stable` в данном runtime — 1.99.1.
Runner использует `en_US.UTF-8`, необходимый при холодном CocoaPods install;
`C` годился только для ранее закешированной сборки, `C.UTF-8` отсутствует на macOS.
Проверять версии по `infra/crypto-tools.json`, не заменять датированный web nightly
произвольным stable. Полный production build здесь не нужен.
