# Screen protocol v1 — контракт SS-02

Статус: структурная валидация и схема SQLite реализованы; HTTP-маршруты и бизнес-операции
добавляются в SS-03–SS-05. Этот документ не объявляет endpoints работающими.
Основание: [ТЗ §8](screen-sharing-spec.md#8-контракт-управления-экраном).
Машиночитаемые примеры: [fixtures](../prototype/screen_protocol_fixtures.json).

## Вход

Все JSON POST содержат `protocol_version: 1` (integer, bool недопустим).
Размер тела 1–8192 байта UTF-8, неизвестные и повторные поля отклоняются.
Matrix Bearer token передаётся только заголовком. Идентичность определяется сервером,
`peer` в bind — утверждение для взаимной проверки, не полномочие.

| Операция | Поля помимо protocol_version |
| --- | --- |
| `POST /api/screen/bind`, group | `room_id`, `call_session`, `transport:"group"`, `call_lease_id` |
| `POST /api/screen/bind`, direct | `room_id`, `call_session`, `transport:"direct"`, `peer:{user_id,device_id}` |
| `POST /api/screen/unbind` | `binding_id`, `lease_id`, `request_id` |
| `POST /api/screen/{binding}/claim` | `lease_id`, `request_id`, `expected_revision` |
| `POST /api/screen/{binding}/stop` | `lease_id`, `request_id`, `expected_revision` |
| `POST /api/screen/{binding}/heartbeat` | `lease_id`, `observed_revision`, `capture_state` |
| `POST /api/screen/{binding}/token` | `lease_id`, `expected_revision`, `generation` |
| `GET /api/screen/{binding}/state` | Нет тела |
| `GET /api/screen/{binding}/operations/{request_id}` | Нет тела |

`binding_id` и `request_id`: UUID в канонической нижнерегистровой записи.
`lease_id/call_lease_id`: 64 hex-символа нижнего регистра. Generation:
`screen-` и 48 hex-символов. Revision: integer 0–9007199254740991, без bool/float.
`room_id`: строка 2–255 символов с `!`; полную принадлежность проверяет Matrix.
`call_session`: 1–128 печатных ASCII-символов без пробелов; допускаются UUID с дефисами,
это не групповой pattern на 32 hex. `peer` содержит только строки user_id/device_id
длиной 1–255, user_id начинается `@`; актуальность проверяет допуск.
Capture state: `idle | preparing | sharing`. Серверные deadlines клиент не задаёт.

`screen_protocol.parse_request` проверяет структуру, не выдаёт допуск и не заменяет
membership/device/trust/lease/version checks. Отказ — безопасный `invalid_request`
без rejected values. Версию нельзя автоматически понижать при неизвестном значении.

## Выход

Snapshot содержит: `protocol_version`, `binding_id`, `revision`, `state`,
`owner_identity`, `generation`, `roster_version`, `deadline`, `server_time`,
`roster`, `capabilities:{screen:boolean}`. Все версии и время — integer; время —
Unix milliseconds UTC. State: `idle | switching | active | unavailable | ended`.
Owner/generation/deadline допускают null; в idle/ended owner и generation — null.
Roster — до десяти допущенных устройств с identity и проверенными публичными
`curve/ed` keys, без чужих lease IDs. Объём ответа не более 32 КиБ.

| Ответ | Дополнительные поля / смысл |
| --- | --- |
| Bind | `binding_id`, свой `lease_id`, `binding_state:pending|open`, `snapshot` |
| Unbind | `status`, `request_id`, `snapshot` |
| Claim/stop | `status:pending|succeeded|failed`, `request_id`, `result_revision:integer|null`, `snapshot` |
| Heartbeat | `lease_expires_at`, `snapshot` |
| Token | `generation`, `revision`, `role:viewer|publisher`, `token`, `expires_at` |
| Operation receipt | `request_id`, `status`, `result_revision`, `error_code:string|null`, `snapshot` |

Claim/stop с незавершённым результатом возвращают 202, завершённые — 200.
Повтор квитанции не делает прежнего владельца текущим и не выдаёт ему JWT.
`active` означает готовое поколение, не доказанную расшифровку каждым зрителем.
Токен — только после актуальной проверки всех прав; токены в fixtures — заглушки.

HTTP-ошибки: 400 invalid_request, 401 unauthorized, 403 screen_access_denied,
404 screen_session_not_found, 409 screen_revision_conflict / screen_transition_in_progress /
screen_not_owner / screen_binding_mismatch / idempotency_conflict,
410 call_ended / lease_expired, 429 screen_rate_limited, 503 screen_unavailable.
Оболочка: `{error:code}`; для 409 можно приложить разрешённый snapshot, для 429 —
`retry_after` в секундах. Чужой binding не раскрывать через подробную ошибку.

## Схема, миграция и очистка

`screen_control.ScreenStore` получает путь **той же calls.sqlite**, что CallStore.
Собственная логическая метка `screen_schema` не меняет чужой PRAGMA user_version.
Все новые объекты имеют префикс screen_. SQL исполняется одной транзакцией;
неизвестная версия отвергается без изменения данных. Таблицы calls/leases/retired
не переписываются и не обслуживаются ScreenStore.

- Bindings связывают room/session/transport; участники имеют один выбранный device
  на пользователя в binding и уникальный lease. Group participant ссылается на
  проверяемый основной call lease, без второй регистрации в пользовательском лимите.
- Session хранит revision, owner/lease, generation, roster_version и fenced operation.
  Владелец обязан ссылаться на допуск в том же binding. Active без владельца невозможен.
- Commands: уникальность `(binding_id,actor_identity,request_id)`, fingerprint,
  expected/result revision, status, безопасная ошибка и created_at. Другой fingerprint
  с тем же ID не выполняется. Fingerprint — SHA-256 канонического JSON команды;
  bearer token и медиаключ в него не входят.
- Retired содержит поколение/binding/revision для повторного удаления SFU после crash.
  Запись удаляется только при доказанной очистке. Graceful restart не воскрешает leases.

Cleanup реализуется в последующих сценариях: квитанции сохраняются весь живой binding,
после ended — минимум 24 ч. Затем удаляются квитанции/истёкшие допуски, только если нет
незавершённых операций/retired rooms. Минимальный терминальный binding-tombstone
сохраняется, чтобы поздний bind старого call_session не создавал новую трансляцию.
Он не содержит секретов. Удаление tombstones требует отдельного механизма доказанной
свежести вызовов; произвольный TTL здесь небезопасен.

Rollback: существующий код не читает screen tables, additive-схему не удалять.
До отката отключить capability и удалить screen rooms; старый авторизатор не должен
обслуживать активные экранные grants. Пока модуль не подключён к HTTP/Compose, он
не меняет работающую БД. Подключение файлов SQL к image и backup проверяется в SS-15.
