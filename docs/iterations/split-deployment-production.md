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
- Edge production: PASS, revision `f51b928`; edge обновлён, core и соседние процессы неизменны. Прежняя synthetic сессия и Matrix marker сохранены.
- Web production: PASS, revision `73c15c4`; изменён только web, core/configure/TURN/route-health и соседние процессы неизменны. Прежние synthetic account/device/session/Matrix marker сохранены; затем token штатно отозван и временный credential file удалён.
- Один параллельный read-only postcheck получил штатный nonblocking baseline lock; API-чтение завершено, последовательный повтор postcheck PASS. Отказ сохранён локально; deploy не повторялся.
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

## Итог 30.10.2026: блок завершён

[Production full58 — SUCCESS](https://github.com/kerbermeister/voicechat/actions/runs/41005474251),
source `2eaee99516c942c2d9026290477777e69b3c6379`. CI artifact 12955642598,
опубликованный ZIP SHA256 `3c9c8db8a570dcf03d191edadcfb02f404998a329cbc46f248a8fb4620b9fdad`.
Артефакт этого run отдельно не скачивался; CI SUCCESS и независимая проверка
реально установленной baseline/immutable images подтверждены.

| Production операция | Кандидат | Независимый результат |
| --- | --- | --- |
| full58 | `2eaee99` | schema2, core guard, core/edge health, data identity и maintenance PASS |
| core | `42706c5` | core изменён; все edge процессы неизменны |
| edge-a | `f51b928` | edge изменён; все core процессы неизменны |
| web-a | `73c15c4` | web изменён; core и остальные entry процессы неизменны |

Partial операции выполнены штатным SSH coordinator, **не отдельными CI runs**.
Точное совпадение application/operator inputs с full58 проверено перед каждой
операцией; они переиспользуют его immutable control/web images. Проверена
реальная смена процессов выбранного scope, а не только no-op той же revision.
Изменение функциональности приложения в эти acceptance revisions не входило.

На каждом шаге проверены current/previous lineage, фактические image refs,
ID/StartedAt/RestartCount, PostgreSQL/signing identity, отсутствие pending fences,
освобождение intents, enabled/active backup/TLS timers, публичный HTTPS и route
readiness. Шесть общих/соседних процессов и macOS24 feed остались прежними.
С операторского Mac дополнительно проверены HTTPS200 и `Cache-Control: no-cache`.
Synthetic account/device/session и живая Matrix account_data запись сохранены
после каждого partial scope; тестовая сессия в конце отозвана, credentials не
экспортировались с A.

Control: `ghcr.io/kerbermeister/voicechat/control@sha256:f0165cbfb99157c60337a77b73a0bd5e6ce3d796dbd9b32c58c6415f0e4b568d`.
Web: `ghcr.io/kerbermeister/voicechat/web@sha256:794deef3d9677cb82c67838a8bffb0e36fd709ba73a78f3f5a82414d9bbc16be`.

Технические свидетельства: [full](three-vps-evidence/2026-10-30-split-full58.json),
[core](three-vps-evidence/2026-10-30-split-production-core.json),
[edge](three-vps-evidence/2026-10-30-split-production-edge.json),
[web](three-vps-evidence/2026-10-30-split-production-web.json),
[guard refusals](three-vps-evidence/2026-10-30-split-guards.json),
[final checks](three-vps-evidence/2026-10-30-split-production-final-checks.json),
[session logout](three-vps-evidence/2026-10-30-split-api-logout.json).
Соседние `*-release.json` фиксируют фактические coordinator attempts и source hashes.

Предел результата: один физический VPS с core и cohost edge-a. Подключение
реальных B/C, onboarding/replacement, перенос A и клиентская/медиа приёмка не
выполнялись в этом блоке. Production rollback намеренно не вызывался; проверены
его pointers и guards, прежние VM rollback свидетельства остаются отдельными.
Исходники приложения относительно опубликованного macOS24 не изменялись;
новый выпуск macOS этим блоком не требуется. Более широкий draft PR5 остаётся
открытым; для выпуска выбирать согласованную ветку `codex/three-vps-rollout`.
