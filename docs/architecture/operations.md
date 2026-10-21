# Развёртывание и эксплуатация

## Один VPS и сетевой план

Один Linux VPS, исходный ориентир 4 vCPU/8 ГБ RAM/80–100 ГБ SSD. Сборки выполняются GitHub-hosted runner. Реальная ёмкость проверяется с 10 аудиоучастниками, синхронизацией истории и upload файлов одновременно; запас диска определяется сроком хранения медиа.

План сервисов Compose: `edge`, `web`, `synapse`, `postgres`, `control`, `livekit`, `coturn`, `push-gateway`; backup task по расписанию. Redis не нужен, пока не выбран режим компонента, который требует его. Один экземпляр каждого сервиса.

Предлагаемый edge: HAProxy TCP/SNI на 443 перед Caddy для HTTPS и coturn для TURN/TLS. Это позволяет оставить один публичный IP: web/matrix/api/rtc идут на Caddy, turn — на coturn. TLS для TURN завершается в coturn, сертификат обновляется автоматизированно. Начальную конфигурацию и SNI совместимость клиентов обязательно проверить; не заявлять поддержку TCP-443-only сети до этого теста.

| Внешний порт | Назначение |
| --- | --- |
| TCP 22 | SSH, ограниченный доступ для администрирования/CI |
| TCP 80 | ACME/HTTPS redirect |
| TCP 443 | SNI edge: HTTPS/WSS и TURN/TLS |
| UDP/TCP 3478 | coturn STUN/TURN |
| UDP 7882 | LiveKit UDP mux — проектный выбор вместо широкого диапазона |
| TCP 7881 | LiveKit ICE/TCP fallback |
| UDP 49160–49260 | Выделенный TURN relay range, проверить достаточность нагрузкой |

Внутренние 5432 PostgreSQL, 8008 Synapse, 7880 LiveKit signaling и control health/admin не публикуются напрямую. Reverse proxy проксирует WSS/SSE с подходящими timeouts. TURN relay не должен обращаться к loopback/private инфраструктуре; credentials краткоживущие, quotas обязательны.

WebRTC-порты и announced public IP задаются явно. Если host networking нужен медиасервису, его использовать осознанно с firewall, а не применять ко всем контейнерам. Docker bridge/port mapping проверять на реальном VPS. Для LiveKit задаётся внешний TURN, если закреплённая версия server/SDK позволяет передать нужную конфигурацию; иначе отдельный встроенный TURN на непересекающихся портах — решение прототипа без второго VPS.

Поддомены `app`, `matrix`, `api`, `rtc`, `turn` — роли, не выбранные реальные адреса. Homeserver `server_name` выбрать до первых аккаунтов: он становится частью Matrix ID. Федерацию не публикуем, внешние federated rooms не поддерживаем; необходимые outgoing соединения SMTP/FCM/ACME разрешены.

## Секреты и постоянные данные

Постоянные тома: PostgreSQL, Synapse signing/config и media store, сертификаты, нужное состояние control. Restart и redeploy не выполняют `down -v`. Runtime config разделён на шаблон в Git и секреты с ограниченными правами на VPS.

Секреты: PostgreSQL passwords по ролям; Synapse signing/registration/TURN credentials; LiveKit API secret; FCM service account; SMTP; internal webhook secret; ограниченный Synapse admin credential для reconciliation; SSH deploy и APK signing keys. Пользовательские E2EE/recovery secrets в этот перечень не входят и не появляются на VPS/CI.

По умолчанию нет текстов сообщений в логах/metrics/traces. Редактируем поля Authorization, cookies, query secrets и bodies до логирования. Для reverse proxy uploads ограничены по размеру, но ciphertext не проверяется как открытая картинка. Безопасное декодирование изображений выполняет клиент.

## Целевой репозиторий

```text
apps/client/             Flutter Android + Web
services/control/        Go control API, outbox worker, reconciliation
integrations/synapse/    observer metadata changes, version compatibility
infra/compose/           Compose, сервисные шаблоны, .env.example
infra/scripts/           bootstrap, deploy, backup, restore
.github/workflows/       checks, build, release/deploy
docs/architecture/       этот проект
```

Сейчас существуют только документы; эта структура — план. Не создаём фиктивный Compose или workflow, который выглядит рабочим без приложения и проверенных параметров.

## Контракт запуска

После однократной подготовки Docker, DNS, firewall, секретов, сертификатов и initial Synapse config: `docker compose up -d` из каталога инфраструктуры поднимает стек. Bootstrap должен проверять существование данных и не генерировать заново signing keys. Healthcheck и зависимости с готовностью БД не заменяют retry в приложениях.

Development использует отдельные секреты/порты/данные и отдельный Matrix server_name. Production backup никогда не загружается в CI. Браузерный микрофон и E2EE проверяются на допустимом secure origin.

## GitHub Actions

Предлагаемый production trigger — version tag, ручной `workflow_dispatch` для того же immutable release. Push/PR выполняет проверки без production-доступа. Адрес/доступность GitHub repo ещё не заданы; публичность не меняем автоматически.

1. Lint/analyze, unit/integration tests по модулям; compose config validation, secret scan.
2. Сборка Flutter Web и APK, Go image; фиксированные зависимости и base images, actions закреплены по commit SHA.
3. Images в GHCR с commit tag и digest; manifest релиза связывает web/control/config/schema и APK version. Третьесторонние образы также зафиксированы.
4. APK подписан стабильным release key, versionCode возрастает. Артефакт для скачивания и checksum; доступ пользователей к приватному release определить перед выпуском. Публикация не устанавливает APK на телефоны автоматически.
5. Деплой через SSH с проверкой host key и отдельным пользователем; deploy lock и GitHub concurrency исключают параллельное обновление.
6. Preflight: доступность backup, свободный диск, валидная конфигурация, допустимый путь миграций. Перед несовместимым обновлением — maintenance/drain звонков, а не обещание zero downtime.
7. Pull по digest, миграции по инструкции компонента, compose update без удаления томов, healthchecks и smoke проверки HTTPS/auth/call-service.
8. Сохранение результата и предыдущего manifest. Автооткат возможен только для совместимой схемы. Иначе остановка обновления и процедура восстановления с явно указанным риском утраты изменений после backup.

Секреты репозитория/окружения зависят от возможностей GitHub-плана; никаких требований обязательных reviewer gates без необходимости. Доступ к Docker даёт широкие права на хосте, поэтому deploy credentials считаются чувствительными. APK signing key резервируется вне CI.

## Backup, восстановление и наблюдение

Исходный план: ежедневная зашифрованная копия PostgreSQL и media/config на независимое хранилище, 7 ежедневных и 4 недельных снимка; контроль успешности и тестовое восстановление. Это начальная политика, RPO/RTO ещё не измерены.

Согласованность: БД snapshot согласован сам по себе, но media отдельно. Для простого v1 backup останавливаем новые записи/загрузки на короткое окно, снимаем согласованный набор БД и файлов (либо используем согласованные snapshots); не копируем живой postgres volume обычным file copy. Частичные backup помечаются незавершёнными и не заменяют последнюю проверенную копию.

В backup входят signing key, конфигурация, БД, файлы и серверные секреты в защищённом виде. Ключ расшифровки backup хранится вне самого VPS. Пользовательский recovery secret отдельно у пользователя. Проверка restore: изолированная среда без отправки настоящих push/mail → восстановление → вход тестового аккаунта → history/file → restart → smoke call.

Наблюдаем: свободный диск, RAM/CPU, ошибки auth/sync/upload, задержку server acknowledgement, число активных calls, reconnect/ICE failures, TURN usage, packet loss/jitter/RTT по безопасной телеметрии, состояние backup/сертификатов. Не собираем аудио или тексты. Измеряем p50/p95 в известных условиях до назначения целевых показателей.

## Проверка архитектуры

| Проверка | Критерий / решение при провале |
| --- | --- |
| Matrix Dart + vodozemac Android/Web | Текст/файл/голосовое, verify, recovery, restart; при несовместимости адаптер/SDK пересматривается до UI-разработки |
| Локальное хранилище | Crypto DB, outbox, индекс защищены; потеря browser storage восстанавливается; не обещать шифрование SQLite без реального адаптера |
| История и search | Пагинация старше первой страницы, edits/redactions в индексе, частичный прогресс виден |
| WebRTC dependency graph | LiveKit и P2P plugin совместимы в одном APK/Web, без конфликтующих native libs |
| Group sender keys | Per-sender E2EE Android↔Web, replay/expiry/device mismatch отвергаются |
| Member/device revoke | Отзыв во время вызова, новый epoch/room generation, сохранённый JWT не читает новый звук |
| Synapse observer | Membership/device changes доходят, пропуски закрывает reconciliation; нет прямых SQL-зависимостей |
| TURN и firewall | Прямой путь, UDP blocked, TCP/TLS fallback, SNI 443 на одном IP |
| Android background | Экран заблокирован, процесс выгружен, permission denied, повторный push, cancel до accept |
| Multi-device | Два accept одновременно, accept vs cancel, пользователь занят; один победитель по БД |
| Fault injection | Restart control/Synapse/LiveKit, lost webhook, duplicate request, clock skew; состояния восстанавливаются |
| Нагрузка | 10 участников + загрузки/история; измерить RTT/jitter/loss/CPU, не объявлять результат заранее |
| CI/restore | Один clean deploy, один update, один совместимый rollback и проверенное восстановление данных |

Блокирующие для релиза: E2EE/fail-closed, revoke/recovery, loss/duplicate сообщений, системный входящий звонок, восстановление backup. UI-полировка не компенсирует провал этих сценариев.

## Источники

- [LiveKit ports/firewall](https://docs.livekit.io/transport/self-hosting/ports-firewall/)
- [LiveKit deployment](https://docs.livekit.io/transport/self-hosting/deployment/)
- [Docker Compose](https://docs.docker.com/compose/)
- [GitHub deployment environments](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments)

Сетевой layout, backup policy и CI pipeline — проектные решения; должны быть проверены на выбранном VPS и закреплённых версиях.
