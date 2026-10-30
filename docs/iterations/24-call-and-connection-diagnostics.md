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
