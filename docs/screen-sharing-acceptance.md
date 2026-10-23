# Приёмка демонстрации экрана

Дата: 23 октября 2026. Релиз **не принят**. Реализация и лабораторное доказательство
отделены от аппаратной, сетевой и эксплуатационной приёмки.

## Платформы — SS-12

| Среда | Захват | Encrypt / decrypt | Фон / системный Stop | Результат |
| --- | --- | --- | --- | --- |
| macOS, Chrome 156.0.8078.47, Flutter web JS, LiveKit SDK 2.13.1 | Реальная тестовая вкладка; выбор автоматизирован | Реальные E2EE-кадры совпадают с источником; без ключа 0 кадров | Ручной picker/Stop/monitor/window не проверены | PARTIAL PASS |
| Desktop Edge | Не проверен, браузер недоступен | Не проверено | Не проверено | BLOCKED |
| Desktop Firefox | Не проверен, браузер недоступен | Не проверено | Не проверено | BLOCKED |
| Desktop Safari, macOS | Установлен; сквозной сценарий не выполнен | Не проверено | Не проверено | NOT TESTED |
| Физический Android APK | Реализация подготовлена; не запускалась | Не проверено | Не проверено | DEFERRED владельцем |
| Android Chrome, мобильный веб | Отправка запрещена закреплённым SDK | Просмотр на реальном устройстве не проверен | Не проверено | BLOCKED |
| iPhone Safari, мобильный веб | Отправка запрещена закреплённым SDK | Просмотр на реальном устройстве не проверен | Не проверено | BLOCKED |

Нативный iOS не входит в задачу. Widget-тесты 320×640/640×320 — проверка layout,
а не доказательство работы реального мобильного браузера. SharedArrayBuffer/worker,
HTTPS, codec и фактический E2EE decode должны проверяться на каждой целевой версии.
Артефакт Chrome: [verified-screen-web-run.json](../prototype/verified-screen-web-run.json).

## Внешние условия — SS-13/SS-14/SS-17

- В этой итерации screen share не принят на целевом VPS и тестовых мобильных
  сетях. Параллельная подготовка общего VPS deploy не заменяет эту приёмку.
  Loopback SFU не доказывает работу firewall/NAT/TURN или сети только TCP 443.
- TURN/TLS на 443 сейчас не настроен. HTTP reverse proxy сам по себе не заменяет
  TURN. До проверки L4/SNI или отдельного разрешённого порта эта сеть не поддержана.
- Ограничение владельца на тяжёлые тесты и параллельные сборки сохранено. Нагрузку
  10 участников, 30 минут, 50 циклов и несколько одновременных звонков не запускать
  до отдельного разрешения. Без замеров нельзя объявлять вместимость машины.
- Production не обновлялся; включение функции на целевом стенде требует согласованной
  среды и окна. До приёмки серверный flag остаётся off.

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
| A14 | PARTIAL PASS | Потерянный claim reply, fault/lease/fencing unit, настоящий fail-closed container и DeleteRoom. Живой E2EE screen прекращён при restart отдельного production control API/SQLite и отказе его Matrix-зависимости; unexpired JWT отвергнут, P2P голос/камера продолжаются. Общий Synapse не выключался. В отдельном control/SFU container живой экран безопасно прекращён при restart, SIGKILL каждого процесса и SIGSTOP control; unexpired JWT отвергнут после recovery. Короткий обрыв, unknown SFU outcomes и silent lease ещё проверяются. Исправлены гонка device refresh, пропуск subscriptions после SDK reconnect и revision до picker; результаты повторов — в журнале. |
| A15 | BLOCKED | Нет внешнего VPS/NAT/целевых Wi-Fi/mobile сетей; TCP443-only не заявлен. |
| A16 | PARTIAL PASS | Layout 320×640/640×320, fullscreen, Material focus/semantics; тема и реальный screen reader на каждой платформе ещё не приняты. |
| A17 | PARTIAL PASS | Additive v1→v2, fresh/repeated migration, read-only image, SQLite backup/recovery, настоящий feature off сохраняет group voice/camera. Полный Compose application restore ещё не принят. |
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
[настоящий supervisor](../prototype/verified-screen-supervisor-run.json).

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

До включения остаются как внешние, так и локальные проверки: дополнительные fault
фазы SS-10/SS-16 (A14), физический Android и браузеры, системный picker/Stop/
доступность, внешние сети, разрешённая нагрузка, полный application restore/rollback
и оставшаяся регрессия сообщений/файлов/тем. PARTIAL/BLOCKED сохраняются для них.

На целевом стенде порядок: совместимый сервер с flag off → web/APK и обычный
звонок → обязательная приёмка в тестовом окне → решение о включении. Отключение:
атомарный flag=0, дождаться active/pending/retired=0, проверить обычный звонок.
Общую БД ради выключения экрана не откатывать. Команды и restore-порядок:
[runbook](../infra/README.md#экран-диагностика-обновление-и-восстановление),
[однохостовый VPS](../infra/VPS.md#4-screen-api-и-sqlite).
