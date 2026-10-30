# Раздельный deploy: production-проверка

Рабочая установка: один VPS, роли core и edge-a в `/srv/voicechat-managed`.
Этот блок проверяет раздельное обновление ролей на существующем VPS.
Подключение и замена физических B/C, перенос A и приёмка медиа остаются отдельными задачами.

## Области выпуска

В GitHub Actions → Build and deploy выбрать ветку, `rollout=managed`,
нужный `mode` и `deploy=true`.

| mode | Что обновляется | Обязательные ограничения |
| --- | --- | --- |
| full | Core и выбранная схемой совокупность входов | Нужен при изменениях общих защищённых исходников или отсутствии подходящей baseline |
| core | Только core; веб-образы переиспользуются | Для backend delta записанный `core_guard` должен совпасть с вычисленным; остальные изменения требуют full |
| edge | Выбранные входы; control image переиспользуется | Полный backend fingerprint совпадает с production; core-конфигурация сохраняется |
| web | Только web на выбранных входах | Условия edge и проверка совместимости web-only; configure/TURN/route-health не обновляются |

Поле `edges` для web/edge принимает ID входов через пробел; пустое поле означает
все входы текущей baseline. `deploy=false` публикует артефакты без выкладки;
частичные сборки всё равно читают production baseline через проверенный SSH.
Серверные и клиентские проверки остаются включёнными во всех режимах.

`core` не разрешает произвольные серверные изменения: allowlist определяется
`infra/release_source.py`. Изменение workflow, общего оператора, edge-настроек,
Compose или другой защищённой части вне allowlist требует full. Исходный полный
backend fingerprint сохраняет прежний охват. Full записывает baseline schema2
и `core_guard`; старая schema1 остаётся читаемой, но не разрешает новый backend
через core без подходящего записанного guard.

Новая topology, изменение назначения хоста, замена ключей и перенос данных не
выполняются обычным scope deploy. Их нельзя проводить ручной правкой fingerprints
или release pointers.

## Отказ и повтор

Незавершённая операция сохраняет frozen source и journal на A, локальные owned
fences и частичные результаты на узлах. Штатный workflow сначала возобновляет
эту операцию. После завершённого rollback новая попытка требует явного
`retry_managed=true`; перед этим проверить actual phase и здоровье служб.
Не удалять journal/fences, не редактировать current/previous/digests и не удалять
release-каталоги, пока они используются bind mounts.

Rollback приложения сохраняет данные, записанные после backup; откат БД поверх
новых записей не является частью обычного release. Обновления движка PostgreSQL
или Synapse требуют отдельной совместимой миграции.
Core/full и согласованный backup могут кратко останавливать writers. Web/edge
должны сохранять процессы core; web также сохраняет остальные процессы входа.

## Состояние проверки

- Local candidate: 685 Python tests PASS, три условных skip; приложение и Compose
  относительно production2dae758 не изменены.
- Full production run58: SUCCESS; независимый VPS postcheck PASS, baseline schema2 и core guard записаны; source `2eaee99516c942c2d9026290477777e69b3c6379`.
- Core production: PASS, revision `42706c5`; реальные core processes обновлены, все edge и соседние процессы неизменны. Прежние synthetic account/device/session/Matrix marker сохранены.
- Edge/web production: следующие отдельные проверки.
- Deployed planner отклонил несовместимые partial scopes и удаление full guard без начала операции; synthetic Matrix session/marker подготовлены через production HTTPS.

Для последовательных acceptance releases используются неизменённые образы CI
full58 и новые docs-only revisions. Штатный `managed_ssh` проверяет clean Git,
полный набор публичных source bytes, backend/core fingerprints, immutable image
digests и baseline, затем выполняет тот же coordinator/peer протокол. Изменение
revision позволяет подтвердить настоящее применение кандидата и изоляцию
процессов без повторной сборки неизменённого приложения.

Перед каждой операцией и после неё сохраняются process IDs, StartedAt,
RestartCount, actual image references, data identity, current/previous,
состояние timers и HTTPS-проверки. Отдельный synthetic Matrix account проверяет
сохранение сессии/device и живой записи account_data через публичный HTTPS.
Его credentials остаются на A; основное пользовательское хранилище не читается.
Это не проверка расшифровки переписки или медиа.

Пользовательская приёмка ведётся в [едином реестре](../user-acceptance.md).
