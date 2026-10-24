# Демонстрация экрана — журнал реализации

Основание: [ТЗ](../screen-sharing-spec.md), [задачи](../tasks/08-screen-sharing.md).

## SS-16/A16 — 24 октября 2026: доступность статуса и клавиатуры

В production `ScreenPanel` ошибка захвата была видна, но не входила в live region:
новая widget assertion воспроизвела дефект до изменения. Исправление объединяет
текущий статус и notice в одном отдельном semantics node; визуальный notice исключён
из повторного чтения. Media, авторизация и lifecycle не изменялись.

Локальный target `lab_screen_accessibility_main.dart` использует реальные
CallWindow/ScreenPanel и синтетические viewer/owner/error/reconnecting состояния,
без credentials, Matrix/SFU и медиапотоков. Это UI fixture, не media proof;
в обычный релиз он не включается. Для повторения собрать этот target отдельно
с `--no-web-resources-cdn`, отдать на 7358 и запустить
`NODE_PATH=<runtime node_modules> PLAYWRIGHT_BROWSERS_PATH=/tmp/voicechat-screen-browsers
node prototype/check_screen_accessibility.cjs`. Пути/версии браузеров — как в SS-12 ниже.
Flutter web переносит announcement в временный `aria-live` text node на 300 ms;
runner наблюдает реальные mutations, а не ищет aria-live на самом Text. Каждая
проверка capture error очищает предыдущие сообщения, чтобы не принять старый статус.

Chrome 156, Edge 156, Firefox 153 и Playwright WebKit 26.5 последовательно PASS:
320×640 / 640×320 / 1280×900, named controls, динамический live error со статусом,
fullscreen/Escape оставляет звонок, disabled takeover при reconnect, quality и stop.
Каждый браузерный контекст подтвердил отсутствие backend/media requests.
`prototype/verified-screen-accessibility-browsers-run.json` содержит версии и хеши.
UI PASS Firefox не закрывает его отдельный media FAIL в SS-12.

Widget: 7 тем × 2 ориентации, текст 200%, reduced animations, Tab/Enter fullscreen,
Escape и восстановление фокуса, кнопка завершения остаётся в viewport. Отдельный
тест проверяет 4.5:1 для onSurface/surface, primary/surface, onSurfaceVariant/surface,
onError/error во всех семи принятых темах. Это точечные проверки, не полный WCAG audit.

В нативном Safari 18.3 CUA подтвердил названия controls, статус с текстом ошибки,
Escape из fullscreen без закрытия звонка, возврат фокуса, Tab к микрофону;
клавиатурные открытие звонка, выбор Auto → Low и stop обновляют доступный статус.
Нативная проверка использовала JS `2a3ec8e6…`, до добавления отдельной semantics
границы; финальная browser/widget проверка имеет собственные хеши.
VoiceOver временно включён с разрешения владельца (исходно off), процесс наблюдался;
попытки VO navigation/action через текущий инструмент не дали проверяемого курсора
или действия, speech не записан. Поэтому manual screen reader НЕ принят.
VoiceOver возвращён off, подтверждено через AX System Settings; остальные настройки
диктора не менялись, собственная Safari-вкладка закрыта. Свидетельство:
`prototype/verified-screen-native-accessibility-run.json`.

Чистая финальная копия клиента: все 136 Flutter tests, analyze и обычный release JS
PASS. Отдельный fixture target не попал в `main.dart.js`; fixture.json/source.html
отсутствуют. Lockfile и CallWindow совпадают с committed baseline; параллельный
UI/VPS diff исключён. Артефакт — `/tmp/voicechat-screen-accessibility-release-web`,
хеши и границы — `prototype/verified-screen-accessibility-build-run.json`.
Генерированные crypto/scanner assets переиспользованы из закреплённого результата,
холодная Rust/WASM сборка не проверялась.

Очистка PASS: собственные 7358/7362 остановлены, fixture JSON/SS-01 SFU rooms/feature
flags отсутствуют, metadata ended=60, active/pending/retired=0; общий Compose и тома
сохранены, прежние два release JS не изменены. Свидетельство:
`prototype/verified-screen-browser-accessibility-cleanup-run.json`.

Android, физические мобильные браузеры, OS picker/Stop и тяжёлая нагрузка не
запускались. SS-A16 остаётся PARTIAL до реального принятого озвучивания/VO-навигации
и матрицы целевых устройств; release BLOCKED.

## SS-12 — 24 октября 2026: дополнительные desktop браузеры

Закреплённый Flutter/LiveKit lab на clean `55d8a77`, без текущего design/VPS diff.
Последовательно, 2–3 участника, общий loopback SFU; настоящая вкладка Chrome/Edge,
синтетические микрофон/камера. Matrix-доставка ключа здесь не проверяется.

- Edge 156.0.4314.42 ↔ Chrome 156.0.8078.47: отправка и просмотр PASS.
- Playwright WebKit 26.5: просмотр от Chrome PASS; это отдельная тестовая сборка,
  она не заменяет установленный Safari.
- Нативный Safari 18.3 (20620.2.4.11.5), macOS 15.3.1: просмотр через CUA PASS.
  Видимые кадры источника/камеры и растущие счётчики; 101/90 → 221/210 кадров.
- Firefox 153.0 (Playwright build 1538): FAIL при подготовке SDK media connection,
  `failed:minified:ym`, нет принятой расшифровки/кадров. ScriptTransform/SAB присутствуют;
  это не доказательство совместимости. Временный профиль с loopback ICE preference
  также не прошёл. Причина не установлена; не объявлять весь Firefox несовместимым.

Во всех принятых направлениях без ключа и после явной установки неверного ключа —
0 screen/camera кадров. Автоматические прогоны также проверили продолжение camera
и voice packet counters после удаления отдельной screen room. Safari: положительный
контроль после отрицательных случаев снова показывает изображение. Это SDK/media
проверки, не полная обычная UI/Matrix приёмка каждого браузера.

Edge извлечён из официального vendor pkg во временный каталог, SHA256 сверен с
официальным API; системный установщик не запускался. Firefox/WebKit загружены
Playwright в `/tmp`; пользовательские профили не используются. Fixture rooms удалены,
секретный fixture JSON удалён; безопасные записи — `verified-screen-browser-*-run.json`
и `verified-screen-native-safari-run.json`. Повтор: собрать `lab_screen_main.dart`
в каталог `/tmp/voicechat-screen-browser-probe-web`, запустить `serve_web.py` на 7362;
`VOICECHAT_SCREEN_PROBE_DIRECTORY` задаёт тот же каталог, затем
`NODE_PATH=<runtime node_modules> PLAYWRIGHT_BROWSERS_PATH=/tmp/voicechat-screen-browsers
node prototype/check_screen_browsers.cjs <edge|firefox|webkit|safari> [sender|viewer]`.
Для Edge путь к извлечённому `.app` хранится в `/tmp/voicechat-screen-browsers/edge-path`;
`sender` допускается только для Edge; Safari требует ручного CUA наблюдения и Enter
после него, автоматического PASS не выдаёт. Нативное наблюдение сохраняется отдельно.

Ручной capture picker, window/monitor, системный Stop, Safari/Firefox отправка,
обычный клиент/Matrix в этих браузерах, мобильные устройства и внешняя сеть остаются
открытыми. Android и тяжёлая нагрузка не запускались. SS-12 PARTIAL; release BLOCKED.

## SS-16 — оставшаяся локальная регрессия обычного клиента

**PASS** на чистом `4df481d` с одним исправлением production-кода: удалён
неиспользуемый hint списка качества видео. Flutter учитывал его ширину даже при
выбранном значении, что давало overflow на 320 px при тексте 130%. Вариант с
растягиванием списка нарушал компоновку обычного звонка и не принят. Итоговый
вариант прошёл analyze, все **135 Flutter tests** и release web build (85.1 с).
Чужие pending UI/VPS изменения, зависимости и lockfile не включены; готовые pinned
crypto/scanner assets переиспользованы, cold Rust/WASM build не заявляется.

Два обычных Chrome клиента: согласия/приглашения, direct replies/reactions,
muted unread counts/read receipts, новый group text; файлы в direct и group
скачаны через UI, расшифрованные bytes точно совпали с разными исходными payloads.
Все 7 тем выбраны через UI: значения записаны в localStorage, PNG подтвердили
7 разных основных цветов и ожидаемую светлую/тёмную яркость. Чат проверен на
320×640, 390×844, 640×320. Для живого group screen на этих размерах кнопка
«Завершить» остаётся видимой, screen-действия доступны через прокрутку content;
fullscreen/возврат сохраняют звонок. A использует Midnight, B — Lavender Soft.

Личный P2P и групповой video call: реальный tab capture, разные пиксели A/B,
Matrix E2EE, cancel/takeover/stop/Low/Auto/fullscreen и feature off; voice peers
сохраняются. В обоих звонках камера выключена/включена, mic muted/unmuted,
screen pixels остаются. После republish сравнивается рост **новых** RTP counters,
а не их абсолютное значение до замены stream; после resize media продолжаются.

Widget-проверки обеих ориентаций расширены на все 7 тем; окно звонка — с text
scale 1.3 и disableAnimations. Tab достигает fullscreen, Enter открывает его,
возврат не закрывает screen controller. DOM activeElement у Flutter Canvas не
используется как доказательство Flutter focus. Это не приёмка screen reader.
Ранее принятые audio-only/mute/no-camera и Matrix device revoke не переписаны;
их media/authorization controllers совпадают с принятым caecb3c.

Команда: обычный clean web на 7358, local control 8090 с
`VOICECHAT_SCREEN_FLAG=/tmp/voicechat-screen-test-enabled`, существующие Matrix/SFU;
`NODE_PATH=/path/to/existing/node_modules python3 prototype/run_screen_regression.py`.
Нужны Playwright/pngjs и установленный Chrome. Runner проверяет health до создания
аккаунтов, сохраняет прежний calls report и удаляет временный flag в finally.
Основной отчёт требует PASS обеих calls и деактивацию 3 fixture accounts.
Три аккаунта раннего запуска без API и временный cleanup admin тоже деактивированы;
первые FAIL и прерванные прогоны не считаются приёмкой.

[Сквозная регрессия](../../prototype/verified-screen-regression-run.json),
[источник/сборка](../../prototype/verified-screen-regression-build-run.json),
[очистка](../../prototype/verified-screen-local-regression-cleanup-run.json).
Постоянный flag отсутствует, release BLOCKED. Android, тяжёлая нагрузка, другие
реальные браузеры/OS picker/Stop, screen reader и целевой VPS screen rollout не
проверялись. SS-16 локально принят; полная межплатформенная приёмка остаётся PARTIAL.

## SS-15 — локальное обновление существующих томов и безопасный откат

**PASS, 193.480 с.** Реальный baseline control из pre-screen `c3e3f43` →
текущий pinned local image → baseline. Отдельный Compose project с новыми тестовыми
томами; при обеих сменах image используются **те же** named volumes. Перед каждой
сменой writers остановлены, production backup/check выполнен, SQL counts,
signing key и terminal tombstone сохранены. До upgrade в calls.sqlite подготовлена
схема screen v1 с ended binding; текущий сервер мигрирует её до v2. Это metadata
fixture на pre-screen коде, не действующая старая screen generation.

До upgrade созданы настоящие encrypted text/file и E2EE voice/camera call.
После upgrade: screen off, принудительное чтение серверной истории и реальный
скачанный/decrypt файл; затем новые text/file, screen on и видимые пиксели у зрителя.
Ранний ручной rollback отвергнут fixture при active screen. Flag=0 закрывает root
capture/кадр и старую room, active/pending/retired=0, основные voice PC сохраняются.
После следующего backup baseline запущен на тех же данных: **без restore старой БД
и без downgrade v2**. Старый код корректно возвращает 404 capability, обычный звонок
работает; оба набора encrypted text/file прочитаны после rollback, файл, созданный
после upgrade, действительно скачан. Capture автоматически не начинается.

Сохранены те же encrypted client vaults. При переключении flag пересоздаётся звонок,
без лишнего reload Matrix-клиента; SDK-команды ограничены 60 с. Предварительные
FAIL/прерванные прогоны на пересоздании lab-клиентов не засчитаны; принят полный
повтор от пустого проекта с cleanup=true. 29 screen и 10 deployment tests PASS;
lab analyze/release PASS. Все частные проекты/тома/аккаунты удалены.

[Отчёт](../../prototype/verified-screen-security-operations-run.json),
[команда и границы drill](../../infra/README.md#локальная-проверка-обновления-существующих-томов).
Guard раннего rollback находится в fixture и проверяет **ручной runbook**;
production deploy coordinator, registry manifest/target config и точная старая
версия клиента не проверены. Общий stand и VPS не изменялись. Android и тяжёлая
нагрузка не запускались; release BLOCKED и default off сохраняются.

## SS-15 — полный локальный Compose backup/restore

**PASS, 129.137 с**, отдельные source/target Compose projects и
непересекающиеся новые тома; общий prototype/VPS не изменялись. Fresh installation
подняла Synapse/PostgreSQL/control+SFU/Caddy/TURN и локальный mail sink. Два реальных
SDK клиента создали encrypted text/file и живую E2EE screen generation.

Пишущие сервисы остановлены; существующий production backup создал согласованный
Restic snapshot и выполнил check. Исправлен реальный недостаток backup: вместо
жёстких `voicechat_*` используются фактические volume names из Compose config,
включая override/project name. Unit проверяет отдельный prefix; default deployment
сохраняет прежние имена. Secret config JSON не выводится.

Восстановлен конкретный snapshot ID: SQL в пустой PostgreSQL, пять файловых томов
с byte-for-byte проверкой, UID/GID/permissions и signing key; три SQLite прошли
integrity_check. Release, runtime env и compose override взяты **из backup**.
Пароль Restic не находится в snapshot. До control startup flag принудительно=0.
Snapshot действительно содержал active screen; после startup active/pending/retired=0,
старой комнаты нет. Actual media keys не найдены в control SQLite/WAL и развёрнутом
SQL (`pg_restore --file=-`), screen JWT отсутствует в control.

Свежий password login успешен. После закрытия/reload SDK браузер принудительно
прочитал encrypted events с восстановленного сервера, расшифровал текст и реально
скачал/расшифровал файл (не только local cache). Сохранён исходный encrypted client
vault; восстановление истории при его потере не заявлено. Основной group E2EE
voice/camera работает при screen off. Reload не запускает capture.

После явного screen enable создан **новый call_session**, новый показ виден зрителю.
Выключение очищает screen и сохраняет основные voice PC/растущие media counters.
Первая попытка неверно повторила terminal call_session: сервер правильно вернул
410; она не засчитана. Полный повтор от новых пустых томов прошёл и удалил оба
проекта/тома/аккаунты. Никаких пользовательских данных в drill нет.

Для независимой проверки старой room через длительный restore JWT fixture меняет
только expiry старого grant на 600 с, подписывая секретом **одноразового** SFU.
До expiry независимый SDK отвергает этот токен после restore. Production TTL=60 с
не менялся; предыдущие короткие fault-прогоны отвергали настоящие unmodified JWT.

10 deployment unit tests PASS, 29 screen tests PASS, lab analyze PASS/release build
65.7 с. [Полный безопасный отчёт](../../prototype/verified-screen-security-restore-run.json).
Команда: `node prototype/check_screen_security.cjs restore` с существующим NODE_PATH,
lab web на 7363 и локальными образами; подробности в infra runbook.

**Принят полный локальный backend/application restore, не production rollout.**
Registry manifest, отдельный upgrade/rollback на целевых volumes, точная старая
клиентская версия, публичные DNS/SMTP/ACME/TURN остаются внешней приёмкой.
Android и тяжёлая нагрузка не запускались; default off и release BLOCKED сохранены.
[Финальная очистка](../../prototype/verified-screen-operations-cleanup-run.json):
9 fault cohorts + full restore PASS, частные контейнеры/тома и lab server удалены,
общий stand сохранён, active/pending/retired=0, production JS не изменён.

## SS-10 / SS-16 — локальная fault-матрица завершена

**PASS**: `network` 26.810 с, `after_create` 32.929 с, `after_delete` 33.893 с, `lease` 55.438 с, `kick` 23.510 с.

Короткий реальный обрыв SFU WebSockets и HTTP A: после восстановления получен
свежий grant, растут decoded frames, остаются прежние generation и root capture.
При следующем отключении B перехватил экран; вернувшийся A закрыл capture,
получил viewer grant и увидел пиксели B, без автоматического claim. Это отказ
сигналинга/control, не измерение потерь UDP или внешней сети.

Для CreateRoom/DeleteRoom production API wrapper вызывает настоящий pinned SFU,
затем однократно теряет ответ уже выполненной операции. Клиент закрывает
неопределённый capture; durable intent восстанавливается и компенсируется.
Нет ложного success, active/pending/retired=0, старый root/кадр исчезают.
Явный новый запуск B создаёт один рабочий encrypted screen, A видит B; основные
voice PC не заменяются, voice/camera counters растут.

Блокировка только screen HTTP A оставляет основной voice/video call живым:
истекают клиентский допуск и серверный lease, capture закрыт, room удалена,
независимый SDK отвергает unexpired old JWT. B может явно начать новый показ.
Настоящий Matrix kick зрителя B ротирует screen generation/roster; ведущий A
продолжает тот же capture, B не получает новый ключ/grant и не входит старым JWT.
Вместе с предыдущими late join, добровольным leave и device revoke это закрывает
локальный roster/recovery scope SS-10. OS Stop, Android и внешние сети остаются
своими отдельными gate, нагрузка не запускалась.

Observer исправлен окончательно: копия реального fetch response читается внутри
тестовой вкладки до передачи SDK; body/JWT сохраняются только в памяти Node/browser.
Это не proxy и не подмена ответов, offline продолжает блокировать реальные запросы.
Чтение response body через DevTools иногда зависало, хотя SDK получал ответ.
Первоначальное ожидание автоматической публикации после SFU 503 было ошибкой
теста: безопасный контракт — локальный abort и компенсация, затем явный retry.
Production-код не менялся. 29 Python screen tests повторно PASS.

Все fixture accounts/rooms/private databases очищены. Lab target для kick
прошёл analyzer и release build 65.7 с; хешы source/JS находятся в отчётах.
Ранее четыре container fault-прогона сохранены отдельным коммитом 0d1bb10.
Следующий этап — полный Compose backup/restore SS-15.

- [network](../../prototype/verified-screen-security-faults-network-run.json)
- [after_create](../../prototype/verified-screen-security-faults-after_create-run.json)
- [after_delete](../../prototype/verified-screen-security-faults-after_delete-run.json)
- [lease](../../prototype/verified-screen-security-faults-lease-run.json)
- [kick](../../prototype/verified-screen-security-faults-kick-run.json)

## SS-10 / SS-16 — живые restart, crash и health watchdog

**Локально PASS**: `restart` 32.996 с, `kill_control` 47.233 с, `kill_sfu` 50.911 с, `pause_control` 41.741 с.
Два настоящих Matrix SDK участника, group voice/video и видимые пиксели E2EE
экрана; отдельный pinned control/SFU container, private SQLite и loopback-порты.
Общий Synapse/SFU и пользовательские звонки не останавливались.

После restart, SIGKILL control, SIGKILL SFU и SIGSTOP control supervisor
останавливает медиаконтекст; root capture закрыт, старый кадр скрыт. После запуска
нет active/pending/retired, ListRooms подтверждает отсутствие старой generation,
независимый SDK отвергает сохранённый **ещё действующий** JWT. Автоматического
захвата нет. Групповой голос при сбое общего SFU прерывается; продолжение голоса
в этих сценариях не заявляется. Для отказа только screen control есть отдельные
предыдущие свидетельства.

Исправлены только fixtures: стабильные опубликованные порты при Docker restart,
право roomList для ListRooms, формирование argv без NUL. SIGTERM LiveKit является
штатным drain, поэтому crash проверен SIGKILL. Ошибки setup/observer и очистки
не засчитывались как PASS; observer больше не ждёт дополнительный allHeaders RPC.
Все четыре принятых прогона завершили очистку контейнера/БД/аккаунтов.

Команда: `node prototype/check_screen_security.cjs faults SCENARIO` с имеющимся
NODE_PATH и lab web на 7363; lab target анализатор PASS, release build 40.4 с.
29 screen Python tests PASS; первый sandbox-only запуск не мог открыть loopback
и повторён с разрешённым bind. Android и нагрузка не запускались.

Короткий сигналинг-обрыв, unknown SFU outcomes и silent lease — следующая
локальная итерация. Restore/внешняя приёмка ещё не закрыты.

- [restart](../../prototype/verified-screen-security-faults-restart-run.json)
- [kill_control](../../prototype/verified-screen-security-faults-kill_control-run.json)
- [kill_sfu](../../prototype/verified-screen-security-faults-kill_sfu-run.json)
- [pause_control](../../prototype/verified-screen-security-faults-pause_control-run.json)

## SS-11 — локальная итерация 4: доверие не заменяет допуск к звонку

**PASS** для двух отдельных cohorts: член чата вне звонка (**19.652 с**)
и дополнительное устройство уже звонящего пользователя (**31.559 с**).
В каждом — два настоящих voice/video участника и третья idle SDK-сессия с реальными
Curve25519/Ed25519 keys. Все устройства явно вручную проверены друг у друга.
Третье устройство не вызывает CallProbe.connect и не получает call lease.

Контрольная безвредная Olm-посылка A → excluded device реально расшифрована:
синхронизация/криптография у него работают. Тем не менее запрос screen token с его
собственным SDK bearer отклонён (404), ни один screen generation key ему не пришёл.
Повторно пройдены takeover/stale commands, original/refreshed JWT rejection,
viewer-only grant прежнему ведущему и независимый отказ подменённому JWT с изменёнными
identity/canPublish. Картинка B и основные voice PC/media counters сохраняются.

Уточнён тестовый collector: GET login flows не принимается за POST login session;
поздний ответ не перезаписывает более новую revision, 202 claim учитывается как
наблюдаемая команда. Условие готовности проверяет новый request_id и publisher
context, не требует случайного совпадения времени двух HTTP observer callbacks.
Чтение response при закрытии context не порождает необработанный Promise rejection.
Cleanup больше не пропускает аккаунты при ошибке закрытия fixture и отражает ошибку
в результате, вместо ложного PASS. Изменений production-кода не потребовалось.

Один промежуточный runner оборвался в асинхронном observer при закрытии браузера.
Восстановительная проверка очистила три оставшихся **только тестовых** аккаунта по
точному prefix/role pattern. Одноразовый local cleanup admin деактивирован, активных
fixture accounts не осталось; другие пользователи не затронуты.
[Cleanup report](../../prototype/verified-screen-security-cleanup-run.json).

Свидетельства: [член чата](../../prototype/verified-screen-security-commands-member-run.json),
[второе устройство](../../prototype/verified-screen-security-commands-device-run.json).
Полные хеши lab source/JS и production base commit находятся в каждом отчёте.

```sh
NODE_PATH=/path/to/existing/node_modules node prototype/check_screen_security.cjs commands member
NODE_PATH=/path/to/existing/node_modules node prototype/check_screen_security.cjs commands device
```

**Локальная web-часть SS-11 завершена.** Четыре итерации не меняют production API,
контроллеры, зависимости или feature flag. Лаборатория не включена в production JS.
Android и тяжёлая нагрузка не запускались; target browser/device/network матрица,
оставшиеся SS-10/SS-16 fault фазы и полный restore остаются release gates.
Прежний SS-17 preflight дополнен ссылками на новые свидетельства, а не выдан за
разрешение включать screen share. Постоянный flag отсутствует, default off сохранён.

## SS-11 — локальная итерация 3: raw SFU signaling и недопустимые tracks

**PASS, 55.376 с**, production controllers 56efbb1, настоящий Matrix group call,
private control API/SQLite и pinned SFU. SDK `engine.addTrack` отправляет raw
сигнал напрямую, обходя LocalParticipant/UI helpers. Реально отвергнуты:
камера владельца в screen room; SCREEN_SHARE в voice room; публикация зрителя.
После каждого отказа в screen room остаётся ровно один SCREEN_SHARE/GCM track,
правильные пиксели видны B, обычные voice/camera продолжаются.

Следом приняты и отозваны настоящие недопустимые публикации: duplicate screen track
и plaintext track независимого Room без cryptor. Производственный metadata watcher
удаляет room, штатный owner освобождает root capture; old frame скрыт, voice PC
не заменяются и media counters растут. Для plaintext используется тот же ещё
действующий owner JWT в raw Room; браузерные screen API запросы A блокируются
на время атаки, чтобы controller не восстановил штатный encrypted Room раньше
проверки. Серверные наблюдения идут напрямую и не блокируются.

Чтобы доказать именно серверный guard, B заранее покидает только screen binding,
оставаясь в живом voice/video call. A проходит нормальную roster rotation и
действительно публикует новый одиночный track до атаки. Screen roster в этих двух
metadata-проверках содержит только A, voice call — A/B. Это исключает ложный PASS
от быстрого локального unbind честного зрителя при обнаружении duplicate.

Предыдущая plaintext fixture не принята: отключение cryptor в защищённом Room с
`discardFrameWhenCryptorNotReady` не создаёт требуемую открытую трансляцию, а
отбрасывает кадры. Заменена на независимый нешифрующий Room, production-код не
менялся. Raw tracks/rooms закрываются в finally, fixture удаляет свою SQLite/SFU.
[Отчёт](../../prototype/verified-screen-security-publish-run.json) содержит роли,
типы проверок, ограничение roster и хеши; tokens/keys/media в него не записываются.

```sh
NODE_PATH=/path/to/existing/node_modules node prototype/check_screen_security.cjs publish
```

Остаётся отдельная локальная проверка trusted crypto-capable устройств вне звонка
и дополнительных устройств участника. Android и тяжёлая нагрузка не запускались.

## SS-11 — локальная итерация 2: настоящий Olm replay и граница cryptor

**PASS, 28.299 с**, тот же production-код 56efbb1, отдельный lab target и private
API/SQLite. A → B → A создаёт новое screen generation. Нормальная отправка нового
ключа A временно удерживается тестовым HTTP adapter; ручные тестовые посылки идут
через настоящий `sendToDeviceEncrypted` и Matrix, с реальным Olm sender/device.
У B подтверждены новая room, отсутствие корректного ключа и 0 decoded frames.

**15 отрицательных случаев доставлены реально**: точный ещё действующий старый
envelope в новом Olm-сообщении; старое generation с новым expiry; другая room/call/
binding; старые revision/roster; подмена sender/device; expired/слишком долгий expiry;
неверный key/base64 и boolean protocol; plaintext screen envelope; screen envelope
в voice-key channel. Plaintext случай использует фиктивные 32 байта, не настоящий
медиаключ. Для каждого случая наблюдается отсутствие `setKey` в экранный cryptor
и неизменный голосовой ключ. До положительного контроля остаётся 0 decoded frames.

Правильный текущий raw key берётся только в памяти с фактической границы sender →
cryptor worker. Валидный envelope, отправленный тем же authenticated Matrix SDK,
действительно устанавливает его у B, даёт >5 расшифрованных кадров и правильный цвет
на PNG всего Flutter UI. Voice/camera counters растут, их PC не заменяются.

Первый способ измерения через SDK `exportKey` оказался непригоден: pinned WebCrypto
material неэкспортируем, API возвращает пустой результат. Положительный контроль
не прошёл и не позволил принять такой прогон. Теперь тест наблюдает реальные
`Worker.postMessage(setKey)` по provider/participant, не подменяя cryptor. Значения
не пишутся в DOM, console или отчёты. Лабораторный bridge отсутствует в production JS.

Проверены тела control и Matrix sendToDevice запросов: действующих ключей в открытом
виде нет (Olm ciphertext допускается). В отдельной SQLite и её WAL нет raw/base64
медиаключей, SFU JWT и Matrix bearer. Сам scanner сначала нашёл известный безопасный
schema marker — отрицательный контроль против фиктивного PASS. Source review:
production `Handler.log_message` отключён; private fixture не пишет HTTP bodies/
headers в logs. Это локальная проверка границ, не аудит всех production лог-систем.
Отчёт содержит только safe booleans/названия случаев/хеши:
[key replay](../../prototype/verified-screen-security-keys-run.json).
Изменения затронули только лабораторию/fixtures; production-код не менялся.

```sh
NODE_PATH=/path/to/existing/node_modules node prototype/check_screen_security.cjs keys
```

Android, браузерная матрица и нагрузка не выполнялись; SS-11 целиком ещё не закрыта:
дальше проверяются raw SFU signaling и реальные недопустимые публикации.

## SS-11 — локальная итерация 1: команды и сохранённые JWT

**PASS, 31.019 с**, Chrome 156, отдельный laboratory entrypoint, production-код
контроллеров из 56efbb1, настоящие Matrix/Olm/LiveKit и capture тестовой вкладки.
Собственные control API/SQLite удалены после теста; общие службы не перезапускались.
Камера/микрофон синтетические, Android/нагрузка не запускались.

A начал показ, затем B перехватил. Отправлены старый stop, новый claim старой revision,
повтор request_id с другим телом, старый token request, чужой lease и body identity,
подменённое generation. Отказы не изменили revision/generation/owner B. Повтор
успешного старого claim вернул квитанцию и текущий snapshot, не вернул владение A.
Пиксели B видны у A, входящие voice/camera растут, основные PC не менялись.

Независимый SDK Room не подключился с сохранёнными original и действительно
обновлённым SDK JWT до их expiry. Старая room отсутствует по ListRooms. Новый token
для A относится к текущей комнате и имеет только viewer grant без publish/data.
Член чата вне звонка и другая Matrix login-сессия не получили grant (404); последняя
не имела собственного call lease, это не приёмка всех вариантов доверия устройств.
Bind другого call_session с настоящим lease текущего звонка отклонён (403/410).
Direct bind только одной стороны остался pending, token отклонён (403).

Подготовка fixture сначала не прошла: контакты должны записываться в общий сервис,
который проверяет Synapse; приватный control используется для звонков и screen.
Лаборатория также настраивает свой Origin и вручную сверяет реальные отпечатки
двух SDK-устройств до connect. Неуспешные setup/assertion прогоны не выданы за
продуктовые дефекты или PASS. Изменений production-кода не потребовалось.

Новый `lab_screen_security_main.dart` — отдельная тестовая цель с командами для
негативной приёмки; она не импортирована production entrypoint. Ключи/credentials/JWT
живут только в памяти, не включаются в отчёт. Привязка: SHA256 source/JS в
[commands report](../../prototype/verified-screen-security-commands-run.json).
Тестовые команды генерации/публикации и key gate также остаются только в лаборатории.
Дальше — encrypted key replay и реальные SFU publish/source/metadata отказы.

```sh
NODE_PATH=/path/to/existing/node_modules node prototype/check_screen_security.cjs commands
```

Перед запуском нужны общие loopback Matrix/contacts/SFU, generated crypto assets и
отдельный web server :7363 со сборкой `--target=lib/lab_screen_security_main.dart`.
`fixture.json` отдаётся только одноразовому browser context через route, на диск
с credentials не записывается. Все аккаунты деактивируются в finally.

## SS-17 — 23 октября 2026: локальный preflight, включение отложено

**Local preflight PASS, release BLOCKED.** Зафиксирован клиент caecb3c,
проверочный commit 6c37d84, JS SHA256, local control image ID и соответствие всех
16 source files образу. У локального образа нет registry digest; production web
image/публичная конфигурация не приняты. Protocol v1, screen SQLite v2, deployment
manifest schema=1 — отдельные версии. Локальный release artifact обновлён на
caecb3c; прежний 691a0fc сохранён отдельно, не подменён в историческом отчёте.

После сценариев schema=2, ended=52, active=0, pending=0, retired=0. SDK fixture,
временный flag и два screen-only web сервера убраны. Постоянный flag не создавался;
общий локальный app/API/Compose и volumes оставлены для параллельной работы.
Production в этой итерации не обновлялся. Общую схему и deploy на VPS можно готовить
параллельно, сохраняя screen off; работа другого агента не включена в screen-коммиты.

[Preflight artifact](../../prototype/verified-screen-preflight-run.json) содержит
семь групп gate: оставшаяся hostile/key-replay/fault матрица; Android/браузеры/OS Stop;
внешняя сеть/TURN; разрешённая нагрузка; полный application restore/rollback;
остаточная messages/files/theme/accessibility регрессия; приёмка целевого стенда.
Подробный порядок включения/отключения — [матрица](../screen-sharing-acceptance.md#локальная-подготовка-включения--ss-17)
и существующий infra runbook. SS-17 целиком не закрыта: локальная сборка и подготовка
общего VPS не являются приёмкой показа экрана на всех согласованных платформах.

## SS-16 — 23 октября 2026: чистый кандидат, видимый экран и реальные сбои

Клиент **caecb3c** собран из отдельного `git archive`, без незавершённого дизайна
и VPS diff. Flutter 3.47.7, Chrome 156.0.8078.47, release JavaScript, SDK 2.13.1.
Проверены **135 тестов**: 134 PASS в общем прогоне, один QR-тест сначала не нашёл
каталог вывода `.prototype`; после создания каталога его отдельный повтор PASS.
Analyze чистый, JS build PASS (**51.8 с**). Lockfile совпал с commit; **55 файлов**
release не содержат fixtures/SQLite/локальных инфраструктурных secret values.
Готовые закреплённые crypto/scanner assets переиспользованы; cold Rust/WASM build
не проверен. SHA256 JS: `4a3af9a1c9d1f6ed10092e74cf048f6ca223506549af713f2f5c9e258032b790`.

Проверка renderer усилена: установленный flutter_webrtc скрывает DOM `<video>`
и рисует его во Flutter Canvas. Теперь assertion анализирует PNG всего реального UI,
а не только декодер скрытого video. У A/B/C разные контрольные цвета; автоматический
picker получает ровно один источник с подходящим title. После stop проверяется
исчезновение последнего цвета. Эти кадры — тестовая вкладка; камера/микрофон
синтетические, физический монитор/системный picker/телефон этим не приняты.

На новом кандидате **PASS**:

- Personal/group video: Matrix E2EE, видимые кадры правильного источника, отмена
  picker сохраняет ведущего, перехват, остановка старого root, fullscreen, Low/Auto.
  В voice PC растут audio/camera counters; сами PC не заменяются.
- Потерянный HTTP reply: сервер принял claim, browser route удалил ответ; повтор
  сохранил request_id/revision/generation, capture остановлен, следующий показ работает.
- Два подготовленных capture одной revision отправляют claims параллельно: 200/409,
  один root остаётся live; проигравший освобождает свой и видит победителя. Picker
  выполнялся последовательно ради focus, конкурентными были серверные команды.
- Поздний C принимает group call во время экрана A: screen generation меняется,
  старая room удалена, B/C получают кадры A. У A остаётся тот же единственный root
  capture, второй picker не нужен. Затем A → B → C, бывшие ведущие видят новый цвет,
  voice/camera сохраняются у всех троих; Stop освобождает все roots. **38.006 с**.
- Настоящий временный feature flag=0 прекращает capture/renderer, сохраняя group
  voice/camera. Постоянный flag проекта не создавался, default off сохранён.
- Удаление текущего Matrix-устройства ведущего во время group screen — **2.342 с**:
  новый token получает 401, реальный кадр скрыт, старая room отсутствует, независимый
  SDK отвергает сохранённый unexpired JWT. Добровольный screen unbind заблокирован;
  отозванный UI закрывает root capture, оставшийся участник публикует новое поколение.

На предыдущем чистом клиенте **10b97ee** отдельно приняты сбои с живым E2EE-экраном:
private API использует настоящие production modules/SQLite/SFU, но отдельную БД и
proxy к Matrix. Отказ Matrix только для screen control (**31.005 с**) и restart
этого API с тем же SQLite (**1.120 с**) прекращают захват, скрывают кадр, удаляют
room и отвергают ещё действующий JWT в независимом SDK. P2P voice/camera продолжаются,
автозахват не начинается, retired rooms=0. Общий Synapse/SFU не останавливались;
совместная авария контейнера с media и полный перебор фаз этим не приняты.

Исправления device cache и SDK reconnect подтверждены тестами до/после и новыми
сквозными повторами. Дополнительный исходный group отказ на 10b97ee после успешного
personal был конфликтом старой revision перед claim; его исправление и red test
описаны ниже. Отдельный ранний PARTIAL отчёт 2abf4a7 сохранён как история, а не
переименован в PASS. Конечные результаты и commit каждого сценария —
[регрессия](../../prototype/verified-screen-subscription-regression-run.json),
[матрица](../screen-sharing-acceptance.md). Полная приёмка SS-16 остаётся PARTIAL:
внешние платформы/сети/нагрузка, ручная доступность, полный restore и остаточная
негативная матрица не закрыты. Android не собирался и не запускался.

Команды UI (последовательно, `NODE_PATH` указывает на имеющийся Playwright/pngjs;
`:7358` обслуживает чистую сборку, `:7362` — SDK probe):

```sh
VOICECHAT_UI_URL=http://localhost:7358/ VOICECHAT_SCREEN_TEST=1 VOICECHAT_VIDEO_TEST=1 VOICECHAT_SCREEN_THREE_TEST=1 node prototype/check_contacts_ui.cjs
VOICECHAT_UI_URL=http://localhost:7358/ VOICECHAT_SCREEN_TEST=1 VOICECHAT_VIDEO_TEST=1 VOICECHAT_SCREEN_CONCURRENT_TEST=1 VOICECHAT_SCREEN_LOST_REPLY_TEST=1 VOICECHAT_SCREEN_TEST_FLAG=/tmp/voicechat-screen-test-enabled node prototype/check_contacts_ui.cjs
VOICECHAT_UI_URL=http://localhost:7358/ VOICECHAT_SCREEN_TEST=1 VOICECHAT_VIDEO_TEST=1 VOICECHAT_SCREEN_GROUP_ONLY=1 VOICECHAT_SCREEN_REVOKE_TEST=1 node prototype/check_contacts_ui.cjs
VOICECHAT_UI_URL=http://localhost:7358/ VOICECHAT_SCREEN_TEST=1 VOICECHAT_VIDEO_TEST=1 VOICECHAT_SCREEN_DIRECT_ONLY=1 VOICECHAT_SCREEN_FAULT_TEST=matrix node prototype/check_contacts_ui.cjs
VOICECHAT_UI_URL=http://localhost:7358/ VOICECHAT_SCREEN_TEST=1 VOICECHAT_VIDEO_TEST=1 VOICECHAT_SCREEN_DIRECT_ONLY=1 VOICECHAT_SCREEN_FAULT_TEST=restart node prototype/check_contacts_ui.cjs
```

Fault-команды создают/удаляют собственный API/SQLite/proxy. Последние две в этой
серии выполнялись на 10b97ee; остальные на caecb3c. Для UI-прогонов нужен отдельный
временный screen flag=1, для fault — также отдельный готовый SDK probe. Команды
нельзя направлять на пользовательские звонки или использовать как нагрузочный тест.

## SS-07/SS-16 — 23 октября 2026: свежий допуск после picker

В чистом клиенте 10b97ee personal video прошёл с потерянным reply и двумя
конкурентными claims одной revision (200/409). Следующий group старт отклонил claim:
пока готовился capture, состав звонка успел изменить revision. Захват безопасно
закрылся, но пользователю требовалась повторная попытка. Это отдельная гонка от
исправленных device cache и подписок после reconnect.

Новый детерминированный тест до исправления **FAIL**: capture → claim:0 вместо
capture → heartbeat → claim:4. Теперь после разрешения picker и завершения уже
идущего poll выполняется общий fresh snapshot/допуск, затем одна команда claim.
При отказе проверки capture закрывается, команда не отправляется. Неизвестный
ответ по-прежнему повторяет прежний request_id; конфликт с другим ведущим не
вызывает автоматического перехвата. Подготовленный capture не запускает фоновый
reclaim во время этой проверки. Capture остаётся до сетевых await, сохраняя browser
user activation. **7 адресных lifecycle/media/panel tests PASS**; обновлены fixtures
дедлайна. Чистая сборка и реальный повтор фиксируются следующей записью.

## SS-10/SS-16 — 23 октября 2026: подписки после полного reconnect SDK

На 2abf4a7 прошли 133 tests/analyze/release JS и полный personal/group video с
потерянным reply, конкурентными claims и device revoke. Но независимые group video
повторы всё ещё иногда не получали media до screen claim. Дополнительные счётчики
показали connected ICE, работающий synthetic AudioContext и пустой subscriber PC
без receivers. Это не отсутствие микрофона и не отказ шифрования уже принятого кадра.

Установленный SDK 2.13.1 при полном restart создаёт RemoteParticipant/publications
из JoinResponse без TrackPublished events. С autoSubscribe=false начальный connect
покрывался явным обходом, а восстановление того же Room — нет. UI мог сообщать
«Соединение восстановлено» с пустой подпиской. Новый unit до исправления **FAIL**:
0 subscribe requests вместо 1.

Теперь после свежей проверки устройств/roster и при connected Room обходятся
неподписанные публикации. Это работает и когда повторная отправка ключа ещё не нужна;
уже подписанные tracks не дублируются. RoomReconnected ускоряет обновление допуска.
Screen использует тот же принцип в своём snapshot loop, сохраняя owner/source/kind,
GCM/codec, duplicate-track и serial guards. Unsubscribe убирает старый экранный кадр.
Чужой peer и ошибка авторизации не получают подписку. **8 адресных tests PASS**,
ещё **6 screen UI/lifecycle tests PASS**, analyze чистый. Чистый build и сквозной
повтор этого исправления выполняются отдельно; полный fault matrix ещё не принят.

## SS-16 — 23 октября 2026: сериализация проверки Matrix-устройств

Сравнительный основной group video при выключенном screen flag прошёл: входящие
audio/camera у обоих клиентов, UI экрана отсутствует. Одноразовый диагностический
harness не менял приложение; [baseline](../../prototype/verified-screen-disabled-baseline-run.json).
В общей `refreshDevices` найдена гонка: второй вызов помечал список outdated, пока
первый SDK update уже применил response и ещё сохранял его в БД. Первый мог ошибочно
завершить проверку доступа отказом. Экран добавил параллельные обращения к этому
общему mutable cache; одной задержкой старта проблему исправлять нельзя.

Новый детерминированный тест до исправления **FAIL**: два SDK updates одновременно
вместо одного. Добавлена очередь на Matrix Client по существующему соглашению Expando,
без новой зависимости; отметка outdated, update и проверка результата выполняются
последовательно. Реальная ошибка по-прежнему закрывает доступ, не отравляет следующий
запрос; разные клиенты независимы. **15 адресных Flutter tests PASS**, analyze чистый.
Это доказанный дефект конкурентного доступа; связь со всеми наблюдаемыми сбоями
group video ещё проверяется новым чистым build и реальными звонками. SS-16 остаётся
IN_PROGRESS до этой проверки; аппаратные/внешние gate не меняются.

## SS-10/SS-11 — 23 октября 2026: реальный device revoke и потерянный claim reply

Обычная чистая web-сборка 691a0fc, Chrome 156, два одноразовых Matrix-пользователя,
аудиозвонок без camera request. **PASS**:

- Принятый сервером claim лишён HTTP-ответа через browser route. Poll повторил
  то же тело/request_id; revision и generation совпали. Захват закрыт локально,
  серверный owner остановлен; следующий обычный показ/перехват прошёл. **2.614 с**.
- Во время группового показа удалено именно текущее Matrix-устройство ведущего,
  не аккаунт. Его добровольный screen unbind блокирован. Выдача нового screen JWT
  вернула 401, кадр скрыт, старая room отсутствует, независимый pinned SDK отверг
  сохранённый **ещё действующий** JWT. Оставшийся участник сохранил звонок и смог
  опубликовать новое поколение. **2.668 с**, без диагностической подмены приложения.

Свидетельства: [потерянный ответ](../../prototype/verified-screen-lost-reply-run.json),
[отзыв устройства](../../prototype/verified-screen-revoke-run.json). Только безопасные
флаги/хеши, токены и credentials не записаны. Для удаления room используется ListRooms:
ListParticipants в pinned SFU возвращает 200/[] даже для отсутствующей room. Проверка
helper сначала обнаружила существующую room, затем подтвердила её удаление.

Harness получил focused direct/group режимы, ожидание входящих base media и явную
активацию вкладок; adaptiveStream может приостанавливать video в фоне. Дополнительные
video прогоны выявили нестабильный старт основного group call **до screen claim**:
иногда нет приглашения, иногда нет входящего audio/video у одной стороны. Причина
пока не доказана; один успешный прогон это не отменяет. Это открытая локальная
регрессия SS-16/A14, отдельно от аппаратных/сетевых gate. Финальные focused audio
сценарии прошли. Временный диагностический JS и harness удалены, release не менялся.

Команды (последовательно, локальный стенд с временным screen flag=1):

```sh
VOICECHAT_UI_URL=http://localhost:7358/ VOICECHAT_SCREEN_TEST=1 VOICECHAT_SCREEN_DIRECT_ONLY=1 VOICECHAT_SCREEN_LOST_REPLY_TEST=1 node prototype/check_contacts_ui.cjs
VOICECHAT_UI_URL=http://localhost:7358/ VOICECHAT_SCREEN_TEST=1 VOICECHAT_SCREEN_GROUP_ONLY=1 VOICECHAT_SCREEN_REVOKE_TEST=1 node prototype/check_contacts_ui.cjs
```

Playwright использует доступный NODE_PATH; UI :7358 — чистая release JS сборка,
SDK probe :7362 — существующая лаборатория. Android не запускался. Сквозной replay
старого key envelope, три участника/одновременные pickers и полный live restart ещё
не приняты; SS-11 остаётся PARTIAL.

## SS-16 — 23 октября 2026: итоговая локальная регрессия и пользовательская инструкция

В обычном web приложении приняты personal/group video screen share с двумя
одноразовыми Matrix-пользователями. Проверены настоящие пиксели выбранной вкладки,
encrypted to-device key exchange, отмена без смены owner, перехват без подтверждения,
остановка старого capture, stop/fullscreen и реальные encoder Low limits. Камера и
аудиопакеты измерены только в основном voice PC; его identity не меняется при
перехвате. Суммировать screen и camera counters было неверно: удаление screen room
сбрасывает её вклад. Исправлен только способ измерения.

Реальный feature off на отдельном временном flag закрыл capture, убрал старый кадр
и сохранил group voice/camera. Реальный контейнер без внешней сети/портов с pinned
SFU прошёл health, создал room, затем авария control завершила весь контейнер за
2.301 с — не mock процесса. Негативный SDK прогон: 0 кадров без ключа и с неверным
ключом, отказ viewer/wrong source и старым original/refreshed JWT.

Найдены и исправлены ранний group bind до готовности media (теперь проверяется
connected и есть bounded retry до создания binding), audio kind с поддельным
screen source и локальный дедлайн capture, включая 202 pending. Закрытый/сменяемый
renderer скрывается до сетевых await. Native lifecycle приёмка этим не закрывается.

**146 Flutter tests PASS**, общий analyze без замечаний; после добавления интеграции
панели в CallWindow — отдельные 6 tests PASS. **48 Python tests PASS** (5.079 с).
Release JS web build PASS; WebAssembly не выбирался, dry-run предупреждение FRB
не выдано за WASM-совместимость. Проверка чистого committed snapshot выполняется
отдельно: общий checkout содержит чужой незавершённый дизайн, в screen-коммиты
попадают только наши изменения. Credentials/медиаключи/кадры пользователей не
включались в артефакты. Артефакты содержат только безопасные результаты.

Добавлены инструкция `docs/screen-sharing.md`, актуальный статус, архитектура,
runbook и таблица SS-A01–SS-A18. Ни BLOCKED, ни PARTIAL не превращаются в DONE.
Аудиосценарий A03 проверяется отдельно: личный уже PASS с camera requests=0 и
сохранением mute; групповой повторялся после одного отказа базового запуска и
затем упёрся в tooltip accessible label. Новый harness убирает hover и ждёт вкладку.
Окончательный результат/остаточные ограничения фиксируются ниже и в матрице.

Аудиоповтор завершён: **личный и групповой PASS**, camera request count=0,
mute сохранён до/во время/после screen; `verified-screen-calls-audio-run.json`.
Исходный единичный отказ обычного группового запуска до screen не воспроизвёлся
в следующем/финальном прогоне; это не доказательство устойчивости при сетевых сбоях,
они остаются в A14. Tooltip-клик исправлен в harness, продуктовую mute-логику не меняли.

### SS-16: допроверка committed host

Чистый git archive нашёл две зависимости от общего checkout: screen-тест использовал
новый аргумент чужого fixture, а исходная (до редизайна) компоновка не отводила
гибкую область экрану. Тест теперь совместим с committed fixture; screen content
скроллится, камеры/список ограничены по высоте, основные controls остаются снаружи.
Без screen сохраняется прежняя flex-компоновка. Чужой текущий редизайн в рабочем
дереве не заменялся и не включался в коммит. Три tests и analyze экспортированного
host прошли. Для базового QR-fixture создан пустой `.prototype`, как на обычном стенде.
Полный committed прогон повторяется после фиксации исправления.

Повтор завершён на чистом `git archive` **691a0fc30a**: **130 Flutter tests PASS**,
полный analyze без замечаний, release web JS build PASS. Сборка не содержит чужого
дизайна. В ней заново прошли обычные personal/group video calls: реальные screen
пиксели, Matrix key exchange, отмена, перехват, stop/fullscreen, encoder Low и
непрерывность основной камеры/голоса. Прогон от 18:09 UTC: direct 21.987 с,
group 22.756 с. [Отдельный артефакт](../../prototype/verified-screen-committed-calls-run.json)
содержит полный source commit и SHA-256 main.dart.js; прежний feature-off прогон
сохранён отдельно. Проверены 55 файлов release: нет fixture/SQLite/access-файлов
и значений локальных инфраструктурных secrets.

Зависимости восстановлены offline с `--enforce-lockfile`; использованы уже
сгенерированные upstream crypto/scanner assets из закреплённых зависимостей.
Холодная Rust/WASM сборка этим не проверена. Общий checkout имел 146 tests с чужими
изменениями; именно **130** относятся к принятому чистому screen snapshot.

## SS-15 — 23 октября 2026: control image, backup metadata и runbook

Реальная сборка выявила недостающий docker context: `.dockerignore` исключал SQL,
хотя Dockerfile их копировал. Добавлены только два screen schema файла. Control image
собран из закреплённых баз, модули импортируются, fresh/repeated migration v2 работают
под UID10001 с read-only root и пустым tmpfs control; flag off, секретов внутри нет.
Артефакт — `prototype/verified-screen-control-image-run.json`.

Backup existing control volume уже включает screen metadata. Новый test SQLite backup
→ восстановление → startup recovery доказывает, что старые leases аннулируются,
retired очередь очищается, предыдущие call данные сохранены; integrity_check ok.
Добавлен read-only screen_status.py с агрегатами без identities/JWT/leases/ключей.
Runbook описывает диагностику, off/rollback и изолированный restore. Feature off имеет
отдельный код screen_disabled: клиент закрывает экран сразу, не ждёт истечения lease.

**43 Python tests PASS** (4.356 с), последующий адресный повтор 11 tests PASS;
тестовый ResourceWarning устранён явным закрытием SQLite backup connection.
Dart lifecycle/capture tests PASS; targeted analyze доводится до чистого состояния.
Полное восстановление всего Compose приложения, внешний сервер и screen supervisor
fault с живым media остаются не приняты. Образ не публиковался и production не менялся.
SS-15 **PARTIAL**, аппаратные/нагрузочные/полный restore критерии не закрыты.

Допроверка: все **16 файлов COPY** в локальном образе совпали по SHA-256 с исходниками
(первый автоматический список ошибочно включал lab fixture; исправлен на фактический
Dockerfile COPY). [Manifest исходников образа](../../prototype/verified-screen-image-sources-run.json)
фиксирует image ID и UID10001:10001; это не опубликованный registry digest.
Реальный контейнер с сохраняемым control bind mount прошёл restart: screen participants=0,
старый binding ended, retired=0. Затем остановка control завершила весь контейнер/SFU
с exit=1. **PASS 8.988 с**, сеть none, портов нет, живое media не передавалось.
[Supervisor report](../../prototype/verified-screen-supervisor-run.json).

## SS-14 — 23 октября 2026: лёгкая циклическая регрессия, нагрузка BLOCKED

Добавлена проверка 50 циклов takeover/stop в fake SFU координатора. После каждого
шага ровно одна актуальная room либо ни одной после stop; retired очередь пуста;
повтор первоначального claim возвращает старую квитанцию без повторного эффекта.
6 transition tests **PASS 0.435 с**. Это проверка durable state machine, не замер
медиа, памяти браузера/native services или пропускной способности машины.

Реальный прогон 10 участников/30 минут/50 медиапереключений и нескольких звонков
не запускался: ограничение владельца на тяжёлые прогоны сохранено, Android и внешний
стенд отсутствуют. p50/p95/CPU/RAM/нагрев и вместимость VPS **не измерены**.
SS-14 BLOCKED для нагрузочной приёмки; независимая эксплуатационная подготовка SS-15
продолжается. Auto/Low — стартовые пределы ТЗ, пока без утверждения читаемости/ёмкости.

## SS-13 — 23 октября 2026: сетевые пределы и Auto/Low; внешняя сеть BLOCKED

Экран имеет Auto 1920×1080/15fps/2.5Mbps и Low 1280×720/8fps/1Mbps. Пределы
применяются к screen sender, без upscale/crop и без перезапуска камеры/микрофона.
При плохом качестве основного голоса или screen-соединения Auto снижает экран до
Low; codec явно VP8, simulcast выключен. Пределы — исходные настройки, не benchmark.
Widget/unit и analyze проверяют пропорции и controls; фактическую сетевую адаптацию
на внешнем канале этот результат не доказывает.

Два обычных web-клиента уже прошли **личный** Matrix call: настоящий tab capture,
доставка E2EE screen key, совпадение пикселей, отмена picker сохраняет старого owner,
перехват без подтверждения, старый capture остановлен, stop/fullscreen и рост
voice packets/camera frames. 19.597 с экранного сценария, `verified-screen-calls-run.json`.
Групповая проверка продолжается: существующий voice status может остаться
«Соединение восстановлено», поэтому harness ждёт реальное media/пиксели вместо
мимолётной строки статуса. Производственный голосовой код здесь не менялся.

Публичный HTTPS/WSS, реальный NAT/relay-only, mobile/Wi-Fi и TCP443-only **BLOCKED**:
нет целевого стенда/сетей. TURN/TLS не добавлен без доказанной топологии. Одна машина
остаётся допустимой схемой Compose; универсальная достижимость не заявляется.

## SS-12 — 23 октября 2026: матрица сред, аппаратная приёмка BLOCKED

Добавлена `docs/screen-sharing-acceptance.md` с точной областью Chrome 156 PASS,
непроверенным Safari и недоступными Edge/Firefox/телефонами. Мобильный web capture
в текущем SDK не поддержан; реальный decrypt/viewer на телефоне не выдаётся за
проверенный после desktop/layout test. Android по указанию владельца не запускался.
Недостающие среды блокируют SS-12 и общий релиз, но не независимую подготовку
эксплуатации и регрессии. Следующие внешние шаги фиксируются отдельно без fake PASS.

## SS-11 — 23 октября 2026: отрицательные SFU-проверки и исправление direct binding

Реальная интеграция обнаружила неверное предположение SS-03: `party_id` SDK не
равен deviceID, это случайный VoIP session ID. Исправлено: CallController запоминает
только encrypted invite/answer sender_key, связанный с room/call/party, и сверяет
его с доверенным Matrix-устройством выбранной стороны. `invitee_device_id` не даёт
допуска. Plaintext, другое устройство/пользователь и повторная подмена не заменяют
первую связь. Добавлен негативный тест. Ошибка перехвата во время heartbeat также
исправлена: picker вызывается сразу, claim ждёт текущий poll без потери нажатия.

Chrome 156, pinned SFU: **PASS 21.393 с**. Viewer не публикует экран; owner не
публикует camera в screen room; original/refreshed JWT после DeleteRoom отвергнуты;
0 декодированных кадров без ключа. Фактическая ListParticipants metadata проходит
production validator для одного E2EE screen и отклоняет два track. Камера/голос/P2P
продолжаются после удаления screen room. Артефакт — verified-screen-web-run.json.
При старте control теперь немедленно аннулирует сохранённые screen leases, до HTTP.

**41 Python tests PASS**, адресные Dart tests/analyze PASS. Полный Matrix-перехват
двумя UI-клиентами продолжается; отзыв устройства во время такого показа, настоящий
аварийный перезапуск control/SFU с экраном и Android пока не приняты. Отсутствие
ключей на сервере обеспечивается границами API/SQLite; это не независимый аудит E2EE.
SS-11 **IN_PROGRESS** до оставшейся сквозной негативной приёмки.

## SS-10 — 23 октября 2026: восстановление и ограничение пустой публикации

Смена группового roster отзывает старую screen room и сохраняет только ещё
допущенного owner в unavailable без generation. Живой capture может продолжиться
только после свежего snapshot/проверки доверия/нового claim с новой revision и ключом;
исключённый владелец этого права не получает. После reload/system stop capture
не возобновляется. При неизвестном исходе клиент повторяет тот же request_id.

Добавлен серверный опрос ListParticipants: пустой экран без публикации дольше
15 секунд отзывается; второй track, неверный sender/source, plaintext или AV1
отзывают поколение. Результат heartbeat не считается доказательством публикации.
Состояние watchdog не восстанавливается из памяти после restart: все старые
leases тогда отзываются. Root и clone останавливаются локально до сетевой очистки.
Поздний ответ bind после close получает unbind; повтор close идемпотентен.

Проверено: **35 Python tests PASS** (2.973 с), адресные Dart tests и analyze PASS,
включая late bind, native borrowing и поддельные key envelopes. Watchdog в этих
тестах использует fake SFU; фактический формат pinned LiveKit и общий UI пока
проверяются далее. Реальный прогон остановился до звонка на устаревших локаторах
SAS в существующем harness; исправления локаторов изолированы от продукта.
SS-10 **IN_PROGRESS** до реальных fault/reconnect и SFU watchdog проверок.

## SS-09 — 23 октября 2026: адаптивная панель экрана

ScreenPanel показывает отдельное contain-видео без mirror/crop, имя ведущего,
состояния подготовки/ожидания/ошибки, кнопки начала/перехвата/stop и полнооконный
просмотр. Закрытие просмотра возвращает в звонок, capture принадлежит контроллеру.
Камеры остаются в своей сетке; при смене поколения старый track/renderer очищается.
На mobile web capture недоступен в закреплённом SDK: есть объяснение, просмотр
не отключён. Touch/focus/semantics и темы используют штатные Material-компоненты.

Проверено: **11 Flutter tests PASS**, targeted analyze без замечаний; отдельный
UI-тест 320×640/640×320 проверяет отсутствие overflow, fullscreen и сохранность
контроллера. Release web build PASS. Полный двухпользовательский прогон запущен,
пока не принят: существующий harness потребовал уточнить локатор вложенного
диалога нового дизайна. Сквозная SS-07/SS-09 приёмка продолжается в следующей итерации.
Чужие незавершённые изменения дизайна в рабочем дереве сохранены отдельно.

## SS-08 — 23 октября 2026: native-путь подготовлен, Android DEFERRED

Добавлены mediaProjection permission/service и notification «Остановить показ»
отдельно от CallService микрофона. Порядок: SDK consent → готовность foreground
service → SDK getDisplayMedia, без второго владельца MediaProjection и без новой
зависимости. Engine сохраняется также при живом ScreenService. Исходный native
track принадлежит ScreenCapture: публикации заимствуют его и не уничтожают при
смене screen room. FLAG_SECURE приложения сохранён: содержимое самого VoiceChat
ОС может скрывать при показе всего экрана; чужие приложения подчиняются своим
ограничениям capture. Скрытого автозапуска камеры этот путь не добавляет.

Основание порядка ОС: [Android MediaProjection](https://developer.android.com/media/grow/media-projection),
[LiveKit Flutter createScreenShareTrack](https://docs.livekit.io/reference/client-sdk-flutter/livekit_client/LocalVideoTrack/createScreenShareTrack.html)
и исходники закреплённых пакетов. Проверен только общий Dart analyze/контракт.
По указанию владельца **не запускались Android build, эмулятор и телефон**.
Не приняты: merged manifest, реальная остановка ОС/onStop, lock/background/rotation,
уведомления и ресурсы; текущий SDK не гарантирует Dart onEnded из системного
MediaProjection callback. Это блокирует Android-приёмку и требует аппаратного
воспроизведения/при необходимости исправления SDK, а не отметки PASS по сборке.
SS-08 **IN_PROGRESS / аппаратная приёмка DEFERRED**; продолжаем независимые задачи UI.

## SS-07 — 23 октября 2026: веб-адаптер захвата проверен

Вызов захвата остаётся до сетевых await; audio выключен, частичный результат
очищается. Отмена picker сохраняет существующий просмотр и серверного ведущего.
Веб-копии публикации отделены от исходного capture: лаборатория теперь использует
production ScreenCapture и проверяет unpublish/dispose → republish без второго picker.
Renderer не нужен для запуска декодера: adaptiveStream выключен, чтобы ожидание kOk
не блокировало сами кадры. Потеря ключа по-прежнему не включает plaintext.

Реальный Chrome 156.0.8078.47, **PASS, 10.624 с**: экран тестовой вкладки, совпадение
пикселей, E2EE, 0 кадров без ключа, сохранность capture после disposal публикации,
продолжение камеры/аудиопакетов/P2P после удаления screen room, отказ двум старым JWT.
Артефакт: `prototype/verified-screen-web-run.json`. Камера/микрофон синтетические;
системный picker автоматически выбирает тестовую вкладку. Matrix exchange и полный
перехват двумя пользователями ещё не проверены: сценарий будет после UI в SS-09.
SS-07 **IN_PROGRESS** до этой интеграции; Android не запускался.

## SS-06 — 23 октября 2026: общий клиентный контроллер

Добавлены ScreenApi, ScreenSnapshot, ScreenShareController и проверка screen-key
контекста. CallController автоматически подготавливает отдельный screen binding
после подключения совместимого звонка и закрывает его вместе со звонком. Отказ
screen API не завершает голос. Capture принадлежит контроллеру, а не CallWindow.
Сохраняется request_id при неизвестном результате, отвергаются старые revision,
JWT связан с поколением. Matrix envelope проверяет encrypted sender, актуальное
доверенное устройство, roster, binding/session/generation/revision и срок ключа.
Получатель подписывается только на E2EE screen video текущего владельца; renderer
до cryptor kOk не получает remoteTrack. Ключи не пишутся в HTTP/SQLite/журнал.

Проверено: **9 Flutter tests PASS**, включая серверные fixtures, подмену владельца,
устройства/ключа/поколения/срока и регрессию окна звонка; targeted analyze — без замечаний.
Невалидные синтетические Base64 fixtures исправлены до успешного прогона.
Реальное декодирование SDK уже проверено SS-01; обмен Matrix и полный controller
проходят интеграционную приёмку после подключения кнопок в SS-07/SS-09. Поэтому
SS-06 пока не закрывает все интеграционные критерии. Android clone в закреплённом
SDK повторно использует native track: сохранение projection при ротации требует
отдельного решения SS-08, аппаратная проверка отложена владельцем.

## SS-05 — 23 октября 2026: HTTP API подключён, функция выключена

`screen_http.py` подключён к существующему Handler: capabilities, bind/unbind,
snapshot, claim/stop, heartbeat, token и собственные квитанции. Выдача JWT строго
по текущим revision/generation/role: viewer без publish, publisher только screen_share,
без screen audio/data/admin. Матрица проверяется заново перед каждой выдачей.
Старый `/token` сохранён. Повтор unbind восстанавливается по durable квитанции;
после выхода snapshot=null, чтобы не раскрывать продолжающийся roster/keys.

Один singleton координатора и worker обслуживают leases, pending IO и cleanup.
Feature flag — файл `.prototype/screen-enabled` (либо `VOICECHAT_SCREEN_FLAG`),
отсутствует/не содержит `1` — функция выключена. Worker отзывает активные screen
rooms без изменения базовых звонков. Флаг не является открытым административным API.
Новые Python/SQL файлы включены в control Dockerfile, иначе импорт нового Handler
сломал бы существующий образ. Внешние пути обслуживает существующий Caddy `/api/*`.

**33 теста PASS за 2,401 с**: loopback HTTP с тестовым Matrix и прежняя регрессия API;
лог `.prototype/ss05-check.txt`. Проверены ownership, source grants, неизвестные/лишние
JSON-поля, чужие квитанции, токен старой ревизии, rate limit и повтор без повторного
списания лимита. Предварительный отказ авторизации ошибочно давал 400; исправлен до PASS.
Docker image и настоящий Matrix HTTP в этой итерации не запускались; сквозной клиент
проверяется после SS-06/SS-07. Первая пользовательская кнопка пока отсутствует.

## SS-04 — 23 октября 2026: координатор переходов реализован

`screen_transitions.py` сохраняет намерение/квитанцию до SFU IO, удаляет старую
комнату перед созданием следующей и завершает операцию только при совпадающем
operation/revision. Сетевые вызовы не удерживают SQL-транзакцию (проверено записью
из другой connection внутри fake SFU callback). Неизвестный DeleteRoom оставляет
pending без нового publisher; повтор/восстановление завершают прежнее намерение.
Один control-процесс использует один экземпляр координатора; несколько реплик
по-прежнему не поддерживаются. Внедрение singleton и его worker — SS-05.

**27 Python-тестов PASS за 0,204 с**, лог `.prototype/ss04-check.txt`.
Покрыты конкурентный claim одной ревизии, повтор без нового эффекта, fingerprint
conflict, stop не владельцем, потерянный результат удаления, deadline, уход во время
CreateRoom и запрет оживления после рестарта. При старте процесса вызывается
`ScreenStore.recover()` (аннулирует допуска), затем координатор чистит retired rooms;
повтор IO внутри живого процесса не смешивается с восстановлением после рестарта.

Настоящий закреплённый LiveKit smoke: **0,078 с**,
[свидетельство](../../prototype/verified-screen-transitions-run.json).
Проверены реальные CreateRoom/DeleteRoom, отсутствие старой комнаты при перехвате
и удаление новой при stop. В этом smoke синтетический допуск; Matrix/медиаключи/
кадры не проверяются повторно. Предыдущая SS-01 отдельно доказывает отказ старым
JWT и непрерывность базовых медиасоединений. Тестовые комнаты удалены.

Следующая итерация SS-05: HTTP-адаптер, выдача ограниченных токенов, worker и выключатель.
До неё компоненты не подключены к работающему control API и UI.

## SS-03 — 23 октября 2026: компоненты допуска реализованы

`ScreenStore` поддерживает взаимный direct bind, group bind через существующий call
lease, продление/проверку/выход и устойчивый отзыв. `screen_access.py` получает свежие
membership/keys от Matrix перед SQL. Отсутствие устройства в проверенном снимке
отличается от нового устройства, вступившего параллельно с Matrix IO: последнее
не удаляется по устаревшему снимку. SQLite v2 добавляет ожидаемый peer identity;
v1 мигрирует отдельно, прежняя миграция не менялась.

Клиентский `screen_binding.dart` формирует запрос для подключённого VoiceCall.
Для direct выбранный party_id сверяется с доверенными устройствами; сам party_id
не даёт полномочия без второго подтверждения. Group использует собственный допуск,
не создавая второе место. UI/HTTP пока не подключены (SS-05/SS-06); окончательное
освобождение по CallController.close проверяется при этой интеграции.

Проверки: **22 Python-теста, 0,148 с**, лог `.prototype/ss03-check.txt`; **2 Flutter-теста
PASS**, длительность команды не зафиксирована. Адресный analyze: 3,6 с, без замечаний.
Сценарии включают гонку двух устройств, несовпадение пары, потерю/подмену ключей,
истечение/продление допуска, v1→v2, выход из основного группового звонка и сохранение
единственного места. Ошибки nullable deviceID и ожидаемого класса UserActionError
исправлены до успешной проверки. Реальный Matrix HTTP и цикл UI проверяются в SS-05/SS-07.

## SS-02 — 23 октября 2026: DONE

Добавлены `screen_control.py`, additive `screen_schema.sql`, строгий
`screen_protocol.py`, примеры всех сообщений и [контракт v1](../screen-protocol-v1.md).
Используется существующая calls.sqlite; на живом стенде миграция ещё не запускалась,
HTTP-пути пока не подключены. Запуск модуля не требует Matrix/SFU или новых пакетов.

Проверено **12 тестов** (включая 5 прежних CallStore): runner **0,080 с**,
вся команда **0,215 с**. Лог: `.prototype/ss02-check.txt`.
Подтверждены одинаковая схема fresh/old DB, сохранность call rows, повторная миграция,
полный rollback при ошибке внутри DDL, отказ неизвестной версии и невозможность
оживить терминальный binding/session. FK не допускает чужой owner lease.
JSON-граница отвергает дубли/лишние поля, неверный UTF-8, bool вместо integer,
oversized body и несовместимые direct/group поля. Примеры запросов проверены parser.

Квитанции хранятся минимум сутки после завершения; tombstone привязки остаётся для
защиты от повторного bind старого звонка. Реальные cleanup/переходы/идемпотентность
сценариев реализуются в SS-03/SS-04, здесь зафиксированы структура и ограничения.
Токены и ключи в БД не сохраняются. Следующая задача SS-03: допуск выбранных устройств.

## SS-01 — завершение веб-проверки, 23 октября 2026

По прямому указанию владельца оставшаяся аппаратная проверка Android отложена;
разрешён переход к SS-02. Веб-проверка осуществимости завершена, это не приёмка
полной функции на всех платформах. Полный Matrix DirectCall с экранным контроллером
проверяется после его появления в SS-03/SS-07; длительный периодический refresh — SS-14.

Повторный прогон: **8,740 с**, web-компиляция 26,9 с, адресный analyze 3,1 с.
Доказано, что после удаления screen room продолжают расти счётчики декодированных
камерных/P2P-кадров и аудиопакетов основной комнаты. Исходный и обновлённый JWT
отклонены. Проверен именно SDK refresh при смене permission; ожидание периодического
refresh в длинном звонке этим тестом не подменяется. Автоматизированный picker не
заменяет ручной системный выбор. Результат: `prototype/verified-screen-web-run.json`.

SS-01: **DONE для веб-проверки осуществимости, Android DEFERRED владельцем**.
Блокирующего отказа выбранного медиатранспорта не найдено. Следующая итерация SS-02.

## SS-01 — 23 октября 2026: веб-часть PASS, итерация IN_PROGRESS

Добавлена отдельная лаборатория `lib/lab_screen_main.dart`. Она не подключена
к обычному клиенту. `screen_fixture.py` создаёт одноразовые комнаты и JWT на
локальном SFU, `check_screen_web.cjs` проверяет assertions собственным headless
Chromium. Аккаунты Matrix, сохранённые пользовательские ключи и браузеры не используются.

### Подтверждённое окружение

| Часть | Версия / состояние |
| --- | --- |
| Flutter / Dart проекта | 3.47.7 / 3.13.5, `.prototype/tools/flutter` |
| Android SDK по Flutter Gradle defaults | minSdk 24, targetSdk 36, compileSdk 36 |
| LiveKit Flutter | 2.13.1 из lockfile |
| flutter_webrtc | 1.6.2+hotfix.4 из lockfile |
| Chromium | 156.0.8078.47 |
| SFU | Закреплённый image из prototype Compose: `sha256:89ca9ce0791e18d6e03bf6e2c49ceb27e1c754eae8bd50c989386c1a5963791a` |
| Android runtime | ADB доступен, подключённых устройств нет |

Системный `/Users/anton/flutter` оказался старым (Dart 3.8.1); попытка его анализа
остановилась на несовместимости SDK до проверки кода. Для работы используется
закреплённый SDK из проекта, зависимости не обновлялись.

### Что проверено

- Настоящий `getDisplayMedia` захватывает только отдельную тестовую вкладку.
  Выбор вкладки автоматизирован; ручной системный picker здесь не принят.
- Видеотрек screen share проходит E2EE закреплённого Flutter SDK и декодируется
  вторым клиентом. Цвет пикселей приёмника соответствует исходной тестовой вкладке.
- Одновременно работает вторая E2EE-комната с синтетическими камерой/микрофоном.
  Это не доступ к физическим камере и микрофону владельца.
- Отдельная локальная пара Flutter WebRTC также декодирует видео во время передачи
  экрана. Это проверка сосуществования P2P/SFU в одном клиенте, не Matrix DirectCall.
- Клиент без медиаключа декодировал ноль кадров, правильный ключ — ненулевое число.
- После удаления экранной комнаты старый JWT не подключается к ней повторно:
  `auto_create:false` действует в проверенном локальном SFU.
- Отдельно проверен обновлённый SDK JWT после серверного изменения permissions:
  сохранённый обновлённый токен также отклонён после удаления комнаты.
- Клон экранного трека принят SFU как вторая публикация того же identity. Серверное
  разрешение source не ограничивает число треков; VoiceChat должен выбирать один
  подтверждённый SID и отзывать нарушающий допуск по ТЗ.
- Capture stream не содержит аудиотреков (assertion лаборатории).

Последний результат: [verified-screen-web-run.json](../../prototype/verified-screen-web-run.json).
Итоговый расширенный прогон — **8,616 с**: 10 экранных, 19 камерных и 31 кадр
локальной P2P-пары; 0 кадров у клиента без ключа; исходный и обновлённый JWT отклонены.
Первый принятый прогон без P2P занял 7,672 с; расширенный с локальным P2P — 7,429 с
по монотонному таймеру драйвера. В расширенном прогоне до удаления комнаты получены
11 экранных и 19 камерных кадров; без ключа — 0. Это smoke-проверка, не benchmark fps.
Web-компиляция: 26,8 с и 27,9 с по Flutter build output для двух версий лаборатории.
Последующие сборки проверки токенов/clone: 30,4 с и 27,3 с соответственно.
Адресный анализ прошёл; предупреждения NeedBraces в промежуточной версии исправлены.

Первоначальный глобальный Chrome fake-device флаг подменял также изображение экрана:
assertion цвета корректно отклонил такой тест. В итоговом драйвере подменяется только
`getUserMedia` камеры/микрофона, а `getDisplayMedia` остаётся настоящим.

### Не проверено и что остаётся до закрытия SS-01

1. Android capture ↔ web и два соединения на Android; физический телефон отсутствует.
2. Реальный P2P Matrix DirectCall одновременно с экраном на разных устройствах.
3. Периодическое обновление JWT в длительном соединении (проверено обновление при
   смене permissions). Один успешный reconnect-тест не доказывает все варианты отзыва.
4. Ресурсы Android/фон/системный Stop, остальные браузеры и реальная сеть.

Владелец подтвердил отсутствие телефона и поручил отложить аппаратную проверку.
Она остаётся явным release gate; сборка или эмулятор не закроют её автоматически.

Ключи в лаборатории одноразовые из loopback fixture; они проверяют медиакриптографию,
но **не** безопасное распределение ключей через Matrix. Этот обмен реализуется в SS-06.
Веб-часть SS-01 принята; общий статус IN_PROGRESS до оставшихся проверок.
SS-02 не начата. Тяжёлые Android/нагрузочные прогоны не запускались.

### Воспроизведение

Из корня проекта, последовательно (локальный LiveKit должен быть доступен на 7880):

```sh
cd apps/client
../../.prototype/tools/flutter/bin/flutter build web --no-pub --release --no-web-resources-cdn --target=lib/lab_screen_main.dart --output=../../.prototype/screen-probe-web
cd ../..
cp .prototype/app-build/e2ee.worker.dart.js .prototype/screen-probe-web/e2ee.worker.dart.js
python3 prototype/screen_fixture.py
python3 prototype/serve_web.py --port 7362 --directory .prototype/screen-probe-web
```

`e2ee.worker.dart.js` должен быть предварительно собран штатным способом проекта
для закреплённого SDK; лаборатория не загружает worker с CDN. В другом терминале:

```sh
NODE_PATH=/absolute/path/to/node_modules node prototype/check_screen_web.cjs
python3 prototype/screen_fixture.py cleanup
```

Fixtures содержат только одноразовые тестовые credentials и не добавляются в Git.
Драйвер проверяет цвет исходной вкладки, декодирование, отсутствующий ключ и отказ
старому JWT; любой непройденный assertion оставляет результат FAIL.

## Последовательность исследования соединения

1. Исходная реализация и доступные SDK.
2. Идентичность участников, выбранные устройства и серверные права.
3. Форматы команд, ответов, ошибок, версий и идемпотентных повторов.
4. Сигнализация и handshake: SDP, ICE/STUN/TURN, SFU connection.
5. Разрешение ОС и получение настоящего screen track.
6. E2EE: создание/доставка ключа, криптографический отправитель и отзыв доступа.
7. Кодирование, доставка, реальная расшифровка и отображение правильных кадров.
8. Конкурирующие команды, обрыв сети, неизвестный результат и восстановление.
9. UI, совместная работа камеры/голоса, остановка и освобождение ресурсов.
10. Проверка целевых устройств/сетей и воспроизводимый однохостовый deploy.

Знания форматов и handshake достаточно для понимания соединения, но недостаточно
для готовности функции: права, шифрование, сбои и lifecycle проверяются отдельно.
