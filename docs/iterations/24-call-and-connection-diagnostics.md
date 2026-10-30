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
