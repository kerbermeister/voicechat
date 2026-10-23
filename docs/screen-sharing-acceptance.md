# Приёмка демонстрации экрана

Дата: 23 октября 2026. Релиз **не принят**. Реализация и лабораторное доказательство
отделены от аппаратной, сетевой и эксплуатационной приёмки.

## Платформы — SS-12

| Среда | Захват | Encrypt / decrypt | Фон / системный Stop | Результат |
| --- | --- | --- | --- | --- |
| macOS, Chrome 156.0.8078.47, Flutter web JS, LiveKit 2.13.1 | Реальная тестовая вкладка; выбор автоматизирован | Реальные E2EE-кадры совпадают с источником; без ключа 0 кадров | Ручной picker/Stop/monitor/window не проверены | PARTIAL PASS |
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

- Нет согласованного внешнего адреса/VPS, характеристик канала и тестовых мобильных
  сетей. Loopback SFU не доказывает работу firewall/NAT/TURN или сети только TCP 443.
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
| A04 | BLOCKED | 10 участников, поздние join/return на реальных устройствах не проверены. |
| A05 | PARTIAL PASS | A → B в личном/групповом звонке, без подтверждения и без замены voice PC. A → B → C отдельным прогоном ещё не принят. |
| A06 | UNIT PASS | Два конкурентных claim одной revision дают одного победителя; реальный одновременный picker/claim ещё не принят. |
| A07 | PARTIAL PASS | Реально потерянный claim reply: тот же request_id, revision и generation, безопасный stop и следующий запуск. Stale revisions/leases/old claim и recovery покрыты unit/HTTP; переставленные команды против нового реального ведущего ещё не приняты. |
| A08 | PARTIAL PASS | Реальная отмена capture сохраняет текущий показ; late bind/close, дедлайн HTTP и 202 pending покрыты unit. Закрытие системного picker при завершении звонка вручную ещё не проверено. |
| A09 | PARTIAL PASS | UI Stop и feature off освобождают web capture и скрывают кадр. Browser OS Stop и Android lock/onStop не приняты. |
| A10 | PARTIAL PASS | Реальный pinned SFU отвергает original/refreshed JWT удалённой room. Matrix device deletion во время group screen: 401 на новый token, ListRooms подтверждает удаление, независимый SDK отвергает unexpired old JWT; оставшийся участник публикует новое поколение. Полный hostile publish в новом поколении ещё не принят. |
| A11 | PARTIAL PASS | HTTP доступ/пара/роль/lease, source и kind; настоящий SFU отвергает viewer publish и owner camera, production metadata guard обнаруживает duplicate. Полный hostile client против активного Matrix звонка ещё не принят. |
| A12 | PARTIAL PASS | Реальные E2EE-пиксели, 0 кадров без ключа/с неверным ключом; sender/device/generation/expiry envelope проверены unit. Сквозной replay старого envelope ещё не принят. |
| A13 | PARTIAL PASS | Capture video-only и source grants, audio-kind отвергается до subscribe, голос в своей room. Воспроизведение системного звука с выключенным mic на физических устройствах не принято. |
| A14 | PARTIAL PASS | Потерянный claim reply, fault/lease/fencing unit, реальный control/SFU fail-closed container и DeleteRoom. Полный live restart/Matrix outage ещё не принят. В дополнительных video прогонах нестабилен основной group call до screen claim; причина не доказана, локальная регрессия открыта. |
| A15 | BLOCKED | Нет внешнего VPS/NAT/целевых Wi-Fi/mobile сетей; TCP443-only не заявлен. |
| A16 | PARTIAL PASS | Layout 320×640/640×320, fullscreen, Material focus/semantics; тема и реальный screen reader на каждой платформе ещё не приняты. |
| A17 | PARTIAL PASS | Additive v1→v2, fresh/repeated migration, read-only image, SQLite backup/recovery, настоящий feature off сохраняет group voice/camera. Полный Compose application restore ещё не принят. |
| A18 | BLOCKED | 50 fake metadata cycles без retired rooms; это не 30 минут media и не доказательство native/браузерных утечек. Тяжёлая нагрузка не разрешена. |

Артефакты: [обычные video calls](../prototype/verified-screen-calls-run.json),
[повтор на чистом committed build](../prototype/verified-screen-committed-calls-run.json),
[аудиосценарий](../prototype/verified-screen-calls-audio-run.json),
[потерянный claim reply](../prototype/verified-screen-lost-reply-run.json),
[Matrix device revoke](../prototype/verified-screen-revoke-run.json),
[отрицательный SFU/E2EE](../prototype/verified-screen-web-run.json),
[образ control](../prototype/verified-screen-control-image-run.json),
[сверка исходников образа](../prototype/verified-screen-image-sources-run.json),
[настоящий supervisor](../prototype/verified-screen-supervisor-run.json).
