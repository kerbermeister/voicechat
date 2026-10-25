# Приёмка демонстрации экрана

Дата: 24 октября 2026. Релиз **не принят**. Реализация и лабораторное доказательство
отделены от аппаратной, сетевой и эксплуатационной приёмки.

По запросу владельца 24 октября включён web preview на `https://univc.duckdns.org`
в релизе `30e96d2` после исправления clock-skew group invite (web-only CI SUCCESS).
Личный/групповой показ, перехват, stop и voice/camera continuity прошли на публичном
адресе в двух Chrome. Runtime flag=1 не завершает обязательную приёмку.
[Отдельный отчёт VPS](iterations/screen-vps-preview.md).

## Платформы — SS-12

| Среда | Захват | Encrypt / decrypt | Фон / системный Stop | Результат |
| --- | --- | --- | --- | --- |
| macOS, Chrome 156.0.8078.47, Flutter web JS, LiveKit SDK 2.13.1 | Реальная тестовая вкладка; выбор автоматизирован | Реальные E2EE-кадры совпадают с источником; без ключа 0 кадров | Ручной picker/Stop/monitor/window не проверены | PARTIAL PASS |
| macOS, Edge 156.0.4314.42 | Реальная тестовая вкладка → Chrome; автоматический выбор | Edge ↔ Chrome: реальные E2EE screen/camera, без/неверный ключ 0 кадров; SDK lab | Ручной picker/Stop не проверены | PARTIAL PASS |
| macOS, Firefox 153.0, Playwright build 1538 | Не проверен | SDK media connection FAIL, кадры не приняты; причина не установлена | Не проверено | FAIL / OPEN |
| macOS 15.3.1, Safari 18.3 (20620.2.4.11.5) | Отправка не проверена | Нативный просмотр от Chrome PASS: реальные E2EE screen/camera; без/неверный ключ 0 кадров, повторный положительный контроль | Не проверено | PARTIAL PASS |
| macOS, Playwright WebKit 26.5 build 2336 | Отправка не проверена | SDK lab просмотр от Chrome PASS, key negatives и media continuity | Не проверено; не заменяет Safari | LAB PASS |
| Физический Android APK | Реализация подготовлена; не запускалась | Не проверено | Не проверено | DEFERRED владельцем |
| Android Chrome, мобильный веб | Отправка запрещена закреплённым SDK | Просмотр на реальном устройстве не проверен | Не проверено | BLOCKED |
| iPhone Safari, мобильный веб | Отправка запрещена закреплённым SDK | Просмотр на реальном устройстве не проверен | Не проверено | BLOCKED |

Нативный iOS не входит в задачу. Widget-тесты 320×640/640×320 — проверка layout,
а не доказательство работы реального мобильного браузера. SharedArrayBuffer/worker,
HTTPS, codec и фактический E2EE decode должны проверяться на каждой целевой версии.
Артефакт Chrome: [verified-screen-web-run.json](../prototype/verified-screen-web-run.json).

## Внешние условия — SS-13/SS-14/SS-17

- На целевом VPS подтверждён публичный HTTPS/WSS screen smoke двух Chrome
  через реальные Matrix/SFU: личный/групповой показ, перехват и stop.
  Это не проверка relay-only, мобильных сетей или сети только TCP 443.
- TURN/TLS на 443 сейчас не настроен. HTTP reverse proxy сам по себе не заменяет
  TURN. До проверки L4/SNI или отдельного разрешённого порта эта сеть не поддержана.
- Ограничение владельца на тяжёлые тесты и параллельные сборки сохранено. Нагрузку
  10 участников, 30 минут, 50 циклов и несколько одновременных звонков не запускать
  до отдельного разрешения. Без замеров нельзя объявлять вместимость машины.
- На VPS по явному запросу владельца опубликован web preview, runtime flag включён
  для самостоятельного тестирования. Default off сохранён в коде; полная приёмка
  и поддержка всех платформ этим исключением не закрываются.

## Связанные результаты

История изменений и фактические команды: [журнал](iterations/08-screen-sharing.md).
Контракт: [screen protocol v1](screen-protocol-v1.md). Требования и критерии:
[ТЗ §13](screen-sharing-spec.md#13-приёмка-и-проверочные-свидетельства), [задачи](tasks/08-screen-sharing.md).

## Критерии SS-A01–SS-A18 — SS-16

PASS ниже относится только к явно указанной среде/части. PARTIAL и BLOCKED не
закрывают обязательную приёмку всего продукта.

| ID | Результат | Свидетельство / остаётся |
| --- | --- | --- |
| A01 | PARTIAL PASS | Два обычных Chrome клиента видят контрольные пиксели; голосовые PC и камеры сохраняются. Настоящая вкладка, ручной выбор окна/монитора ещё не проверен. |
| A02 | DEFERRED | Android ↔ web на телефоне отложен владельцем. |
| A03 | WEB PASS | Личный и групповой аудиозвонки: настоящий screen без camera request, mute сохраняется до/во время/после показа. |
| A04 | PARTIAL PASS | Три обычных web-клиента декодируют экран A → B → C. Поздний вход C меняет generation, удаляет старую room, сохраняет один разрешённый root capture у A; B и C получают реальные кадры. 10 участников и join/return на физических устройствах не проверены. |
| A05 | WEB PASS | A → B → C с тремя разными цветами источников на снимках реального UI: бывшие ведущие видят победителя, остаётся один capture, voice PC/камеры сохраняются. Ручные picker/разные устройства остаются в SS-12. |
| A06 | WEB PASS | Два реальных подготовленных capture удержаны на одной revision; claim отправлены одновременно: 200/409. Проигравший останавливает capture и видит экран победителя. Picker выбирался последовательно для сохранения browser focus; одновременными были команды серверу. |
| A07 | PARTIAL PASS | Реально потерянный claim reply: тот же request_id, revision и generation, безопасный stop и следующий запуск. В лабораторном живом group call старые stop/claim, изменённый idempotency key/body, чужой lease, generation/identity не сменили нового ведущего; старый успешный claim вернул только квитанцию. Остальные recovery/fault фазы остаются ниже. |
| A08 | PARTIAL PASS | Реальная отмена capture сохраняет текущий показ; late bind/close, дедлайн HTTP и 202 pending покрыты unit. Закрытие системного picker при завершении звонка вручную ещё не проверено. |
| A09 | PARTIAL PASS | UI Stop и feature off освобождают web capture и скрывают кадр. Browser OS Stop и Android lock/onStop не приняты. |
| A10 | WEB PASS | Реальный pinned SFU отвергает original/refreshed JWT удалённой room. Matrix device deletion во время group screen: 401 на новый token, ListRooms подтверждает удаление, независимый SDK отвергает unexpired old JWT; оставшийся участник публикует новое поколение. После настоящего group takeover независимый SDK отверг original/refreshed unexpired JWT; прежний ведущий получает только viewer grant нового поколения. Raw SFU signaling и duplicate/plaintext publication проверены отдельной локальной итерацией; фактический scope указан в A11. |
| A11 | WEB PASS | HTTP доступ/пара/роль/lease, source и kind; настоящий SFU отвергает viewer publish и owner camera, production metadata guard обнаруживает duplicate. В настоящем Matrix group call raw addTrack отвергнут для owner-camera, screen-in-voice и viewer-publish. Duplicate и raw plaintext приняты SFU, затем production watcher удалил generation и остановил capture. Для изоляции серверного guard screen roster=A, voice=A/B. Trusted idle SDK другого члена чата и второе trusted устройство участника не получили token/key; оба способны расшифровать контрольное Olm-сообщение. Подменённый identity/canPublish JWT отвергнут независимым SDK. |
| A12 | WEB PASS | 15 доставленных Matrix/Olm отрицательных случаев: точный старый envelope, подменённые контексты/срок/устройство, plaintext, voice channel. Ни один не достиг screen setKey; voice key не изменился, 0 кадров до правильного ключа. Положительный контроль установил актуальный raw key и дал видимые пиксели. Физические платформы остаются в SS-12. |
| A13 | PARTIAL PASS | Capture video-only и source grants, audio-kind отвергается до subscribe, голос в своей room. Воспроизведение системного звука с выключенным mic на физических устройствах не принято. |
| A14 | WEB PASS | Локальные private control Matrix/restart, joint container restart/SIGKILL control/SIGKILL SFU/SIGSTOP watchdog, короткий signaling/control обрыв и возврат проигравшего viewer, unknown результат настоящих SFU CreateRoom/DeleteRoom, silent lease и настоящий Matrix kick. Захват/старый кадр закрыты, retired/pending очищены, unexpired old JWT отвергнут. Только screen faults сохраняют основные voice PC/media; crash общего SFU прерывает групповой голос. Внешняя сеть/UDP loss относятся к A15. |
| A15 | PARTIAL PASS | Публичный VPS HTTPS/WSS: два Chrome, личный/групповой screen smoke PASS. Relay-only, UDP-blocked, целевые Wi-Fi/mobile сети и TCP443-only не приняты. |
| A16 | PARTIAL PASS | Обычный Chrome: 7 тем через UI/localStorage/PNG, чат и live screen 320×640/390×844/640×320, scroll-доступ к screen controls, всегда видимое завершение, fullscreen/возврат. Direct/group mic/camera off/on сохраняют screen и voice PC, новые RTP streams продолжают декодироваться. Widget: 7 тем, text200%, reduced animations, Tab/Enter/Escape fullscreen и возврат фокуса; контраст используемых color pairs ≥4.5:1. Исправлен live status с ошибкой захвата; UI fixture в Chrome/Edge/Firefox/WebKit на 3 viewport PASS (без media). Нативный Safari AX/keyboard PASS; озвучивание и VO navigation не приняты, VoiceOver возвращён off. Целевые устройства остаются. |
| A17 | PARTIAL PASS | Additive v1→v2, fresh/repeated migration, read-only image, SQLite backup/recovery, настоящий feature off сохраняет group voice/camera. Полный локальный Compose restore принят: новые тома, restored release/runtime, signing key, SQL/3 SQLite/media; новый login, принудительное чтение/decrypt истории и реальный download/decrypt файла, group voice/camera и новый screen call. Старые leases отозваны, capture не возобновляется. Сохранён client vault. Отдельный local upgrade pre-screen c3e3f43 → current → baseline на тех же томах: v1→v2, off/on, отказ ручного rollback при active screen, quiescence, backup перед обеими сменами; данные до/после upgrade и ordinary E2EE call сохранены. Registry/target release и старая клиентская версия остаются. |
| A18 | BLOCKED | 50 fake metadata cycles без retired rooms; это не 30 минут media и не доказательство native/браузерных утечек. Тяжёлая нагрузка не разрешена. |

Артефакты: [обычные video calls](../prototype/verified-screen-calls-run.json),
[повтор на чистом committed build](../prototype/verified-screen-committed-calls-run.json),
[аудиосценарий](../prototype/verified-screen-calls-audio-run.json),
[потерянный claim reply](../prototype/verified-screen-lost-reply-run.json),
[Matrix device revoke](../prototype/verified-screen-revoke-run.json),
[три участника и поздний вход](../prototype/verified-screen-three-run.json),
[конкурентный claim](../prototype/verified-screen-concurrent-run.json),
[отказ Matrix для screen control](../prototype/verified-screen-matrix-fault-run.json),
[перезапуск отдельного control](../prototype/verified-screen-restart-fault-run.json),
[регрессия чистой сборки](../prototype/verified-screen-subscription-regression-run.json),
[старые команды и сохранённые JWT](../prototype/verified-screen-security-commands-run.json),
[настоящий Olm key replay и SQLite audit](../prototype/verified-screen-security-keys-run.json),
[raw SFU signaling / duplicate / plaintext](../prototype/verified-screen-security-publish-run.json),
[trusted участник вне звонка](../prototype/verified-screen-security-commands-member-run.json),
[trusted дополнительное устройство](../prototype/verified-screen-security-commands-device-run.json),
[cleanup одноразовых аккаунтов](../prototype/verified-screen-security-cleanup-run.json),
[отрицательный SFU/E2EE](../prototype/verified-screen-web-run.json),
[образ control](../prototype/verified-screen-control-image-run.json),
[сверка исходников образа](../prototype/verified-screen-image-sources-run.json),
[настоящий supervisor](../prototype/verified-screen-supervisor-run.json),
[полный локальный Compose restore](../prototype/verified-screen-security-restore-run.json),
[обновление томов и совместимый rollback](../prototype/verified-screen-security-operations-run.json),
[оставшаяся обычная web-регрессия](../prototype/verified-screen-regression-run.json),
[чистая сборка и 135 тестов](../prototype/verified-screen-regression-build-run.json),
[финальная локальная очистка](../prototype/verified-screen-local-regression-cleanup-run.json).

## Локальная подготовка включения — SS-17

[Preflight](../prototype/verified-screen-preflight-run.json): **локально PASS,
релиз BLOCKED**. Чистый клиент caecb3c, проверочный commit 6c37d84; локальный JS
artifact `.prototype/screen-release-web` имеет SHA256
`4a3af9a1c9d1f6ed10092e74cf048f6ca223506549af713f2f5c9e258032b790`.
Это loopback build для регрессии; публичная конфигурация и production web image
требуют отдельной сборки/проверки. Проверенный local control image:
`sha256:caa3777db260ddf4aca89465429b47931162c11f46eb519c343cd97abaf2156a`.
Его 16 файлов совпадают с актуальными исходниками; registry digest у этого
локального образа отсутствует. Protocol v1, screen SQLite v2; `schema: 1` в
deployment manifest — другой маркер совместимости.

После тестов active=0, pending=0, retired=0; SDK fixture и временный flag удалены,
постоянный flag отсутствует. Screen-only серверы остановлены; общий локальный
стенд и volumes сохранены для параллельной работы. Production в этой итерации
не обновлялся. Отдельные коммиты не включают незавершённый дизайн/VPS diff.

Локальная web-негативная матрица SS-11 принята отдельной лабораторией на production
controllers: новые свидетельства связаны выше. Это не полная аппаратная приёмка
и не независимый security audit всей инфраструктуры.

До полного выпуска остаются как внешние, так и локальные проверки: физический Android и браузеры, системный picker/Stop/
доступность, внешние сети, разрешённая нагрузка, target upgrade/rollback и registry manifest
и совместимость старого клиента. Локальная Chrome регрессия сообщений/файлов/тем принята отдельно. PARTIAL/BLOCKED сохраняются для открытых gate.

На целевом стенде порядок: совместимый сервер с flag off → web/APK и обычный
звонок → обязательная приёмка в тестовом окне → решение о включении. Отключение:
атомарный flag=0, дождаться active/pending/retired=0, проверить обычный звонок.
Общую БД ради выключения экрана не откатывать. Команды и restore-порядок:
[runbook](../infra/README.md#экран-диагностика-обновление-и-восстановление),
[однохостовый VPS](../infra/VPS.md#4-screen-api-и-sqlite).
