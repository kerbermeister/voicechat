# Точка продолжения: три и более VPS

## Актуальная сводка: production core/edge включены

**LATEST: core-only source guard candidate implemented, НЕ production.**
БылоREDregression, теперь129managed+9release/source+6transport PASS; all668
PASS/skipped3,77.252s (`.prototype/all-python-tests-core-source-guard.log`).
`release_source.core_scope_fingerprint`: прежний backend hash побайтносовместим
(проверенoldGit463eed4→7f5751…). Новыйcore-scope.sha256 исключаеттолькоcoreapp
allowlist+prototype/test_*.py; unknown/shared/edge/workflow/vendor защищены.
Artifact unpack/verify/cleanGit связываютguard сметаданными; full→baseline schema2,
core backend delta requires matching guard; schema1history readable, missingguard
requiresfull. Journal/control next_baseline helper, probe/SSH/CI propagation done.
Нужны commit clean source, public package checks, новая real normal VM проверка:
full1→2/lostreply, web/core scopes, core-only protected testfile backenddelta сsameguard,
отказ core приcommentchangeedge_deploy.py БЕЗ fences/processchanges, badfull rollback.
Parent/driver можно адаптировать из `/tmp/voicechat-managed-normal-{vm,driver}.py`
под managed-guard names, сохранив старыеlogs/records. Source core-scope metadata
добавить в каждую fixture archive; frozen initial backend остаётся base, core testfile
меняет backend только в private Git clone, не runtime. Не менять mainVM WGprivatekey/
двастарыхтома. HostprepareVM network/key готовы; всёVPSreadonlyпослеfull53.

**LATEST 30.10 03:40local: producer54/55 и postchecks PASS; core-only guard audit открыт.**
[Web55 proof](three-vps-evidence/2026-10-30-ci-managed-web-build-only.json): SUCCESS11m,
job10m55, artifact12949243943 ZIP SHA7cc2913c…, downloaded exactGit463eed4,
sourcearchive179306ee…, backend7f5751…production, control ee3d5d reused.
[Postcheck55 PASS](three-vps-evidence/2026-10-30-production-web-build-only-postcheck.json):
все role processes равны full53 releasing proofs, neighbor6/data/pointers/timers/feed
unchanged. VPS по-прежнему2dae758; ни54, ни55 не делали deploy.

При проверке source guards найден пробел core scope: сравнение только generated
edge bundle не ловит изменения operator scripts, не включённых в manifest.files.
Новый regression `test_core_protected_source_change_requires_a_recorded_non_core_guard`
в `test_managed_release.py` закономерно RED (19tests,1failure), log
`.prototype/core-source-guard-regression.log`. В production core-only не выполнялся.
Следующий приоритет — устранить пробел: отдельный non-core protected fingerprint,
сохранив backend fingerprint без ослабления. Core-only с backend delta допустим
лишь при совпадающем записанном guard; старой baseline без guard нужен full.
План: generated core-scope.sha256 в verified artifact, baseline schema2 core_guard,
backward read schema1, target helper в managed_release; propagate journal/control/
read-only probe/SSH + CI tar/source verification + tests. Full сохраняет новыйguard,
web/edge сохраняют его; missing guard не разрешает новый backend delta. Никаких
ручных правок production baselines/digests. Перед новой live full нужны regression
suite, immutable package checks и реальная VM проверка schema1→2/scopes.

Mesh VM только исследована, НЕ запущена/изменена: QEMU official docs подтверждают
loopback multicast L2 netdev socket mcast/localaddr. Mac16GiB. MainVM4GiB и prepareVM1.5GiB
живы, packageVMoff; для будущего3VMстенда нужен тщательный memory budget и сохранение
оригинальных WG keys/двухстарыхтомов. Не менять main network без saved/verified restore.

**LATEST: unified SSH bootstrap repeat source3a8bf19 PASS.**
HEAD/origin3a8bf192f5e134667f2311e2c57fe5b72ee5bb8c;43 host tests PASS.
[Proof](three-vps-evidence/2026-10-30-vm-unified-host-bootstrap.json), exec83402 exit0:
один pinned connection/frozen source на dependency→key→network, repeat receipts equal,
private key stays local, owned boot exact, Docker not restarted, original VM records
unchanged. Это repeat на уже подготовленном peerless узле, не новая initial install.
Production остаётся2dae/full53; никакого live rollout сейчас нет. Webbuild-only55active.
Next functional work: новый edge role/TLS readiness и coordinated live peer/catalog
lifecycle, safe replacement без доступа к old host; затем доступный core transfer.

**ACTIVE 30.10 03:19local: web build-only55, без деплоя.**
https://github.com/kerbermeister/voicechat/actions/runs/40990964885,
job123853000739. Отдельная ветка `codex/three-vps-web-build-check`,
source463eed4d9aff74d313880305cdbeea59ec8fcdbb (ровно docs-only commit поверхproduction2dae).
Protected fingerprint7f5751… равенproduction; control должен reuseee3d5d… .
Inputs managed/web/deploy=false, retryfalse, edgesempty — провереныUIдоRun.
Не запускать deploy на этой проверочной ветке. Получить SUCCESS, скачатьсвойartifact
черезUIи сверить ZIP SHA, source receipt с clean Git, reusedcontrol. Потом один
read-only production postcheck (как54), без повторного запуска сервисов.
Local checkout/metadata `.prototype/web-producer-check.json` (tmpvoicechat-web-producer-a4sas727).
Основная ветка локально c532074 (docs/proofs), origin a8060f4; ничего не терять/reset.
Реальныеhostnetwork20841 иreboot49274 exit0; всеjobsVMзавершены, prepareVMвключена.

**LATEST 30.10 03:14local: core build-only54 и new-host network component PASS.**
HEAD/origin a8060f416177732387f5df1d1a0dbc4a1530005a; production всё ещё2dae758.
[CI54](three-vps-evidence/2026-10-30-ci-managed-core-build-only.json) SUCCESS7m32,
job7m27; actual downloaded ZIP SHA0f834740…/artifact12948069554 проверен,
source archive32effdaf… exact clean-Git fea4b06, web6dcb6 reused from53. Web/crypto
build и все deploy steps skipped. [Production read-only postcheck PASS](three-vps-evidence/2026-10-30-production-core-build-only-postcheck.json):
все core/edge IDs/StartedAt/RestartCount равны releasing proofs full53; neighbor6,
data identity, pointers, timers и Mac24 feed unchanged. Никакого deploy54 не было.

New host network wrapper a8060f4: actual pinned SSH VM20841 exit0; VM reboot49274
exit0. [Proof](three-vps-evidence/2026-10-30-vm-host-network-bootstrap.json): peerless WG/firewall,
boot exact, repeat без Docker restart; после reboot network ready BEFORE Docker,
private key bytes/identity receipt preserved. VM prepare-host-6c9b07e8b0 сейчас
включена, уже имеет managed peerless network. Не считать её чистой VM.0containers.
Original main VM и off package VM не тронуты.Все41 host tests PASS; полный646
был до12 новых registration/network tests. Новая CI наa806 включает новый набор;
получить её итог. Source wrappers passive, клиент/native не менялся; Mac24актуален.
Далее: новый edge onboarding и coordinated topology/network/catalog lifecycle.

**LATEST 30.10: новый SSH host preparation / identity component проверен.**
HEAD/origin `fea4b0624994693d9bd91fcebf9c7efcdf7070a1`; production остаётся2dae758.
Host prepare доставляет clean-Git bundle, устанавливает зависимости и опционально
создаёт generation-bound WG key на узле. Fresh VM `prepare-host-6c9b07e8b0`,
SSH53689/PID16693: install56615 exit0 (sourcea4e564), key init10372 exit0 и actual
host_connection flags/NAT14393 exit0 (sourcefea4b06); reboot40148 тоже завершил
assertions PASS; exec completion получить при следующем poll. [Proof](three-vps-evidence/2026-10-30-vm-host-prepare-identity.json).
VM record `.prototype/vm/prepare-active.json`, wrapper `.prototype/prepare-vm-exec.py`;
узел пока включён, без containers/network intent, ключ только наVM. Старые main/package
VM records неизменны. Логи `.prototype/prepare-{ssh-vm,identity-ssh-vm,pinned-ssh-vm}.log`
и `.prototype/prepare-identity-reboot.log`. Общий suite646 PASS/skipped3,76.76s;
добавленный затем public registry validator:6 focused PASS, все35 host tests PASS.
Uncommitted `host_registration.py`/tests и docs — завершить review/commit.
Build and deploy54 core/build-only (`deploy=false`, managed, retryfalse, edgesempty)
https://github.com/kerbermeister/voicechat/actions/runs/40989121027,
job123846993734, sourcefea4b06, начат03:00local, ACTIVE. Managed hints read PASS;
выполняются обычные server/client tests, core image build и source artifact ещё впереди. VPS mutations в новом run запрещены
выбранным deploy=false. Он проверяет actual managed hints и reuse web digest.
Продолжить onboarding/network registration/activation; полный lifecycle ещё открыт.

**PRODUCTION FULL53 SUCCESS, 30.10 02:19 local.**
[Run53](https://github.com/kerbermeister/voicechat/actions/runs/40983391788),
source `2dae7580c6b229dcd8c804a4efac21055230a6cc`, managed/full/deploy=true.
Длительность 14m33s; сам deploy 2m57s. Независимый read-only postcheck PASS:
[свидетельство](three-vps-evidence/2026-10-30-production-managed-full.json).
Core/edge baselines, immutable digests и source receipts совпадают с кандидатом;
PG/signing identity сохранены, previous указывает на initial24. Блокировки сняты,
released audit receipt сохранён штатно. Шесть общих/соседних процессов не меняли
ID/StartedAt/RestartCount; backup/TLS timers active/enabled, HTTPS checks PASS,
macOS24 feed неизменен. Первый запуск проверяющего скрипта ошибочно ожидал удаления
released audit receipt; исправлен только checker, повтор PASS, сервер не менялся.
Backend fingerprint `7f5751bb6df936a45b95fe8e84f3b687e1a1f0773e2cfe3af62433655b0003e6`.
CI97 push и CI98 PR того же source SUCCESS. Production jobs сейчас завершены.

Физический VPS по-прежнему один: core + edge-a. Полная автоматизация подключения
нового хоста, replacement/core transfer и реальные аппаратные/media проверки ещё
не завершены. Host-local package preparation уже прошла чистую Debian VM и reboot;
следующий шаг — доставлять её штатно через pinned SSH и проверенный source bundle.
Mac rebuild не нужен: клиент/native/vendor относительно опубликованного24 не менялись.
Основная fixture VM: 0 контейнеров, два старых тома и исходный WG key сохранены;
package VM выключена, disk/keys/restart argv сохранены. Старые блоки ниже — история,
не команды повторить уже завершённые jobs.


**LATEST 30.10,01:58local: NORMAL FUNCTIONAL SCOPES COMPLETE, CLEANUP RECOVERED.**
Driver60962 exit0: full/lostreply, web/core process isolation, bad full/outerrollback
PASS. Parent80589 exit1 на line18 volume-set assertion; network-byte equalityline17
уже PASS, child independently verified account/device/data/identity/fences/neighbors.
Был1 orphan coturn volume b87c4bcc… (created23:29:39UTC внутри fixture): его69KiB
SQLite побайтно равен unstarted pinned image seed. Probe79581 exit0; private tar
сохранён `/srv/voicechat-edge-fixture/retained-seed-volume-b87`. Recovery58278 exit0:
только этот unreferenced exactseed том удалён; old2 metadata unchanged, original
network fingerprintb8ceb4… restored/key unchanged,0containers,systemd running.
[Combined scopes proof](three-vps-evidence/2026-10-30-vm-managed-scopes.json),
[cleanup recovery](three-vps-evidence/2026-10-30-vm-managed-cleanup-recovery.json).
Нельзя переписать исходный parent как exit0: он остаётся явно записанным exit1.
Fixture-only fix: capture verified TURN mount ID до managedwait + private receipt,
shared with existing fault capture;4 focused/39 initial tests PASS. Runtime unchanged.
Все VM test jobs завершены; основной QEMU жив, исходная peerless network активна.

CI95/96 87a4a9e SUCCESS; full source package87 verified cleanGit (101files/10KBreceipt).
Следующий commit включает только fixture fix и docs/evidence поверх87; ordinary
runtime всё ещё идентиченD0, package module exactVM tested87. План: commit/push,
сразу штатный GitHub managed/full/deploy=true; его server/client checks перед deploy
проверят новый candidate. Ненужный отдельный Android artifact job не меняет scope full.
VPS строго read-only snapshot подтвердил24c42bf, no rollout.json,32GiB free, backupidle;
[before normal](three-vps-evidence/2026-10-30-production-before-normal.json) сохраняет
sharedfront+Caddy+neighbor4 IDs. Postcheck script принимает exactcommit argv и
сверяет все6 процессов, PG/signing identity, previousinitial24, release digests иMac24feed.
Не запускать initial, не трогать старые2VMтома, archivecoturnseed не экспортировать.


**LATEST 30.10,01:18 local:** HEAD/origin `87a4a9eb73099fcfc745c37c4e57db3034b264a1`,
новый общий кандидат; before this edit git clean. Backend fingerprint
`820b8e178621c86e40f506ff3af3aa0052cd8962d5081a59c6fe57700e0c66cd`.
CI95 push https://github.com/kerbermeister/voicechat/actions/runs/40978202914
(job123811375572), CI96 PR https://github.com/kerbermeister/voicechat/actions/runs/40978207688
ещё running. CI93+94 D0 PASS; release build-only52 D0 SUCCESS, deploy=false.
PR5 draft attached; main unchanged; production STILL24c42bf initial51.
Никаких live VPS mutations в этой итерации не было.

Normal VM parent80589/driver60962 ACTIVE, sources/roots прежние awmnrf_u/ghyq2y5a.
Уже actual full+lost-reply, web-only(core ID/StartedAt/RestartCount unchanged),
core-only(edge processes unchanged) PASS. Последний bad full: core applied,
edge intentionally failing; outer rollback/data assertions и parent cleanup ещё нужны.
Не запускать production full пока BOTH driver+parent не PASS. Ready timeout7200s
примерно с00:34local; parent timeout9000 с00:14. Не стартовать дубликат.

Package VM2 test16157/reboot50488/stop92779 all exit0. VM2 powered off, disk/key
retained; restart_argv в package-active.json. Proof committed87a4a9e. 632 unit tests
PASS/skipped3 +7 release-source focused PASS. Exact host_packages/harness hashes
совпали с realVM proof. Source archive validation87 PASS:101 files,243813 bytes,
receipt10130 bytes; synthetic image digests (только source test, не Docker build).
Runtime/workflow diff87 vsD0 отсутствует, кроме нового passive host_packages.py
и runbook; executable ordinary release файлы идентичны проверяемомуD0.

После VM/CI: выполнить GitHub Build and deploy `rollout=managed,mode=full,deploy=true`
на87a4a9e (или docs-only successor с тем же runtime), retry flagsfalse, edges empty.
Не повторять initial51 и не двигать codex/three-vps-initial24. Postcheck готов:
`python3 /tmp/voicechat-production-normal-postcheck.py <exact-40-char-commit>`;
он ещё не запускался и ожидает previous initial24, исходные PG/signing identity,
neighbor4 unchanged, Mac24 feed unchanged. Нового macOS build не требуется.


**НОВЫЙ КАНДИДАТ ДЛЯ ПЕРВОГО normal production full:** проверенный host_packages
компонент включается в следующий общий commit до production. Ordinary runtime/
workflow файлы относительноd0cf533 не меняются; normal VM всё ещё проверяет именно
их в clean cloneD0. Новый package-модуль отдельно прошёл real clean VM/reboot и632
unit suite. Не делать сначала отдельный D0 production full: планируется один
full из нового проверенного commit после normal bad-full rollback PASS и CI.
Postcheck `/tmp/voicechat-production-normal-postcheck.py` обновляется на exact commit
аргументом. Source branch codex/three-vps-initial24 остаётся нетронутой.
Package VM2 штатно выключена, диск/ключи сохранены; package-active.json содержит
powered_off=true и restart_argv. [Package/reboot proof](three-vps-evidence/2026-10-30-vm-host-packages.json).
Normal full/lost-reply, web-only (core unchanged), core-only (edge unchanged) уже PASS;
остался bad full + outer rollback + parent cleanup.

**Новый локальный regression PASS:**632 tests/skipped3,103.617s, включая8
host_packages checks (17 host tests суммарно). Bootstrap-код ещё untracked/не опубликован.
VM2 real test session16157, launcher `/tmp/voicechat-package-vm-test.py`, log
`.prototype/package-vm-test.log`, marked root `/srv/voicechat-package-fixture-35bb6bc4fe`.
Источник/harness staged из локальных public .py; VM2 уже прошла настоящий base apt,
внедрён lost reply, возобновила intent и выполняет Docker apt (pending phase=docker,
4 planned packages). Не прерывать dpkg. Evidence `.prototype/package-vm-evidence.json`
появится только после всех assertions и адресной очистки probe nft table.
Normal driver: full+lost-reply PASS; web-only releasing, core/bad-full ещё впереди.

**ПАРАЛЛЕЛЬНО, package bootstrap кандидат (ещё НЕ опубликован):** untracked
`infra/host_packages.py` + `prototype/test_host_packages.py`;16 host tests PASS,
в том числе7 новых package tests. Pinned Debian12 amd64 dependencies взяты из
проверенной VM, official Docker key SHA1500c1f…a570. Журнал apt closure, запрет
чужого Docker/runtime/repository/unfinished dpkg/container data, identity/profile
binding; completed repeat/lost commit reply не запускает apt. Active nftables
unit сохраняется через отказ, не stop/restart: exact1.0.6-2+deb12u2 postinst наVM
новую службу не стартует, при upgrade делает try-restart. Настоящий package install
ещё не выполнен. Чистый VM2 запущен: package-host-35bb6bc4fe, SSH57373, PID11153,
1CPU/1536MiB/nice19; **отдельный** `.prototype/vm/package-active.json` и wrapper
`.prototype/package-vm-exec.py`. Original active.json и vm-exec.py не менять.
Launcher `.prototype/start-package-vm.py`; base image SHA512 проверен до запуска.
Историческое ограничение D0 production superseded сводкой выше: публикуем проверенный
package-компонент тем же первым normal full. Run52/normal fixture остаются замороженыD0.

**Build and deploy52 SUCCESS**,8m51s ([proof](three-vps-evidence/2026-10-30-managed-build-only52.json)), artifact12942511756; deploy=false, production unchanged.

История запуска: **30.10 00:39 local: Build and deploy52 ЗАПУЩЕН**, run40974631683,
job123799520717, d0cf533, rollout=managed/mode=full/**deploy=false**,
retry flags=false, edges empty. Проверка новой build pipeline без SSH/deploy;
не путать общий GitHub environment label с фактическим обновлением A.
Production всё ещё24c42bf. Не запускать production пока normal VM proof не завершён.
VM initial завершён: ready `/srv/voicechat-edge-fixture/cohost-fixture-ghyq2y5a/managed`;
driver60962 уже прошёл fencing core/edge-a и выполняет apply core.
Подготовлен read-only postrelease checker `/tmp/voicechat-production-normal-postcheck.py`
(ещё не выполнялся; ожидает exact d0cf533 full commit и unchanged Mac24 feed/neighbor).

Draft PR создан и прикреплён к чату: https://github.com/kerbermeister/voicechat/pull/5.
Merge не выполнялся; описание явно сохраняет открытые bootstrap/replacement/core-transfer/media проверки.

**АКТУАЛЬНО, 30.10, commit d0cf533:** один активный parent session80589
`/tmp/voicechat-managed-normal-vm.py` и один driver session60962
`/tmp/voicechat-managed-normal-driver.py`. VM source
`/srv/voicechat-edge-fixture/managed-normal-source-awmnrf_u`, local logs
`.prototype/vm-managed-normal.log` и `.prototype/managed-normal-driver.log`.
Новый fixture использует sibling nonnested roots; старые попытки ниже — история.
Не запускать дубликаты и не использовать старый ready. Clean clone/commit/backend
в `.prototype/managed-normal-run.json`. Обычный production deploy ещё не запускался.
Ветка d0cf533 отправлена в GitHub; Prototype checks93 run40972369775 запущен,
[результат SUCCESS](three-vps-evidence/2026-10-30-managed-ci93.json),11m55s. Production остаётся24c42bf (initial51), Mac24 опубликован.


**ПЕРЕД СЛЕДУЮЩИМ RETRY, 30.10 local:** parent19475 завершён, driver29758 упал на
первом coordinator status **до begin/fences**. Причина — старый fixture создавал
managed/shared внутри legacy root, тогда как normal journal и initial SSH entry
требуют distinct nonnested roots; production /srv roots уже соответствуют этому
контракту. Initial lower-level target_for теперь также отклоняет nesting (новый
regression PASS). Fixture создаёт отдельный cohost-fixture-* sibling и проверяет
реальный initial_entry.request до cutover. Mac driver assert обновлён на этот prefix.
34 initial tests +3 cleanup regressions PASS; полный набор620 ранее PASS, новый
focused shared transport15 тоже PASS. Не ослаблять normal baseline validator.

При cleanup обнаружен второй test-only нюанс: reset-failed inactive/not-loaded
service возвращает error. Теперь reset выполняется **только** при ActiveState=failed;
owned unit bytes всё равно проверяются до stop. Это закреплено отдельным regression.
После остановки nested fixture применён guarded cleanup старых known models,
legacy public pointer прочитан штатным legacy parser (0644 допустим для legacy,
не менять private managed_state boundary). [Recovery PASS](three-vps-evidence/2026-10-30-vm-normal-layout-recovery.json):
все owned units/containers убраны, legacy anonymous volumes удалены только по
original receipt, synthetic CA снята, original private network/key восстановлены,
systemd running. Recovery scripts `/tmp/voicechat-recover-normal-vm-owned.py` и
`/tmp/voicechat-finish-normal-vm-recovery.py`, последний session21631 exit0.

**Активных VM/production jobs сейчас нет.** Следующий шаг: commit текущего diff,
повторить один `/tmp/voicechat-managed-normal-vm.py`, затем один driver. Старый
ready.json относится к g0y48bb9, не запускать driver до нового source/run.json.
Production остаётся24c42bf, только read-only проверки; signed Mac24 уже установлен.


**АКТИВНО: retry676613e, 29.10 22:42 UTC.** Parent session19475
`/tmp/voicechat-managed-normal-vm.py`, source
`/srv/voicechat-edge-fixture/managed-normal-source-7vcoa1mv`, log
`.prototype/vm-managed-normal.log`. Driver session29758
`/tmp/voicechat-managed-normal-driver.py`, log `.prototype/managed-normal-driver.log`.
Он ждёт ready после первоначальной migration; в source log уже прошёл consistent
backup. Новый clone676 и fingerprint — `.prototype/managed-normal-run.json`.
Не запускать ещё один parent/driver. Старые50323/76852 завершены/остановлены, recovery
оригинальной сети успешно выполнен до retry. Новый сценарий дополнен real core-only
с проверкой неизменных edge PID, а bad full использует отдельный temporary Git commit,
чтобы core действительно обновился/сделал snapshot перед отказом edge.

После676 локально сокращено дублирование SSH: `managed_ssh` переиспользует
`host_connection.connection`, прежний execute/argv API сохранён; host pin + node ID
сверяются с inventory, отдельные identity maps остаются. Три старых SSH теста и12
managed SSH tests PASS. Реальный strictly read-only запрос к A через общий transport
вернул идентичные build hints ([proof](three-vps-evidence/2026-10-29-production-managed-shared-ssh.json)).
Runtime/native source не менялся; production всё ещё24c42bf, no normal deploy.
Обновляются operator runbooks; Git status может содержать docs + shared transport diff.


**Следующее продолжение после53e15b8 (29.10, 22:22 UTC):** production всё ещё24c42bf,
новых mutations нет. [Read-only CI hints на A PASS](three-vps-evidence/2026-10-29-production-managed-build-hints.json):
один edge-a, pending=null, точные immutable control/web digests. Это не runtime/media proof.
Локально подключены workflow managed/full/web/core/edge, per-node private SSH key map,
resume-only до сборки и standalone bounded read-only probe. Web/edge reuse control,
core reuse каждого deployed edge web; core не строит web/crypto assets. Все прежние
server/client checks сохранены. YAML/bash/embedded Python syntax PASS, 26 steps.
Functional workflow tests проверили generated manifests и private distinct key files.
Полная regression **620 PASS/skipped3**,70.420s; focused managed124 PASS,29.268s.
Diff относительно production24c42bf серверный/infra; macOS/native source относительно
опубликованного9d4 не менялся, повторная сборка macOS не требуется.

Сквозной parent50323 завершился **FAILED до normal SSH**, stage initial network install:
после предыдущего core fixture в PID1 осталась только `voicechat-core.service`
not-found/failed; healthy-systemd guard правильно запретил установку. Driver76852
ждал ready и остановлен агентом (PID4326/SIGTERM), normal mutations не начинал.
[Recovery PASS](three-vps-evidence/2026-10-29-vm-normal-bootstrap-recovery.json):
только эта проверенная удалённая owned unit reset-failed, исходные private network/key
bytes сохранены, штатный network_bootstrap restore по saved fingerprint завершён,
network service ready, containers отсутствуют. Не ослаблять systemd guard.
Fixture cleanup теперь reset-failed только проверенных owned units, precheck SystemState
перед созданием ресурсов; parent/driver надо повторить из нового чистого commit.
Старый source `/srv/voicechat-edge-fixture/managed-normal-source-fp3o70nm`, receipt
`/srv/voicechat-edge-fixture/legacy-preflight-3vswjehd/network-isolation.json` restored.
Старый clone53 и логи оставлены как forensic; не использовать старый run.json после
нового запуска. Сценарий `/tmp/voicechat-managed-normal-driver.py` дополнен настоящим
core-only/неизменными edge PID и fail-fast при отказе parent. Следующий retry проверит
full+lost reply, web-only, core-only и реальный bad web/full rollback.

Preflight теперь готовит immutable sources и скачивает все образы до первого fence,
не меняя app/runtime pointers. Known failure в fencing сохраняет attempt для retry,
например при наложении backup; автоматический rollback — applying/verifying.
После commit новый parent `/tmp/voicechat-managed-normal-vm.py` и driver запускать
по одному. Пока **активных VM/production jobs нет**; workflow ещё не pushed/run.
В этой сводке следующий launch должен обновить реальные session IDs/source path.

**Актуальное продолжение 29.10, 21:41 UTC:** пользователь ушёл спать и разрешил
непрерывную автономную работу; production по-прежнему24c42bf/run51, новых mutations
на A в этой итерации нет. **[Genuine VM core rollback PASS](three-vps-evidence/2026-10-29-vm-managed-core-rollback.json)**,
точный source f5c1a26, два цикла claim→apply+consistent backup→policy rollback→release.
Реальные Matrix session/device/account data и post-backup SQLite writes сохранены,
исходная private policy и PG/signing identity восстановлены; active repo reader
блокировал rollback без kill/остановки writers; lost commit reply не повторил configure.
Fixture удалён, исходная сеть/ключ VM не менялись. Первый прогон3ea8d56 прерван
агентом: synthetic policy менялась при уже включённом monitor; порядок исправлен,
повтор полностью PASS. Не выдавать interrupted прогон за успех.

После eee197a локально завершена связка normal coordinator→peer instructions→pinned
SSH driver: read-only preflight до begin, core/edge/web/full scope, frozen source,
known-error rollback и uncertain/busy SSH resume, refresh owned backup/TLS/shared
maintenance delegates после terminal journal. Откат пересоздаёт fence даже у
нетронутых участников и устанавливает owned boot sources до recovery. Edge обычный
apply и rollback используют общий stop TURN→configure→wait→no-deps readers, закрывая
ту же one-shot Compose race. Focused tests PASS; последний full **605 PASS/skipped3**,68.998s, включая
finish/SSH/edge-order tests. Новый VM standby helper и cleanup проверены compile/diff;
их реальная проверка будет частью следующего сквозного SSH fixture.

Следующий этап — **настоящий сквозной SSH normal rollout на отмеченной VM**, затем
подключение CI scopes и ordinary production full release. Пока настоящего normal
SSH/CI/production proof нет. Core-only VM source был
`/srv/voicechat-edge-fixture/managed-core-rollback-source-4mn52206`, session52840 завершён
exit0, wrapper `/tmp/voicechat-managed-core-rollback-vm.py`.
Ни второго fixture, ни production workflow сейчас не запущено. Проверить git status:
coordinator/SSH/finish modules, tests, edge order и docs могут быть рабочим diff.
Не повторять initial51 или macOS24 build. Установленный macOS24 уже принят кнопкой.


29.10.2026: **[run51 SUCCESS](https://github.com/kerbermeister/voicechat/actions/runs/40935478252)**,
initial/full/deploy=true/retry_initial=true, commit24c42bf866ba7d2ee3e17bd7d0f6a51a05705172.
Source bundle02899e149483a3ebf20c7ae44902e320f268c863571192f630f9b7f1ec49c3ba.
[Независимый postcheck](three-vps-evidence/2026-10-29-production-initial-postcheck.json):
initial phasecomplete, typed current/actual core+edge baseline, PG systemID/signingSHA
сохранены, соседние4 процесса неизменны, оба HTTPS200, backup/TLS timers enabled/
active, old backup timer inactive. Работа идёт на **одном физическом A, core+edge-a**;
B/C и физической отказоустойчивости пока нет. GitHub DEPLOY_ROOT=/srv/voicechat-managed.
Release веткуcodex/three-vps-initial не двигали после24c42bf. Initial повтор не нужен:
обычный managed release executor/scopes **ещё не реализован**.

Последний committed этап83e051c: host-local claim/observe/retarget/release и
строгие maintenance guards для core/edge. После него **локально** реализован
`infra/managed_core_rollback.py`: возврат previous code + исходной private policy,
без DB restore/volume removal, включая partially applied inner deploy и lost
rollback commit reply. Source-owned `managed-rollback` phase не допускает обхода
обычным core deploy. Сохранены early cancel/no-configure и остановка writers перед
повтором configure при неизвестном результате старта. Добавлен общий guard против
оставшегося Docker backup reader, используемый перед configure/writer recovery,
daily backup resume и первоначальным legacy rollback. Нельзя убивать backup/удалять
его locks для прохождения проверки. Full regression **556 PASS/skipped3**,52.945s;
10 focused outer core rollback tests PASS. При первом полном прогоне был пойман
локальный IndentationError в initial rollback guard, исправлен; все touched modules
прошли py_compile, полный повтор PASS. На production эти изменения не выполнялись.

[Production reader proof](three-vps-evidence/2026-10-29-production-managed-reader.json)
на точных Git a9b7a6a sources: current/initial bytes и все running containers
неизменны, временный public source удалён. [Production TURN/TLS](three-vps-evidence/2026-10-29-production-turn-tls.json):
на A через public SNI прошли authenticated allocation, expired credential denial,
private-peer403 и SFU public-peer permission. Статический secret **остался на A**,
успешные allocations освобождены, payload не отправляли. С Mac отдельно проверен
внешний trusted TLS443. Это не реальные аудио/видео/E2EE/failover.

Следующий этап: genuine VM outer-core rollback (реальные Synapse/control/Postgres,
synthetic session + post-backup writes, private policy и lost commit reply), затем
edge outer rollback/apply, frozen peer entry, pinned SSH driver и CI scopes.
Обычный managed CI пока не подключён. Production остаётся24c42bf/core+edge-a,
никаких новых mutations/rollout/baseline store на A не было.

**macOS24 опубликован и установлен23→24 через кнопку, PASS.** Владелец подтвердил
Keychain; кандидат открыл прежний профиль. Exact signed ZIP/DMG опубликованы штатным
publish_macos.py в `/srv/voicechat-managed/edges/a/runtime/macos-updates`.
[Evidence](three-vps-evidence/2026-10-29-macos24-published.json): HTTPS/feed/cache/hash,
Sparkle feed signature и archive embedded public key проверены. Installed23
предложил24; «Скачать и установить» реально обновила `/Applications/VoiceChat.app`,
PID89685, About1.12.0(24), codesign и все285 файлов/ссылок равны exact ZIP.
Account/device и10 прежних history markers совпали; новая24 проверила updater через
route-aware путь и получила «Совместимых обновлений нет». Приватные сравнения в CUA,
не копировать сами ID/тексты в docs. Backup app23+полного профиля сохранён в
VoiceChatRelease/before-update-24; Keychain не удаляли, приватный Sparkle key не
покидал Mac. User handoff закрыт, повторно не спрашивать подтверждение.

Android24 exact signed APK готов, физических устройств нет, не опубликован,
acceptance не подделывать. Real call/screen/E2EE и15s failover остаются открытыми;
нет B/C, нет Windows hardware/client. Новый normal journal и peer maintenance primitives **локально**, на VPS не
развёрнуты. Последний полный Python job61417 завершён PASS556/skipped3. Активного
production/VM/native build job нет. Installed24 открыт в About; candidate закрыт.
Проверить git status перед продолжением: новый core rollback module/tests и docs
могут быть ещё не закоммичены. Heartbeat voicechat-core-edge сохраняется, дубликат
не создавать. Продолжать normal apply/rollback/SSH/CI, не повторять initial51 или
Mac build24. Read-only proof A не означал выполнения peer mutations.

Важные условия следующего шага:
- Claim пишет **full marker первым**, затем peer intent: уже установленный51
  operator не знает новый receipt, но понимает существующий full fence. До apply/
  release ждать MainPID=0 у owned monitor (15s bound), не вызывать stop у неизвестного
  старого monitor: его finally мог бы остановить apps. Timeout оставляет fence.
- Новый peer receipt held/releasing закрывает gap отсутствующего full marker для
  новых boot/backup guards. Watch/stop/monitor_after учитывают оба вида maintenance.
- Outer rollback успешно committed core после edge failure **не сводится** к
  core_deploy.deploy(old): configure_policy объединяет существующие поля и может
  оставить добавленные candidate defaults. Требуется остановить writers, восстановить
  оригинальный private policy snapshot (core_deploy.policy_path(root,rejected)),
  запустить old code и проверить data identity; DB restore не выполнять. Учесть
  также прерванный inner apply/current==before с pending candidate, lost commit
  reply и failed-edge current==before без лишнего configure.
- Обычный shared-edge update не обновляет внешний shared-front автоматически:
  его config/image changes требуют проверенного отдельного перехода/раннего guard,
  чтобы не остановить core перед заведомо неподдержанным frontend изменением.
- Preflight всех участников делать до begin/fencing. Постоянная потеря edge во
  время fencing потребует recovery после доказанного revoke на A; произвольный
  skip неизвестного peer недопустим. Core/data host нельзя abandon. Это ещё не
  реализованная отдельная recovery ветка; не выдавать lost-reply resume за замену
  навсегда недоступного host.

## История предыдущих этапов


Обновляется 29 октября 2026 после возобновления работы владельцем.
Исходная остановка перед reboot завершала inventory/render и TLS;
после неё добавлены отдельные core/edge роли и локальная публикация каталога.
Последние итерации: один physical host, LiveKit resume/full restart, role manifests,
node-local WireGuard configs, Linux peer replacement, CI build config и отдельный WSS failover.
Владелец просит продолжать все доступные локальные задачи без дополнительных
подтверждений; новая просьба — итоговая схема сети, не остановка реализации.

## Ранний локальный шаг: общий первоначальный переход

`infra/initial_cohost.py` связывает подготовленные компоненты в один журналируемый
legacy→core/cohost сценарий на A. Это **кандидат**, ещё не разрешённый CI production
путь: цельный VM переход и fault drills пройдены; интеграция workflow не завершена.
Приватный snapshot рабочей policy остаётся на A; rollback меняет текущие URL pushers,
сохраняет данные/ключи/тома и возвращает legacy без восстановления старой БД.
После commit публичного ingress предусмотрено только доведение нового режима вперёд.
Boot recovery committed роли под full fence разрешён только владельцу точного nonce
и manifest, без повторного configure. Восстановление существующей сети требует
исходного fingerprint; новый peerless registry привязан к generation и сохраняет ключ.
Неверный SSH host и remote Docker отвергаются до записи состояния.

Последний подтверждённый полный набор — **479 Python tests, OK, skipped=3**;
координатор после следующего исправления — **14 focused PASS**, shared front — **10 PASS**, fixture cleanup — **2 PASS**. CLI и backup scheduler используют одну выбранную
подсеть. Commit **76707dc** сохраняет первый кандидат координатора.
В VM завершена проверка старого Git **8bcbd91** с source-built legacy control
**bc8327…** и candidate **abc8e6…**:
[PASS evidence](three-vps-evidence/2026-10-29-vm-exact-legacy-rollout-fence.json).
Точный Git source, restart=no lost-reply resume, installed full-fence systemd,
stopped-writer backup/check, URL forward/resume/current-row reversal и две
legacy recreation сохранили account/device, БД/signing/coturn identity и pointer.
Fixture ресурсы удалены; исходная VM network независимо проверена active.
Это синтетические данные на точных старых исходниках, **не полный core/edge переход**.
Следующий шаг — цельный сценарий координатора с подготовленным cohost ingress,
изолированной новой сетью VM, public commit, fault drills и восстановлением
исходной VM-сети без смены её ключа.

Новый [VM isolation proof](three-vps-evidence/2026-10-29-vm-network-isolation.json)
проверил atomic archive/restore исходного peerless intent/key и active network.
`prototype/initial_cohost_network.py` нужен только полному disposable-VM harness;
в production этот тестовый helper не запускается. Начальный network key не удаляется.
[Проверка systemd](three-vps-evidence/2026-10-29-vm-initial-boot-dependency.json)
выявила обязательный порядок: boot-unit с Requires=network не проходит verify до
появления network unit. Координатор теперь заранее только проверяет свободные/
owned boot slots, а устанавливает их после network и до запуска core. Rollback
обрабатывает ещё не установленный/частично установленный owned unit; чужие unit и
drop-ins отвергаются. Namespace cleanup допускает строго проверенный `created`
контейнер после неудачного Compose up; legacy baseline preflight остаётся строгим.
Actual Docker stop/rm never-started контейнера проверен, временный контейнер удалён.

Цельный VM harness теперь подготовлен: `check_legacy_core_preflight.py
--initial-cohost` использует `check_initial_cohost.py`, `initial_cohost_business.py`
и `initial_cohost_network.py`. Он создаёт старый 8bcbd91, соседний Caddy/HTTP-сервис,
synthetic CA/catalog key, запускает coordinator и проверяет account/device/account
 data, data/signing identity и same-target repeat. Оригинальная VM network хранится
целиком в private fixture root до удаления тестовых приложений, затем восстанавливается.
**Первый цельный прогон отказал, не принят**:
[attempt1](three-vps-evidence/2026-10-29-vm-initial-cohost-attempt1.json).
Production guard правильно отказался принимать оставшийся от исходной сети global
code cache без ownership receipt в новой сети VM. Global coordinator вернул legacy,
после чего fixture cleanup отказалась от пустой owned drop-in directory. Удалены
только сверенные backup units/пустой каталог; исходная network active, VM containers
пусты. VM isolation теперь архивирует также точный immutable source cache, guard
production не ослаблен. Расширенный isolation proof повторён успешно.
Scheduler slots предварительно проверяются до maintenance. Fixture cleanup покрыта
проверками отказа чужого unit и запрета остановки активного backup.
**Второй цельный прогон прошёл**:
[initial cohost PASS](three-vps-evidence/2026-10-29-vm-initial-cohost.json).
Проверены exact legacy 8bcbd91→backup/check→push migration→fresh network/boot→core
и edge→warm TLS→public shared ingress→timers→same-target repeat. Сохранились
account/device/account data, PG/signing identity и прежний legacy pointer.
Fixture resources удалены; независимая проверка подтвердила отсутствие контейнеров,
именованных VoiceChat volumes и role/backup units, original network active.
Это synthetic data/CA/key/fingerprint; настоящие устройства/media и production
не проверены этим прогоном.

**Failure drills завершены успешно после двух исправленных отказов fixture/retry.**
- [Fault attempt1](three-vps-evidence/2026-10-29-vm-initial-cohost-faults-attempt1.json)
  отказал на оставшемся пустом external TLS bridge предыдущего fixture. Bridge
  удалён только после проверки labels/config hash/IPAM и отсутствия endpoints.
  Business cleanup теперь удаляет его после Caddy; coordinator проверяет front
  ownership до maintenance. Guard `owned=False` не ослаблен.
- [Fault attempt2](three-vps-evidence/2026-10-29-vm-initial-cohost-faults-attempt2.json)
  прошёл intentional pre-public rollback и сохранил account data, записанные после
  snapshot. Следующий `retry` выявил реальную ошибку: Compose сохранил предыдущий
  recovery override в config-files labels. `legacy_models` теперь допускает только
  exact owned prior override с прежним TURN volume, проверяет его до maintenance;
  регрессия с retained labels всех шести services и чужим volume покрыта unit test.
  Этот отказ не считается подтверждением восстановления после core/public commit.
- [Финальный fault proof PASS](three-vps-evidence/2026-10-29-vm-initial-cohost-faults.json):
  rollback сохранил новые account data после snapshot; явный retry завершился;
  lost reply после core commit и после public commit восстановлен вперёд.
  Actual Type=notify boot под full fence завершался без restart loop; configure
  committed core/edge не выполнялся повторно. Исходная сеть восстановлена с тем же
  public key. Текущие fixture containers/units/networks удалены; два старых
  анонимных volume от 28.10 сохранены. Активных VM прогонов сейчас нет.

`release_delivery.py`: bounded stdlib stdin receiver, immutable `/ROOT/bundles/SHA`,
exact repeat без overwrite — **7 unit PASS**. `ssh_deploy.py receive` сверяет архив
с чистым Git commit, полным набором tracked sources и backend fingerprint до SSH;
исполняет bootstrap только из проверенного архива, через закреплённый SSH host key.
**5 transport tests PASS**, [Linux SSH transport/repeat PASS](three-vps-evidence/2026-10-29-vm-source-transport.json),
86 публичных files, synthetic image pins, без app/data/credentials. К workflow ещё
не подключено. Полный набор **479 PASS, skipped=3**.

Для продолжения в этом же чате создан heartbeat **voicechat-core-edge**, каждые
30 минут. Он продолжает доступные работы, не дублирует активные прогоны и молчит
при неизменном состоянии; при завершении/настоящем внешнем блокере его надо
приостановить, сохранив остальные настройки. Новые чаты/агенты не создаются.

GitHub repo подтверждён UI и main SHA **2cca4d3**; `origin` теперь SSH
`git@github.com:kerbermeister/voicechat.git`, fetch выполнен. Существующий
`/Users/anton/.ssh/id_ed25519` аутентифицирует **kerbermeister**, push **dry-run**
успешен. Ветка ещё не опубликована; HTTPS без credentials не использовался для push.
CUA docs восстановлены; tab2/browser2 — GitHub variables, binding `rolloutGitHub`.

Production transition, normal managed core/full/edge/web CI orchestration,
client releases и реальные устройства/media остаются впереди.

Production службы, данные и DNS в этом шаге не менялись.

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

Дополнительная защита после VM proof: initial controller после public commit
публикует owner-only `legacy_root/role-deployment.json`; текущий старый controller
отказывает до runtime/Docker. Проверены repeat, foreign marker и symlink refusal
(15 initial-focused PASS). Это не защита от запуска исходников старого 8bcbd91:
перед production нужно также переключить canonical DEPLOY_ROOT на managed root
и проверить отказ старого workflow. Финальный fault proof выше относится к
предыдущему hash initial controller; новая защита пока покрыта unit, не новым VM.

## Сквозной CI initial путь — следующий этап

29.10: `managed_release.py` добавляет read-only план web/edge/core/full и фактический
per-role baseline: pinned host, role/bundle/boot ownership, locks, pending/fence,
process IDs/StartedAt/RestartCount, runtime hash и data identity. Выбор произвольных
edge IDs и mixed web versions покрыт 12 unit checks. Это пока план/чтение, не обычный
managed rollout controller.

`initial_entry.py` + `ssh_deploy.py initial` соединяют frozen source delivery с
проверенным initial coordinator; GitHub `Build and deploy` получает явный
`rollout=initial, mode=full`, build-only остаётся доступен. Envelope/raw public key
передаются stdin; private signing key/runtime/registry credentials не принимаются.
5 entry/transport checks и workflow YAML PASS. Последний уникальный полный набор **497 PASS/3 skip** (39.662s);
повторный импорт test class исправлен. Клиентский кандидат поднят до **1.12.0+24**, не выпущен.

Повтор old28/e964 manager→current32/**876ae8…** прошёл на VM с сохранением всех
процессов: [evidence](three-vps-evidence/2026-10-29-vm-manager-28-to-32.json).
Текущий цельный VM proof retirement/typed baseline **ещё идёт**:
`/tmp/voicechat-initial-cohost-retirement-vm.py`, exec session **97397**, source
`/srv/voicechat-edge-fixture/legacy-preflight-source-unml653o`, fixture
`/srv/voicechat-edge-fixture/legacy-preflight-p7pzzrjy`; последняя фаза **edge**.
Не запускать параллельно другой VM fixture. Новые `initial_entry.py`/baseline reader
появились после freeze этого прогона; этот proof не проверяет сам CI entry point.

Production baseline обновлён read-only: app по-прежнему 8bcbd91, backend ad44fd…,
plan 5b27…, managed root отсутствует, контейнеры healthy, свободно около 36.6 GB.
По разрешению владельца установлен **только wireguard-tools 1.0.20210914-1ubuntu4**:
[evidence](three-vps-evidence/2026-10-29-production-wireguard-tools.json).
Проверены неизменность всех running container IDs/StartedAt/RestartCount и network
links; WG interface не активирован, DNS и приложение не менялись.

В private `.prototype/production/` готовы `server-role-config.json`,
`signed-route-catalog.json`, `initial-request.json`: исходный production inventory,
shared TLS profile, canonical edge a, root /srv/voicechat-managed; каталог revision1
на 30 суток подписан существующим offline key и проверен. На VPS/GitHub ещё не
отправлены; ключ не меняли и не вывозили. Следующее: закончить активный VM proof,
проверить exact CI entry bundle, commit/push, запустить штатный build-only CI;
после его проверок настроить public config variables и выполнять initial full.
Затем canonical DEPLOY_ROOT→managed (защита от старых workflows), обычные managed
обновления, обязательный Sparkle выпуск24 и реальная приёмка устройств/media.

### После запуска первого CI build-only

Ветка опубликована: commit **b0b7040096457cb1347ea4396ef0293cd9b379a5**.
[Build and deploy #48](https://github.com/kerbermeister/voicechat/actions/runs/40918217857),
`rollout=initial, mode=full, deploy=false`, запущен через GitHub UI. Server/client
checks прошли, на момент наблюдения — cold crypto tool/assets cache. Этот commit
**не выкатывать**: следующая VM проверка выявила дефект durable baseline.

[Retirement attempt1 — отказ, не принят](three-vps-evidence/2026-10-29-vm-initial-cohost-retirement-attempt1.json):
переход и account/device/data assertions завершились, legacy retirement guard
сработал. Затем web planner отказал, потому что managed_state сохраняет JSON с
sort_keys, а core VOICECHAT_ROUTE_CONFIG и node.json рендерились с insertion order.
`role_config.py` и `render_roles.py` теперь используют canonical sorted JSON.
Регрессия проверяет все четыре scopes после persisted sorted round-trip и
идентичность core/edge manifests при перестановке полей. Полный набор **498 PASS,
skipped=3**, 40.480s. Старые артефакты #48 полезны только для проверки сборки/кеша.

Уточнение активного прогона: session97397 завершился отказом; его fixture удалён,
исходная network active. Теперь идёт session **1044**, тот же wrapper
`/tmp/voicechat-initial-cohost-retirement-vm.py`, source
`/srv/voicechat-edge-fixture/legacy-preflight-source-u5sgkaje`.
В него включены canonical JSON fix и actual core/edge baseline reader. Не запускать
параллельный fixture. Текущие незакоммиченные source changes — только эта регрессия;
их надо commit/push и использовать исправленный revision для следующего CI/deploy.

Production дополнительный read-only preflight: modprobe -n wireguard успешен,
/var/lib/voicechat-network, managed root и legacy retirement marker отсутствуют.
Публичные production SERVER_ROLE_CONFIG / SIGNED_ROUTE_CATALOG подготовлены локально;
начата настройка GitHub vars через tab8 (rolloutVariables). Пока проверять UI,
а не считать обе переменные сохранёнными автоматически. Приватный signing key
остаётся на Mac. DEPLOY_ROOT пока /srv/voicechat, ещё не менять до public commit.

GitHub repo variables **SERVER_ROLE_CONFIG** и **SIGNED_ROUTE_CATALOG** сохранены
и подтверждены UI (tab8 rolloutVariables); только public config/envelope, без
private keys. Скриншот `/Users/anton/.codex/visualizations/2026/10/28/01a180db-aec5-70d0-bc4d-59ec5e16b1e3/voicechat-initial-variables.png`.
[CI #48](https://github.com/kerbermeister/voicechat/actions/runs/40918217857) завершился
**успешно**: tests/analyze/build control+web/upload, без deploy; exact crypto caches
сохранены. Его b0b7040 всё равно не выкатывать из-за исправленного выше baseline bug.
Исправленный canonical commit **eb21c74ff7707d6d4572a67f22308090de7f61f5** опубликован.

К обнаруженному протоколу CI добавлена небольшая правка: существующий Restic
backup пишет progress в stdout. SSH initial теперь принимает только финальную
JSON-строку completion, проверяет поля/commit/root/hash и не печатает private
progress в CI. Unit проверяет prefix и отказ trailing garbage. 23 focused PASS;
изменение не трогает coordinator/data/network. После успешного текущего VM proof
следующий штатный full запуск можно делать с `rollout=initial, deploy=true` на
исправленном revision, предварительно сверив exact source и production baseline.

## Подтверждённый initial кандидат; внешний барьер GitHub

Исправленный [полный VM proof PASS](three-vps-evidence/2026-10-29-vm-initial-cohost-retirement.json)
завершён, session1044 закрыт успешно. Canonical source hashes совпали с рабочей
копией, прошли retirement старого controller, durable sorted baseline/web plan и
**actual core/edge baseline reader**. Account/device/account data/PG/signing
identity сохранены; same-target repeat успешен. Независимо подтверждены отсутствие
fixture containers/units и active исходной VM network. Других VM jobs нет.
Отдельно [точный старый 8bcbd91 deploy guard PASS](three-vps-evidence/2026-10-29-vm-old-workflow-guard.json):
на synthetic typed managed root старый deploy отказывает до Docker при отсутствии
глобального stand.env. Это не защита старого root одним новым marker.

Source HEAD кандидата **9d4a1aedd2d1e43c37d42852980dbf655dfc5c13** опубликован.
Все защищённые исходники совпадают с успешно проверенным VM набором, за исключением
SSH completion framing, проверенного focused unit (23 PASS). Full Python **498 PASS,
skipped=3**; новых client изменений после CI #48 нет. Следующий production initial
workflow должен использовать этот verified source (или revision только с docs).

**GitHub DEPLOY_ROOT ещё НЕ изменён.** В environment production попытка сменить
/srv/voicechat→/srv/voicechat-managed вызвала **Confirm access / Password**. Не считать
save завершённым; прежний root остаётся действующим до UI-подтверждения. Пользователю
отправлен async запрос самостоятельно подтвердить вход в tab8 (rolloutVariables),
пароль в чат не запрашивался. open_in_codex(tabId8) вернул queued; tab помечен handoff.
Для защиты от старого workflow меняем root ДО initial dispatch: initial handler
уже допускает DEPLOY_ROOT=managed и берёт legacy_root из SERVER_ROLE_CONFIG. Старый
workflow будет fail-closed, runtime приложения/backup timer от смены CI var не
меняются. После подтверждения проверить сохранение и только затем запускать
rollout=initial, mode=full, deploy=true. Публичные SERVER_ROLE_CONFIG и
SIGNED_ROUTE_CATALOG уже сохранены; SSH secrets и rules не менялись.

Пока auth недоступен, продолжать обычный managed rollout controller и клиентские
артефакты; не обходить аутентификацию/SSH/source guards, не подменять deployment
состояние и не выкатывать b0b7040. Пользователь прямо просит не останавливаться.

macOS **1.12.0(24)** собран на clean 9d4a1ae и упакован/подписан существующим ключом:
`.prototype/macos-candidate-24-signed`, sourceDirty=false, personal-adhoc,
Sparkle feed/archive signatures проверены упаковщиком против embedded public key.
ZIP SHA256 **9ae3b1020439f19aa30bbc106782a6c4a1a66ca0ef1a48ac53b025fb40da1b61**;
DMG **b73ed5efeda7d4e55f53f1e07761174467d68b7135a70f3072c7cbd28c20420c**.
Не установлен/не опубликован; обязательны backup app/profile, previous installed23
UI update и сохранение account/device/history после production перехода.
Первая packaging попытка ошиблась путём sign_update, не принята; правильный SDK bin:
`/Users/anton/Library/Developer/Xcode/DerivedData/Runner-esogviehnrlutigydryaphqbznxi/SourcePackages/artifacts/sparkle/Sparkle/bin`.
Существующий private key только на Mac в VoiceChatRelease; его не вывозить.

Android release APK24 собран успешно (157.7MB), исходники clean9d4; session69769
закрыт. Ещё надо package/verify штатным android_release.py существующим certificate.
Локальный signing config `.../IdeaProjects/VoiceChat/secrets/android/signing.json`
0600 существует; никаких новых ключей не создавали. CI Android secrets отсутствуют,
workflow не запускали; tab9 закрыт. `adb devices -l` — ни одного устройства.
Физическую приёмку и promotion APK не объявлять завершёнными/не обходить guard.
При packaging после docs-only commit проверить неизменность всех compile inputs
относительно 9d4a1ae; не менять уже подписанный Mac package или его provenance.

## Production initial workflow запущен — не дублировать

Владелец подтвердил GitHub access. UI фактически показывает environment production
**DEPLOY_ROOT=/srv/voicechat-managed**; SSH/rules не менялись. Предыдущий auth blocker
снят, старое значение /srv/voicechat больше не считать действующим в GitHub vars.
legacy_root=/srv/voicechat остаётся явной частью SERVER_ROLE_CONFIG.

Закреплена release ветка **codex/three-vps-initial** на
**f3ec45717d638eff9c9539482afa27b637207086** (только docs/evidence относительно 9d4a1ae;
все compile/deploy inputs проверены `git diff` без изменений). Не двигать эту ветку
во время initial run. Основная рабочая ветка по-прежнему codex/three-vps-rollout.
VM proof проверяет перечисленные role/coordinator hashes; не выдавать его за
проверку всех CI/source files (SSH framing покрыт отдельным unit).

**Активный [Build and deploy #49](https://github.com/kerbermeister/voicechat/actions/runs/40923745658)**,
job **123623616357**, `rollout=initial, mode=full, deploy=true`, выбранная ветка
codex/three-vps-initial/f3ec457. Стартовал через UI 29.10. Проверки/сборка идут перед
переходом; на момент запуска production по-прежнему8bcbd91, managed root отсутствовал,
legacy release lock доступен. Не запускать второй workflow/ручной Compose. При
отказе смотреть фактический `/srv/voicechat-managed/initial.json` и exact source
bundle на A; не подменять target новым HEAD и не трогать данные/ключи. `retry_initial`
только после завершённого rolled-back; незавершённый attempt продолжать тем же
frozen source. После public commit — только forward recovery. Последний известный
production app ещё старый, не считать сам запуск доказательством перехода.

Android **1.12.0(24)** также упакован и проверен штатным android_release.py:
`.prototype/android-candidate-24`, sourceDirty=false, existing certificate37d98d…,
три ABI. APK SHA256 **079440582ba1923e7adea319719369409a003cd4507098457b04541185501610**.
Build source9d4a1ae, packaging sourcef3ec457 — diff только docs, все compile inputs
отдельно сверены; APK не пересобирали. Не опубликован, physical acceptance=false
(реального Android в adb нет). Mac signed candidate указан выше; ещё не установлен
и не опубликован. Активных локальных build/VM exec sessions больше нет.

Текущий браузер: rolloutGitHub tab2 — run49; rolloutVariables tab8 — production env
с сохранённым новым root, оба handoff. Скриншоты в разрешённом visualizations root:
voicechat-managed-root-confirmed.png и voicechat-production-initial-run.png.
Следующий приоритет: дождаться/проверить run49, проверить manifest/digests, data/signing
identity, соседний HTTPS/процессы, backup/boot/TLS timers и повтор API/клиента.
Затем backup app/profile, обязательный Sparkle23→24 через UI с прежним аккаунтом/
device/history; штатная публикация exact signed candidate на новый canonical edge.
Обычный managed rollout executor и scopes ещё не завершены; planner/reader есть.

## Внимание: production continuation сейчас активен

CI #49 прошёл tests/build/upload и отказал на начальном legacy preflight (7s),
**до создания initial.json и до остановки служб**: infra старого release имела UID1001
от GitHub tar, guard требует root. Guard не ослаблен. Все29 public source files
сверены с точным Git8bcbd91; только их/каталогов/metadata owner нормализован в root.
[Evidence](three-vps-evidence/2026-10-29-production-source-ownership.json): bytes,
release pointer, все container IDs/StartedAt/RestartCount и runtime/data неизменны.

По согласованному контракту продолжения frozen entry запущен **тот же** артефакт
CI49, без новой сборки, без ручного Compose. **Активный exec session44264**:
`/tmp/voicechat-resume-production-initial.py`; remote entry
`/srv/voicechat-managed/bundles/adb77321e414ff4499f2d846f524ad29bb235eddf33b57a7010c36ac12fd3633/infra/initial_entry.py`,
`--root /srv/voicechat-managed --source-sha adb77321e414ff4499f2d846f524ad29bb235eddf33b57a7010c36ac12fd3633`.
Private stdin — сохранённый `.prototype/production/initial-request.json`, public
config/envelope. Private operator log `.prototype/production/initial-resume-49.log`.
НЕ запускать дубликат/новый target, не менять initial.json/source/current pointers.
При завершении wrapper пишет `2026-10-29-production-initial-completion.json`; CI49
остаётся failure preflight и не выдаётся за зелёный release. Для восстановления
проверить фактический journal phase и завершить тем же entry; после public commit
только forward recovery. Для нового retry после rolled-back нужен явный --retry.

Перед продолжением снят [neighbor process snapshot](three-vps-evidence/2026-10-29-production-before-initial.json)
для frontend/backend/stt/postgres; Caddy может штатно recreate при port handoff.
После completion сравнить эти четыре процесса и data/signing identity с baseline.

Перед обновлением Mac штатно закрыта /Applications/VoiceChat.app build23; создана
и по всем regular files/symlinks проверена private backup
`~/Library/Application Support/VoiceChatRelease/before-update-24` (app+Container Data).
Keychain symlink не разворачивали, его содержимое не копировали/не меняли.
Backup app codesign verified. Старый клиент снова запущен, история видна, без
нового входа. CUA binding rolloutInstalledApp; initial getApp timeout был только
холодным запуском, повтор успешен. Для Flutter UI использовать AX clicks и
getAXState({disableDiffing:true}); coordinate clicks возвращали noWindowsAvailable,
но AX работают. Before account/device и history marker strings сохранены только
в памяти CUA (`rolloutPreviousUser`, `rolloutPreviousDevice`,
`rolloutBeforeHistoryTexts`), не переносить приватный текст в отчёты/реестр.
Сейчас открыт About23, feed24 ещё не опубликован. Порядок оставшейся macOS-проверки
обязателен: production health → launch exact24/prepublish physical acceptance →
publish exact signed package → previous23 «Проверить обновления»/install button →
same account/device/visible history, без удаления Keychain/profile.

## Production preparing guard repair — текущая точка

Session44264 завершился отказом в **preparing**, до любых role/network/backup/fence
изменений. Причина: postgres/turn сохранили config-files labels от49f09…, control
от36ca37…, хотя complete legacy preflight подтвердил текущие images/mounts/ports/
security/data. Это штатное Compose reuse между прошлымі web/full релизами; fixture
с одним исходным release такую историю не моделировал. Приложение8bcbd91 healthy.

Точный pending attempt **2fdbc7c007544a987b51a9d4c10505226290712f127c9be50ed27d0d4a796f8b**,
phase=preparing, attempt directory пуст, core/edges/network/current отсутствуют.
Исходный f3ec457 bundle **adb773…** не менять. В f3 release branch больше не запускать
initial: ей нужен исправленный coordinator, но journal сначала надо штатно отменить.

`initial_cohost.namespace` исправлен: только immutable container IDs из полного
captured legacy baseline могут использовать проверенный current model при старых
labels. Image/mount/network/port/security guards сохранены, новый ID/чужая модель
не принимаются. Все voicechat namespace/cleanup calls передают baseline; новые
core/edge containers по-прежнему требуют exact config-files. **18 initial-focused
PASS**, полный набор **501 PASS / skipped3**,36.035s. [Actual Docker low-level PASS](three-vps-evidence/2026-10-29-vm-retained-legacy-labels.json)
проверил retained hint, rejection нового ID/изменённого read-only; fixture удалён.
Первый probe неверно описал Docker none network, setup исправлен, guard не ослаблен.
Это не новый полный migration proof.

Добавлен `cancel_initial.py`/cancel_preparation: только empty preparing без roles/
network/backup/fence, полный original source receipt+healthy legacy+legacy-certs
проверяются, journal **перемещается целиком** в attempt/cancelled-preparation.json,
не переписывается. Повтор безопасен; при подготовленных ресурсах/другом nonce/
изменённых source или legacy — отказ. Это операторская отмена не начавшегося
attempt, не подмена successful rollback и не очистка пользовательских данных.

Дальше: commit исправления; pinned SSH delivery только публичного проверенного
operator code для read-only namespace check на A, затем reviewed cancellation
точного empty attempt и сохранение evidence (без Compose/service изменений).
После cancellation обновить release ветку codex/three-vps-initial на исправленный
commit и повторить штатный initial/full CI. Предыдущие native24 artifacts сохранять:
их compile inputs не менялись. #49 остаётся failed preflight; source49 не править.
Активных production/VM/build exec jobs сейчас нет. Недоставленных permission asks нет.

## Активен исправленный production run50

Исправленный readonly namespace preflight **успешно проверил все6 реальных legacy
контейнеров**. Первая cancellation попытка отказала до rename: historical operator
не должен совпадать с новым source package. Вызов read_plan исправлен на штатный
`current_sources=False` (полные hashes/ownership исторического пакета сохраняются,
как в других maintenance helpers), contract закреплён test assertion. Новый полный
набор **501 PASS/skipped3**,34.808s.

Commit **469cea9663d7ceccb9f9b73a4478db241b049abb** опубликован. Reviewed public operator
code доставлен по pinned SSH во временный private каталог, сверены Git bytes/hashes;
после проверки исходного immutable49 bundle и healthy baseline exact empty attempt
**2fdbc7…** штатно архивирован в
`/srv/voicechat-managed/attempt-2fdbc7c007544a987b51a9d4c10505226290712f127c9be50ed27d0d4a796f8b/cancelled-preparation.json`.
[Production cancellation PASS](three-vps-evidence/2026-10-29-production-preparation-cancelled.json):
исходные bytes журнала сохранены, current/все процессы/runtime/data/network
неизменны. Исходный49 blob adb773… не модифицирован. Временный operator code удалён.

Release ветка **codex/three-vps-initial** fast-forward на **469cea9** после этой
cancellation. **Активный [Build and deploy #50](https://github.com/kerbermeister/voicechat/actions/runs/40930173085)**,
job **123646194415**, initial/full/deploy=true, retry_initial=false (это новый attempt
после отмены empty preparing, не retry rollback). Начальные tests/config прошли;
последнее наблюдение — сборка control image. Дубликат не запускать; ветку не двигать.
#49 остаётся failed preflight, его manual continuation44264 также завершилась до
fencing. Все pipeline artifacts50 будут новыми после исправления исходников.

Браузер rolloutGitHub tab2 сейчас job50; markHandoff сделан. Native app binding
rolloutInstalledApp — /Applications/VoiceChat.app23, открыт About23. Координатные
native clicks не работают; AX clicks с fresh full AX работают. Получены account/
device и visible history23, затем штатный Quit → verified private backup
VoiceChatRelease/before-update-24 → запуск23; прежняя история видна. Никаких сообщений
не отправляли, данные/Keychain не очищали. CUA private comparison bindings остаются
в памяти; не копировать их тексты в публичные docs.

Точный signed ZIP24 также распакован в `.prototype/macos-24-extracted/VoiceChat.app`,
checksum, version24, embedded key и codesign проверены; **не запущен/не установлен**.
Signed candidate `.prototype/macos-candidate-24-signed` не менять/не переподписывать;
source commit9d4, состав клиента неизменен после него. Android24 `.prototype/android-candidate-24`
проверен, sourceDirty=false, sha079440…, не опубликован; физического Android нет.

Готов read-only postcheck `/tmp/voicechat-production-postcheck.py` для successful50:
требует complete/commit469cea9; проверяет source receipt, actual core/edge baseline,
исходный PG systemID7699984398180954145/signingSHAaa2d…, legacy pointer+retirement,
neighbor4 processes vs before-initial snapshot, HTTPS обоих сайтов, backup/TLS timers
и retired old timer. Даёт running backup спокойно закончить (до300s), не убивает его.
Пока не запускали — сначала дождаться phasecomplete/run50. После этого выполнять
native24 prepublish acceptance и штатный Sparkle publish/update23→24.
Обычный managed rollout executor/web-edge-core-full CI и real-device/media проверки
ещё не завершены. Активных локальных VM/build/exec jobs нет, только GitHub run50.


## Run50: проверенный откат; исправлено ожидание configure

[Run50](https://github.com/kerbermeister/voicechat/actions/runs/40930173085)
прошёл backup, migration, private network и boot installation, но остановился на
configure при запуске core. Автоматический откат завершён, phase=rolled-back.
[Независимая проверка](three-vps-evidence/2026-10-29-production-rollback-50.json):
legacy source/runtime/data/anonymous TURN volume identity сохранены, исходные PG
system ID и signing SHA прежние, четыре neighboring процесса неизменны, старый
backup timer enabled/active, оба публичных HTTPS отвечают200. Оригинальный журнал
сохранён на A в attempt/rolled-back-initial.json; role dirs, network key и desired
state не удалять. Следующий штатный запуск обязан иметь retry_initial=true.

[Диагностика configure](three-vps-evidence/2026-10-29-production-configure-diagnostic.json)
на фактическом env и read-only mounts прошла input validation с подавлением4 writes.
[Изолированное воспроизведение](three-vps-evidence/2026-10-29-production-oneshot-compose.json)
на реальном Compose5.5.1: быстрый exit0 при up --wait ошибочно даёт exit1,
медленный exit0 проходит. Явный compose wait возвращает0 при успехе и7 при ошибке.
Диагностические проекты без сети, томов и credentials удалены, production не меняли.

core_deploy теперь запускает configure отдельно, явно ждёт его exit code, затем
поднимает остальные службы с health wait. Добавлены два regression tests: fast
success до старта writers и nonzero с rollback предыдущего кода без DB restore.
Полный Python набор: **503 PASS/skipped3**,35.105s. Клиентские compile inputs не
менялись; подписанные macOS24/Android24 artifacts не пересобирать ради controller fix.
GitHub DEPLOY_ROOT=/srv/voicechat-managed уже сохранён после подтверждения пользователя.
Далее commit/push, fast-forward release ветки, initial/full/deploy=true/retry=true.


## Следующий managed шаг: bounded baseline storage

`managed_release.store_baseline/load_baseline` сохраняют public/inventory/core и
каждый edge manifest отдельными immutable JSON objects с SHA256 ссылками. Индекс
мал, pointer не изменяется. Это позволяет хранить полную смешанную baseline32
входов, которая целиком превышает64KiB, сохраняя прежний лимит каждого managed
документа. Tests проверяют32 входа/mixed revisions, повтор без новых объектов,
подмену bytes, symlink и path traversal reference. Полный набор505 PASS/skipped3,
39.410s. Это подготовка ordinary coordinator, **не его готовая реализация/CI**.
[macOS24 предварительные проверки](three-vps-evidence/2026-10-29-macos24-prepublish.json)
сохраняют границу: ZIP/DMG/signatures/About проверены, session/update ещё не приняты.


## Production51 принят технически; normal coordinator остаётся

Independent postcheck SUCCESS на точном24c42bf/source02899e…; значения commit/digests,
полная role baseline, PG/signingidentity, HTTPS и timers сохранены в evidence.
Первичный переход **не повторять**. Полный исправленный порядок configure→wait→
dependent writers также отдельно прошёл actual Docker Compose на A без production
данных/сети/credentials, временный проект удалён. Проверка fresh production web
через CUA IAB: обычный экран входа, семантика и About1.12.0(24) открылись; аккаунт
не вводился. Скриншоты production-initial-51-complete и production-web24-about в
visualizations текущего чата. Это не приёмка web account recovery/медиа.

Следующий локальный шаг — durable normal release journal на A (baseline references,
ordered per-role operations, CAS/lost reply, no duplicate apply), затем pinned SSH
role operations и CI scopes. Не выдавать готовый initial handler за ordinary full.
macOS24 остаётся в Keychain handoff, приложение/профиль23 сохранены, feed23 прежний.


## macOS Keychain подтверждён, выпуск24 доведён до установки

Владелец ответил «готово». На exact candidate24 прежние account/device и10 фрагментов
истории видны. `publish_macos.py` опубликован по pinned SSH только с публичными
артефактами, без передачи private signing key; обе SHA и feed signature проверены
после скачивания по HTTPS. App23 предложил24, кнопка выполнила Sparkle replacement
и restart. Все285 файлов/ссылок installed24 равны ZIP, подпись и прежний профиль
проверены на macOS15.3.1. Updater24 через новый маршрут также работает. Исторические
неуспешные22→23 не переписаны как PASS; текущая функция UA-48 обновлена результатом24.
Нативный выпуск больше не blocker. Дальше normal managed journal/peer driver/CI и
реальные медиа/отказы в доступной среде; отсутствие Android/B/C не выдавать за успех.


## Normal-release journal: локальная реализация протокола

`infra/managed_journal.py` связывает bounded baseline index с immutable delivery,
preflight baseline fingerprint и оригинальным current snapshot. Упорядочены
fencing→core/selected edges→verification→public commit→release fences; каждый peer
должен прислать фактические typed manifest/process/data/runtime/fence proofs.
Модуль **не исполняет peer actions и не генерирует proofs**. CAS/nonce и записанные
acknowledgements исключают повторный advance после потерянного ответа; interruption
между proof/journal и current/journal восстановим. После начала public commit
только forward resume. До него rollback идёт в обратном порядке touched roles,
сохраняет before/current/data identity; повтор после rolled-back требует explicit
retry, прежний журнал архивируется verbatim. Чужие pointer/attempt/source paths,
symlink/public directory, runtime/data substitution, missing/out-of-order proof
отклоняются. Early abort до первого fencing proof допускает только восстановление
committed baseline, не выдумывает отсутствовавший process snapshot.

17 journal tests +16 managed baseline tests PASS (33 total,9.671s); полный набор
520 PASS/skipped3,50.571s был до последних3 дополнительных negative tests, код
после полного прогона не менялся. Maximum32 baseline/journal/first-proof отдельно
проверены без увеличения64KiB boundary. Historical completed intent не пересчитывается
новым renderer. **Нужны дальше:** actual pinned-host role claim/apply/rollback/
inspect/release, exact frozen source entry, SSH orchestration, CI scopes и genuine
VM release/partial/full interruption tests. Пока обычный managed CI release не
доступен; legacy path намеренно не может менять новую схему. Production51 здоров,
Mac24 release/update завершён, Android/внешние B/C/реальные медиа остаются открыты.


## Peer maintenance primitives и regression PASS544

Добавлен managed_fence.py (пока без apply/rollback code executor): обе роли
прошли claim/repeat/observe, cancel через retarget baseline, lost first-intent,
lost retarget, lost release receipt, unknown nonce/host, runtime symlink/mode,
архивирование прежнего receipt и monitor timeout. Только synthetic unit fixtures,
не actual VM proof. Runtime и own role metadata проверяются до записей; apps не
останавливаются этими функциями. Durable intent валидируется в role_deploy, guards
учтены во всех boot watch/stop/monitor_after вызовах. Alias initial marker сохраняет
прежнюю конструкцию с дополнительной owner/runtime проверкой. Весь Python набор
544 PASS/skipped3,54.772s. Следующий required шаг — actual apply + policy-preserving
outer rollback, затем transport/CI. Mac24 release закрыт; production51 не менялся.


## Policy-preserving outer core rollback + production TURN check

`managed_core_rollback.rollback` принимает только owned baseline fence, проверяет
runtime/data/host manifest identity и исходный snapshot policy. Работающий backup
reader блокирует configure/возврат writers, но не убивается. Prepared/ещё не
сконфигурированный кандидат отменяется без configure/stale snapshot; завершённый
inner rollback не применяется повторно. После lost outer core state commit reply
возобновление проверяет committed previous и не повторяет configure. При неизвестном
precommit результате старта writers останавливаются перед повтором. Новая pending
phase блокирует ошибочный generic deploy. 10 содержательных unit cases PASS,
556 full PASS/skipped3,52.945s; **actual VM proof ещё нужен**.

Для следующего VM proof использовать cached fixture control
`ghcr.io/voicechat-fixture/control@sha256:abc8e6e2f226aec43a3e59e0229b18b72070f4046f79e5a63b99ea410fd7b9d4`.
VM проверена: /srv/voicechat-edge-fixture/.disposable-vm присутствует, Docker
контейнеров сейчас нет, voicechat-network active/exited. Original peerless WG
intent/key не менять/не регенерировать. Можно переиспользовать setup из
prototype/check_core_backup_current.py без network isolation: берёт текущую VM
inventory и стартует core на5 новых synthetic named volumes. Перед стартом
отказать при любых existing voicechat containers/volumes/unit. Synthetic account
seed через admin registration HMAC; secrets/tokens не печатать. Real policy
проверять валидным изменением text_max_length в fixture volume после candidate,
остановив writers на время правки, затем start_committed. Перед обратным откатом
записать post-backup account data/SQLite sentinel и доказать их сохранение. Можно
включить managed_fence claim/retarget/release и настоящий monitor quiescence.
Cleanup только собственных контейнеров/5 volumes/owned unit, не удалять два старых
anonymous coturn volumes и original network. Source wrapper .prototype/vm-exec.py,
VM SSH54926, marker synthetic host key закреплён. Временный test source только
точные Git public infra/prototype files; production keys/images/credentials не
копировать. После proof проверить original network active/bytes unchanged.
