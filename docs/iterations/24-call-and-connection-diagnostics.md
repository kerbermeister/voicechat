# Звонок Mac ↔ web и диагностика соединения

30.10.2026. Scope: исправление/приёмка звонка на текущем VPS, затем диагностика
и мониторинг. Новые VPS, перенос A и почта исключены. Автоматизация paused.

## Реальная проверка до изменений

Installed native1.13.0(25) → production IAB web: агент инициировал сMac и принял
вweb, оба клиента connected/excellent более2 минут; web mute отобразился наMac,
микрофон восстановлен, native hangup завершил вызов. Пользователь подтвердил
слышимый звук. [Безопасный proof](three-vps-evidence/2026-10-30-mac-web-audio.json).
Предыдущий вызов пользователь принял в браузере; он уточнил, что это был web,
поэтому тот вызов отдельно не считается Mac proof. Работала одна native копия.

Независимый localhost getUserMedia ждал15s без Matrix/TURN. Production захват
и звонки затем разрешились после взаимодействия пользователя с браузером.
Это указывает на ожидание разрешения/действия браузера; точное различие permission
и gesture не доказано. Серверные сеть/политики/сигнализация для успешного звонка
не менялись. Local probe закрыт, HTTP server остановлен; capture не записывался
и не отправлялся в diagnostic page. Root data/Keychain/profile не очищались.

## Подтверждённый дефект таймера

Новый incoming показывал1:07 от предыдущего завершённого разговора. CallWindow
брал active.duration даже при другом incoming/remote вызове. Новый guard скрывает
старый timer для direct/group/remote/dialing/error, сохраняя completed summary.
4 window tests PASS, включая последовательность finished → next incoming → summary.
Пользовательский остаток только в существующем UA-04, без нового списка приёмки.

## Кандидат1.14.0(26)

Settings → Диагностика соединения: локальный allowlisted snapshot route IDs,
readiness selection/recovery durations, last failed service и агрегаты звонка.
Нет origins, user/room/device/session IDs, SDP, credentials, содержимого сообщений.
Никакой автоматической выгрузки. Native/web используют общий контракт.

Node diagnostics: CPU count/load1/5/15 и cumulative RX/TX только собственного
TURN-контейнера. Host/shared container namespace и чужие project/service исключены.
Счётчики включают protocol overhead и сбрасываются с контейнером; это не размер
пользовательских медиаданных и не throughput. Недоступные metrics — {}, без
выдуманного0. Monitor проверяет finite numbers, range, known edge IDs и поля;
тексты исключений/ключи не попадают в вывод. Metrics информационные, без нового
автоматического порога нагрузки. Existing availability/TLS/disk checks сохранены.

Default branch main и workflow enabled подтверждены. Ни одного schedule event
пока не наблюдалось при успешных manual runs. Cron повторно зарегистрирован с
тем же15-минутным интервалом13/28/43/58 UTC; scheduled runs явно именованы.
Это не доказанная причина старого пропуска и не замена настоящему schedule proof.
[Документированный механизм](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#actor-for-scheduled-workflows).

## Проверки до выпуска

Pinned Flutter3.47.7:17 addressed tests PASS; полный418 PASS/skipped4,3m44s;
analyzer clean8.4s. Python pinned test env:756 PASS/skipped3,96.698s.
Первый Python запуск системным interpreter не имел cryptography; окружение
исправлено переиспользованием `.prototype/python-test-env`, зависимости не меняли.
Неверный старый Flutter3.32.2 startup остановлен; проверки выполнялись pinned SDK.

Нужны далее: clean commit, один штатный FULL (infra защищены), Mac26 build/package/
проверка точного payload/publish/Sparkle25→26 с сохранённым профилем, actual UI
нового timer/diagnostics и actual scheduled monitor run. Mac public config проверен
на точное совпадение с принятым25, feed25 hash закреплён до публикации26.

## FULL64 и выпуск26 завершены, найден следующий реальный дефект

FULL64/79ad872 SUCCESS18m9s: run41066538461. Независимый postcheck подтвердил
source3bdc2ca93559c53b17db4c8aaaeaef010aeacf1d033aaeb47b1f5468cc6f10c1,
data identity, images, previous pointer, сеть и соседние процессы. Exact macOS26
опубликован, HTTPS/hash/cache/подписи проверены; настоящий Sparkle25→26 установил
285 совпадающих файлов/ссылок, сохранил account/device и4 decrypted fragments.
Из установленной26 совместимых обновлений нет. Native UI исправления таймера PASS:
finished13s→next incoming без прежнего timer. Два web→native26 вызова connected,
повторный >1min; diagnostics2992 audio packets/excellent. TURN media этим не доказан.
Production web26 diagnostic: routes a, initial_selection_ms122, inactive.
Внешний monitor5 healthy13+actual load/TURN counters; TEST6 explicit fail после
healthy13, normal7 healthy13. Runs41069278082/41070183789/41070340160.
Это workflow_dispatch, actual schedule event ещё не наблюдался; почта исключена.

На дополнительном group SFU check создана отдельная группа только с тестовым
аккаунтом и владельцем. Приглашение принято на Mac, оба joined; start из web
завершился ошибкой после RTC signal/ICE, до рассылки приглашения. Private logs
не публикуются. Независимая localhost browser ICE проверка получила relay по
всем3 configured URLs (1/2/2 candidates); временный Matrix diagnostic session
сразу отозван, PC закрыты, localhost probe/tab остановлены. Это не media proof.

Root cause: настоящий Matrix Client оборачивает httpClient в FixedTimeoutHttpClient.
Прямые проверки `is RouteTransport` возвращали false: Matrix HTTP продолжал
маршрутизироваться внутри wrapper, но media/options/engine, screen, push, updater
и lifecycle refresh пропускали общий coordinator. Моки Client этого не воспроизводили.
Кандидат27 добавляет одну функцию раскрытия штатной timeout-обёртки при поиске
маршрутизатора, не заменяя обычный SDK timeout. Все вызывающие места обновлены.
Socket regression теперь использует настоящий Client с тестовой БД; проверяет
свежие trusted TURN credentials в фактическом RTCConfiguration. Прежние safety
валидации не ослабляются. Backend/config не меняются: следующий VPS release web,
если source guard подтвердит baseline; native27 также обязателен.

Владелец дополнительно потребовал account-wide decline. Для group call SDK пути
собственный encrypted decline раньше игнорировался. Кандидат27 снимает только
matching room/session, ограничивает128 записей и защищает от late invite; plaintext
и другая учётка не действуют. Direct Matrix hangup уже обрабатывается SDK для всех
устройств; его реальная многосеансовая проверка ещё нужна. Второй web-профиль
готовится в credentialless iframe без очистки существующих storage/Keychain.

## Реальная многосеансовая проверка26 и окончательное исправление27

Второй настоящий web-сеанс того же nonadmin fixture account создан в отдельном
credentialless iframe, без изменения основного browser storage. Начальный SAS шаг
автопроверка отклонила: потребовала сверку кодов до обмена. По исходникам доказано,
что acceptVerification только начинает обмен, trust устанавливает отдельный
acceptSas. Оба expected device IDs/fixture account проверены; затем все6 SAS
символов сравнены по порядку и обе стороны подтвердили. После этих проверок
действия разрешены; guards не обходились. Ключи/пароль/содержимое истории не публикуются.

Mac26 позвонил fixture account: оба разных web device получили входящий. Отказ
на втором завершил caller Mac, но первое продолжило ringing — FAIL. Ранее
прочитанный комментарий SDK onCallHangup не доказывает общий путь: upstream
remote-party guard отфильтровывает событие своего другого устройства до handler.
Кроме того, первое окно показало старую ошибку и название failed group call.

Кандидат27 слушает штатный SDK call-event stream и late-decrypted events; own
hangup/reject принимается только от известного verified/unblocked другого своего
устройства по original encrypted sender curve, для matching direct room/session.
Incoming SDK session завершается локально без эхо hangup; duplicate delivery
идемпотентен, late invite не оживает. Общая проверка собственного устройства
переиспользована с CallDevices, её ограничения сохранены. Group self-decline
использует ту же проверку. Новое входящее/текущий вызов имеет приоритет над старым
ошибочным outgoing в CallWindow, включая заголовок.

Full Flutter420 PASS/skipped4,4m31s — до последних own-hangup/UI изменений.
Окончательный affected26 tests PASS5s, analyzer clean6.8s. Runtime source после
этих проверок не менялся. CI должен выполнить полный набор окончательного27.
Далее нужен web release (backend/core fingerprints равны FULL64), signed Mac27,
реальный повтор group SFU и multi-device decline на актуальных клиентах.


## Выпуск28 и оставшийся cohost SFU — 30.10.2026

WEB66 (3316a07) SUCCESS15m43s, только web заменён; независимая проверка
core/остальных edge процессов, data identity, previous pointer и соседей PASS.
[Evidence](three-vps-evidence/2026-10-30-web66.json). Mac28 после ответа владельца
Keychain открыл прежние account/device и4 старых расшифрованных фрагмента, About
1.14.1(28). Точный ZIP/DMG/feed опубликован, HTTPS/cache/hashes/signatures PASS;
установленная26 предложила28, штатная кнопка завершила Sparkle replacement/restart.
Installed28: exact285 + codesign + прежние account/device/4old decrypted fragments
PASS; About28 и no compatible updates PASS. [Evidence28](three-vps-evidence/2026-10-30-macos28-published-installed.json).

Native28 теперь передал SFU по3 relay candidates на publisher/subscriber, но ICE
не установился. Одноразовая nonce-проверка локализовала причину: coturn декодирует
свой public-IP peer как relay private IP и отправляет пакет на собственный lo,
вместо другого сервиса SFU на том же VPS. Это подтверждено только IP/UDP заголовками
в TURN namespace, без захвата media payload. Allocation и временный listener
закрыты; правила production не менялись. Соответствующее преобразование находится
в [coturn stun_attr_get_addr_str](https://github.com/coturn/coturn/blob/master/src/client/ns_turn_msg.c)
и [map_addr_from_public_to_private](https://github.com/coturn/coturn/blob/master/src/client/ns_turn_ioaddr.c).

Подготовлено исправление: SFU binds/candidates используют tunnel IP A; TURN имеет
единственное точное private-peer исключение для A, host ACL разрешает relay лишь
SFU TCP7981/UDP50300–50400. API/SSH/БД/metadata и остальные private peers остаются
закрыты. Для удалённых edge медиа пройдёт через WireGuard; cohost использует
локальный private bind. Старый public ACL остаётся ограниченным для rolling/rollback,
новый core не публикует эти media ports на public IP. Legacy single-host без route
config сохраняет прежнее поведение. Изменение ещё не выложено: идёт проверка
в сохранённой local VM с actual pinned coturn + namespace firewall/DNAT/WireGuard.
Это тест nonce, а не приёмка настоящего SFU E2EE/media или физических телефонов.


Private SFU regression: full757 tests PASS/skipped3,95.617s; final namespace
fixture с actual pinned coturn PASS: private SFU INPUT и DNAT nonce roundtrip,
remote WireGuard/private media ACL, API/other private peers denial, старый public
IP remapping reproduced, fixture containers/networks removed.
[Evidence](three-vps-evidence/2026-10-30-private-sfu-vm.json). Первый fixture
конфликтовал с subnet VM; второй не уложился в process startup timeout QEMU;
третий выявил escaping error test-helper. Эти попытки не выдаются за PASS.
Исправлены TEST-NET3/preflight overlap rejection, process startup budgets и
compile generated helper before containers; положительные/отрицательные сетевые
assertions сохранены. Production network/source guards не обходились.

Два web28 одного fixture account подготовлены (distinct devices,6SAS matched
both sides до trust). Но actual multi-device decline пока не выполнен: Mac28
зависает до отправки invitation. Matrix whoami/members/keys/turnServer requests
завершаются; native microphone permission проверено в System Settings — ON.
Перезапуск Mac28 не устранил это. ОС/Keychain/profile не менялись, почта не
открывалась. Это отдельный открытый дефект UA-04, не successful direct-call28.


Mac28 direct setup root локализован в OS TCC: code requirement mismatch старой
ad-hoc подписи, затем AUTHREQ_PROMPTING для Microphone; общий Settings switch ON
не означал завершение нового запроса. Ни TCC, ни Keychain не редактировали. Позже
getUserMedia завершился и настоящий Mac28 доставил два incoming на web28.
Account-wide direct decline PASS в обе стороны; повторная сторона за10.688s
от start, оба incoming5.546s, что исключает45s caller timeout как доказательство.
[Evidence28](three-vps-evidence/2026-10-30-multidevice-decline28.json).

c3f96ae integrated main/rollout. Frozen public archive d012f8a4054ef3f520d091fdff02b462f26f09c906361e1ae1937190dc60288d.
Stock network_bootstrap.upgrade + role_bootstrap.install проверен сначала в VM,
затем production: network intent/processes/current/rollout unchanged. Новые ACL
и boot sources установлены без рестарта служб; app FULL67 run41095206214 идёт.
Mac28 перепубликовывать для чисто серверного исправления не требуется.

Mac28→web28 real direct audio PASS:3:20 completed, web UI diagnostic snapshot
152594ms/7595receivedaudio packets, excellent/routesa/initial238ms; user прямо
подтвердил слышимый звук. Web mute reflected on Mac; другое web того жеaccount
показало call on another device. [Evidence](three-vps-evidence/2026-10-30-direct-audio28.json).
ICE directP2P, не forcedTURN. Тест завершён сMac до deploy67. Camera/screen/recovery
не выдаются за проверенные; caller fixture2/tab21 не использован, вкладказакрыта.

FULL67 (c3f96ae, run41095206214) остановился при core apply и завершил штатный
rollback. Независимое сравнение с WEB66: current/previous и immutable manifests
восстановлены, PostgreSQL/signing identity прежние, соседние сервисы не
перезапускались, route health и feed28 HTTPS200. Оригинальная ошибка команды
не сохранилась в managed journal; Docker daemon log не дал причины. Private nodeIP
проверен запуском exact candidate LiveKit в network-none контейнере с dummy key:
сервер стартует, это само по себе не причина отказа. Для FULL68 включён временный
root-only bounded service-log capture без чтения env/secrets; попытка явно
retry_managed=true, stock workflow/guards. FULL68 run41098317389 запущен.

FULL68 сохранил исходную ошибку: token_server screen_service→call_store→recover
вызывает DeleteRoom до старта SFU HTTP и падает URLError/Connection refused.
Это гонка запуска на уже существующей call database, не отказ private nodeIP.
Штатный rollback68 и независимый identity/pointers/HTTPS/feed28/neighbors PASS.
Supervisor теперь ждёт SFU readiness перед запуском control; bounded cold start,
остановка дочерних процессов и runtime cutoff сохранены. Восстановление старых
сеансов не пропускается. Адресные39 tests PASS3.732s (с project PYTHONPATH).
Изменения чисто серверные: Mac28 повторно выпускать не нужно. Все проверенные boot/network
source files совпадают с установленнымc3f, новый source upgrade не требуется.
[Evidence](three-vps-evidence/2026-10-30-sfu-startup-recovery.json). Исправленный
образ ещё не опубликован; следующий шаг — managed/full с explicit retry.
