# Реализация схемы трёх VPS

Дата начала: 28 октября 2026. Основание: [ТЗ](../three-vps-spec.md),
[пошаговый план](../tasks/19-three-vps.md), последующее разрешение владельца начать
локальную подготовку без изменений VPS и заказа новых серверов.

## Граница текущего этапа

Начальная ревизия: `bca5b46f582cac1bee080736985950d039b46a0e`, ветка
`codex/calls-and-message-todos`. Рабочее дерево до начала содержало изменения
звонков, экрана, файлов, macOS, web startup, deployment и документации; они
сохранены. Эти результаты относятся к рабочему дереву, не к отдельному релизу.

Production, DNS и GitHub Actions не запускались и не изменялись этой работой.
Фактическая production baseline не считана. Существующий локальный Compose-проект
`voicechat-prototype` не перезапускался; тест создаёт отдельный случайно названный
проект и удаляет только его контейнеры, сеть и синтетические тома.

| Задача | Состояние |
| --- | --- |
| V3-00 | Карта охвата и исходное состояние зафиксированы |
| V3-01 | Открыта: реальные inventory, DNS и baseline не проверялись |
| V3-02 | Частично: HTTP/Matrix стенд A/B/C и нативная macOS-проба |
| V3-03 | Частично: смена транспорта и повторное открытие прежнего криптопрофиля |
| V3-04 | Локальный Chrome: смена TURN с декодированным синтетическим звуком; отдельная TLS/SNI-проба; полные звонки приложения открыты |
| V3-05, V3-05a | Публичная схема, подписанный каталог, локальное добавление D; inventory, offline bundle и атомарная публикация каталога на одном filesystem; multi-host deploy открыт |
| V3-06 | Core/edge роли и права, отдельные runtime, локальные Compose/TLS/TURN rotation probes; туннели и миграция открыты |
| V3-09, V3-11 | Health, выбор, общий координатор, backoff и resume hook; внешняя сеть и аппаратная проверка открыты |
| V3-12, V3-13 | Подключение Matrix до init; control HTTP и начальный WSS через выбранный вход; полная приёмка открыта |
| V3-08, V3-10, V3-15, V3-17 | Частично: TLS/CORS proxy, refresh TURN перед ICE restart, banner сети; полная приёмка открыта |
| V3-14 | Локальные socket fault checks и native encrypted files через D после отказа B/C/reopen; все потребители и платформы открыты |
| V3-18 | Android HTTP и macOS Sparkle выбирают signed-catalog entry; нативная установка, push/P2P открыты |
| V3-07, V3-16, V3-19–29, V3-T01–03 | Открыты |

## Исходная карта охвата (до реализации ниже)

| Область | Основные точки | Проверки / незакрытая часть |
| --- | --- | --- |
| Начальные адреса и профиль | `infra/client_config.py`, `main.dart`, `matrix_probe.dart`, `local_store*.dart` | `transport_test`, `session_preservation_test`, новая нативная проба; автоматический выбор до init ещё не подключён |
| Matrix HTTP, sync, send, ключи | `Client.httpClient`, vendored Matrix SDK, `route_transport.dart` | Новый transport test; прерывание sync и потеря ключевых запросов требуют отдельных сценариев |
| Вложения, аватары, ссылки | `chunked_file.dart`, `chat_actions.dart`, `avatar_image.dart`, `link_preview.dart`, `contact_link.dart` | Используют Matrix HTTP client; полный прогон media download/upload через B/C открыт |
| Control API и операции | `contact_service.dart`, `scheduled_messages.dart`, `screen_api.dart`, `call_probe.dart`, `p2p/service.dart` | Часть использует Matrix client, часть создаёт отдельный HTTP client; нужна общая политика service origins и idempotency |
| Личные звонки | `direct_call.dart`, `call_controller.dart`, `vendor/matrix/lib/src/voip/` | SDK имеет `getIceServers` и `CallSession.restartIce`; обновление credentials и реальный звук через запасной TURN не доказаны |
| Групповые звонки и экран | `call_probe.dart`, `screen_controller.dart`, `screen_api.dart`, LiveKit SDK | RTC configuration поддерживает ICE servers; смена WSS/relay при живом lease требует пробы V3-04 |
| Push, ссылки, updater | `push_notifications_web.dart`, `app_update.dart`, `app_update_dialog.dart`, `update_platform_native.dart`, `main.dart` | Отдельные HTTP clients и canonical links нужно включить в маршрутный контракт; не переключены автоматически |
| Сервер и сеть | `infra/compose*.yaml`, `configure.py`, `Caddyfile`, `prototype/call_control.py`, `screen_*.py`, `web_push.py` | Нынешняя конфигурация одного VPS сохранена; core/edge/TURN/tunnel ещё не разделены |
| Деплой и артефакты | `bootstrap.py`, `deploy.py`, `ssh_deploy.py`, `release_source.py`, release scripts и `.github/workflows/` | Существующие guards/backup/rollback сохранены; новые роли и режимы ещё не реализованы |

Пути `.dart` в таблице без префикса относятся к `apps/client/lib/`, серверные
скрипты без префикса — к `infra/`. Все вызовы `MatrixProbe.open` найдены через `rg`:
основной клиент и лабораторные entrypoints сохраняют прежнее поведение по умолчанию;
новый параметр используется только новой интеграционной пробой.

Пересечения: failover не является call handoff между устройствами; P2P не должен
воскрешать завершённую передачу; разработка Windows остаётся отдельным планом.
Проверка future-client контракта не равна проверке ещё отсутствующего клиента.

## Первая итерация: основа транспорта

- `apps/client/lib/route_transport.dart`: общий HTTP transport сохраняет
  канонический homeserver и меняет только сетевой адрес на один из доверенных
  origins. Проверяет конфигурацию и происхождение запроса до чтения тела,
  запрещает downgrade/redirect, сохраняет streaming body и abort trigger.
  Активная отправка остаётся на выбранном при её начале маршруте. Повторных
  отправок и автоматического выбора здесь намеренно нет: они требуют координатора
  и знания семантики операции, иначе возможна повторная запись после потери ответа.
- `MatrixProbe.open(..., httpClient: ...)`: транспорт можно передать до
  `Client.init`, чтобы восстановление старого профиля не обращалось сначала
  к недоступному адресу. Идентичность Matrix и существующее хранилище не меняются.
- `prototype/check_three_vps.py`: opt-in стенд с закреплёнными образами
  PostgreSQL/Synapse/Caddy из текущей infra. Только B/C публикуют случайные
  loopback-порты; у A нет host ports. Данные, пароли и имена проекта одноразовые.
  Нет реальной почты, push, runtime/env production или подключения рабочих томов.
- `apps/client/integration_test/route_transport_test.dart`: на macOS создаёт
  синтетический зашифрованный профиль и Matrix-комнату. Канонический URL не имеет
  работающего сервера, запросы идут через B/C. После явной смены B→C и закрытия /
  повторного открытия профиля проверяет прежние user/device/token/fingerprint,
  единственное зарегистрированное устройство и расшифровку сообщений. Для проверки
  расшифровки заново получает ciphertext с сервера, обходя кеш plaintext.

В первой итерации обычный клиент не включал `RouteTransport`. Ниже зафиксировано
последующее подключение через opt-in build configuration; production не изменялся.

## Проверки и воспроизведение

Toolchain: Flutter 3.47.7 / Dart 3.13.5; Rust 1.99.1 согласно
`infra/crypto-tools.json`. В этом локальном runtime нужная версия Rust установлена
под именем `stable`; проверена фактическая версия, а не только имя toolchain.

Проверено:

- Полный `flutter analyze`: без замечаний.
- 27 Flutter-тестов: `transport_test`, `route_transport_test`,
  `history_recovery_test`, `session_preservation_test`, `first_keys_test`,
  `device_name_test` — прошли. Из них 8 новых проверяют маршруты, авторизацию,
  отсутствие скрытых повторов, multipart, streaming, отмену и закрытие клиента.
- `python3 -m unittest discover -s prototype -p test_three_vps.py -v`:
  2 теста изоляции стенда прошли.
- `python3 -m unittest discover -s prototype -p test_deployment.py`:
  11 существующих тестов прошли. Они не выполняют production deploy.
- Нативная интеграционная macOS-проба выполнена на настоящих Synapse/Postgres
  и двух локальных reverse proxy, с SQLCipher/Keychain и vodozemac.

Запуск нативной пробы из корня при установленном локальном toolchain и Docker:

```sh
CARGO_HOME="$PWD/.prototype/cargo" \
RUSTUP_HOME="$PWD/.prototype/rustup" \
RUSTUP_TOOLCHAIN=stable \
PATH="$PWD/.prototype/cargo/bin:$PATH" \
python3 prototype/check_three_vps.py --flutter .prototype/tools/flutter/bin/flutter
```

Для другой установки передать её Flutter через `--flutter`, настроить Cargo/Rust
и проверить фактические версии по `infra/crypto-tools.json`. Зависимости Flutter
должны быть заранее получены по lockfile: runner использует `--no-pub`.
Требуются Xcode/macOS и доступ к Docker. Скрипт задаёт поддерживаемый macOS locale
`en_US.UTF-8` (также для CocoaPods), пишет подробный лог в приватный `.prototype/three-vps/` и удаляет свой стенд
в `finally`, включая неуспешный запуск. В Git не включаются пароли, токены,
ключи, базы и полный build environment. Сводка: [evidence](three-vps-evidence/2026-10-28-matrix-route.json).

## Ограничения первой итерации (частично сняты ниже)

Следующая контрольная точка — V3-04: доказать резервный TURN и восстановление
direct/LiveKit, затем закрепить общую topology/config и подключать координатор
выбора маршрута, control и остальные сетевые потребители. Одного HTTP transport
недостаточно для восстановления медиасоединения.

Не проверены внешние сети, реальные B/C, TLS/SNI/TURN 443, Android/web, звонки,
демонстрация экрана, тайминги автоматического переключения и замена VPS.
В пробе B и C доступны одновременно, выбор C явный: она не доказывает обнаружение
сбоя, прекращение зависшего long poll, смену relay или цель 15 секунд.

Новые deploy/bootstrap/rollback ещё предстоят. Локально можно подготовить их код
и проверки, но завершить аппаратную и production-приёмку без серверов нельзя.
A остаётся единственным узлом данных; эта архитектура и текущий код не защищают
от его потери без внешнего backup.

## Вторая итерация: маршрутизация и подписанный каталог

Владелец разрешил продолжать все локальные работы и отдельно включил добавление
D/E без выпуска клиента. ТЗ обновлено до v1.1, добавлена задача V3-05a.

Реализовано:

- `infra/topology.py`, `three-vps.example.json`, `route_config.dart`: одна публичная
  схема, отдельная от физических IP/SSH/secrets. От 2 до 32 уникальных входов,
  проверки неизвестных полей, origins, схемы и идентичности. Старый вызов
  `client_config.py origin output` остаётся совместимым и не включает routing.
- `infra/route_health.py`: edge проверяет Matrix/control по фиксированным upstream,
  параллельно, без redirects/прокси из окружения, с ограничением ответа и числом
  потоков. Короткий кеш 2 с, возраст в ответе, no-store, частичная readiness 503.
  Это служба API readiness, не проверка TURN/SFU.
- `route_coordinator.dart`: параллельные две пробы на вход, 1.5 с на пробу,
  приоритет успешности, медиана RTT, пороги 20% и 50 мс, сохранение исправного пути.
  Отдельный выбор Matrix/control, один concurrent refresh, отмена при закрытии,
  мониторинг и backoff с jitter до 30 с. 401/403/429 не запускают обход через входы.
- `route_catalog.py`, `route_catalog.dart`: offline Ed25519-подпись OpenSSL и
  проверка уже подключённым vodozemac. Каталог не содержит пользовательских токенов;
  revision защищает от сетевого отката, подпись — от подмены адресов. Кеш подписанного
  документа сохраняется единым значением; новые документы ограничены сроком действия.
  При запуске и затем каждые 15 минут каталог обновляется через известные входы.
- `MatrixProbe.open` включает маршрутизацию до `Client.init`, когда собраны
  `ROUTE_CONFIG` и `ROUTE_CATALOG_KEY`. Старые сборки/обычная single-host конфигурация
  работают как прежде. Профиль, device и ключи при выборе входа не пересоздаются.
- Control запросы `CallProbe` и `ScreenApi` используют отдельные HTTP-пулы с общим
  координатором. Начальный WSS URL группового звонка/экрана выбирается через него.
  Автоматический повтор неидемпотентных POST не добавлен. Восстановление уже живого
  LiveKit WSS и смена TURN ещё не завершены.

Локальная нативная проба расширена: скомпилирован только B/C, новый D существует
только в подписанном документе, сгенерированном OpenSSL одноразовым тестовым ключом.
После получения каталога оба B/C останавливаются, остаётся D. Проверены запросы,
реальная расшифровка ciphertext, повторное открытие того же SQLCipher/Keychain
профиля, прежние user/device/token/fingerprint и одно устройство на сервере.
Кроме того, проверены неверная подпись/ключ, истечение срока, чужая установка,
откат revision и конфликт содержимого одной revision.

Прошедшая проба: `voicechat-routes-907d32619dc0`,
`.prototype/three-vps/voicechat-routes-907d32619dc0.log`. Стенд удалён штатно.
Повторная нативная проба выполняется той же командой из раздела выше. Это реальный
macOS/Synapse/Postgres/Caddy, без утверждения о проверке Android/web или внешних VPS.

Проверены 30 выбранных Flutter-тестов транспорта, сессий, call cleanup/key sharing,
screen protocol/lifecycle; полный Flutter analyze без замечаний. Python topology
и isolation tests прошли; route health проверен настоящими loopback HTTP-запросами.

### Подготовка публичного каталога

Закрытый Ed25519 PEM key должен быть создан и сохранён владельцем отдельно от
edge/runtime и Git. В этой работе создаются только одноразовые тестовые ключи.
Публичный ключ — raw 32 bytes в стандартном padded base64, отдельный файл.

```sh
python3 infra/route_catalog.py --topology topology.json --private-key offline-key.pem \
  --revision 1 --valid-days 7 --output routes-v1.json
python3 infra/client_config.py --topology topology.json --catalog-key-file public-key.txt client.json
```

Signer выводит публичный `ROUTE_CATALOG_KEY`, не закрытый ключ. Для нового D добавить
запись в topology, подготовить хост, подписать документ с большей revision и
опубликовать на известных входах по `/.well-known/voicechat/routes.json`.
**Production-публикация и bootstrap ещё не автоматизированы и здесь не выполнялись.**
Не удалять одновременно все ранее известные домены: без доступной начальной точки
клиент не сможет узнать о D. Компрометация signing key требует доверенного выпуска
с новым корневым ключом; каталог не уполномочен менять собственный trust anchor.

## Третья итерация: media, TLS и конфигурация физических узлов

- `RouteTransport` прерывает старый Matrix sync при смене маршрута; следующий
  запрос сохраняет курсор SDK. Тест подтверждает отсутствие повторной отправки
  операции записи. Control использует отдельный socket pool с общим координатором.
- `media_routes.dart` проверяет временные TURN credentials и разрешённые имена из
  подписанного каталога; initial/new LiveKit transport получает свежие credentials.
  `RoutedVoIP` и vendored `CallSession.restartIce` обновляют ICE configuration
  перед restart и не применяют запоздавший ответ к уже заменённому peer connection.
- Resume приложения запускает новую проверку входов. `RouteStatusBanner` показывает
  восстановление/отсутствие связи/частичную недоступность звонков; тесты light/dark
  при увеличении текста 2.5 проверяют отсутствие overflow, сохранение фокуса и
  черновика, live region и минимальную высоту кнопки. Это widget-проверки, не приёмка
  accessibility на реальном мобильном устройстве.
- `prototype/check_route_turn.py` / `.cjs`: два настоящих coturn, два WebRTC peers
  в новом headless Chrome, синтетический звук без микрофона и relay-only ICE.
  После остановки B и ICE restart через C сохранились оба peer connection,
  возобновились data channel echo и декодированный звук. Проба
  `voicechat-turn-803f6b87843d`: 465 мс **от начала восстановления**, без времени
  обнаружения. Это DTLS-SRTP WebRTC, не доказательство Matrix/LiveKit media E2EE.
- `infra/edge_config.py` переиспользует публичную политику существующего Caddyfile.
  Добавлены каталог/readiness, точный CORS allowlist, запрет private routes,
  удаление поддельных forwarded headers. PROXY protocol принимается только от
  одного назначенного private IP HAProxy; core upstream — private IPv4 туннеля.
  Неожиданное изменение границы исходного шаблона останавливает генерацию.
- HAProxy с закреплённым digest разделяет HTTPS и TURN TLS по SNI, отклоняет
  неизвестные имена и обновляет адреса контейнеров через DNS resolver.
  `prototype/check_route_tls.py` проверяет настоящий Caddy/coturn за одним
  loopback-портом: проверка CA/hostname включена, неизвестный SNI и чужая CA
  отклоняются, CORS/preflight/private routes/forwarded spoofing проверены.
  CA одноразовая и не добавляется в системное доверие. TURN TLS проверен STUN binding;
  передачу звука через TLS этот тест не доказывает.
- `node_inventory.py` отделяет public/tunnel IP, поколение машины и проверенный SSH
  host key от публичного списка входов. Валидируются дубли/неизвестные поля/ключи,
  откат поколения и повторное использование ключа заменённой машины.
  `render_edge.py` локально создаёт Caddyfile, HAProxy config, known_hosts и описание
  выбранного узла. Повторный запуск не перезаписывает каталог; ошибка валидации
  не создаёт output. Тесты подтверждают замену C без изменения client defines
  и добавление D без новой логики генератора. Bootstrap/Compose/deploy этим не заменены.

При настройке proxy использованы официальные описания
[HAProxy DNS resolution](https://www.haproxy.com/documentation/haproxy-configuration-tutorials/proxying-essentials/dns-resolution/),
[Caddy header matchers](https://caddyserver.com/docs/caddyfile/matchers#header) и
[Caddy PROXY protocol](https://caddyserver.com/docs/caddyfile/options#proxy_protocol).
Контракты дополнительно проверены закреплёнными в репозитории бинарными образами.

### Проверки на точке остановки 28 октября

- 51 Flutter-тест маршрутов, UI сети, media credentials/restart, сессий, direct
  media, cleanup/key sharing, screen protocol/lifecycle и chat actions — прошли.
- Полный `flutter analyze` — без замечаний.
- 25 Python-тестов topology, inventory/render, edge boundary, route health,
  изоляции стенда и существующего deployment — прошли.
- Повторная нативная macOS-проба `voicechat-routes-549dff223bef` — прошла:
  неизвестный сборке D принят из подписанного каталога; B/C остановлены;
  сообщения расшифрованы до/после переключения и повторного открытия профиля.
- Финальная TLS/SNI-проба и очистка собственного стенда — результаты в
  [сводке доказательств](three-vps-evidence/2026-10-28-local-checkpoint.json).

### Остановка и продолжение

По просьбе владельца работа приостановлена перед перезагрузкой компьютера.
Текущая подзадача offline inventory/render + TLS validation закончена.
Изменения сохранены в рабочем дереве, без commit/push/deploy. В репозитории остаются
и более ранние изменения других задач; их нельзя сбрасывать или считать частью
только этой доработки. Нет обещания выполнения фоновой работы после остановки.

Точная инструкция следующего запуска: [точка продолжения](19-three-vps-resume.md).
Текущие изменения не означают готовность всего MVP к production.

## Четвёртая итерация: независимые роли и TURN rotation

После перезагрузки владелец разрешил продолжить локальную реализацию.

- `role_config.py` / `render_roles.py` генерируют самостоятельный edge и core,
  переиспользующий существующий Compose через extends. Core сохраняет обычные
  имена volumes, signing/media paths и linked control/SFU lifecycle; configure
  валидирует прежние identity/origin до записи и добавляет TURN URLs из topology.
  Single-host поведение остаётся прежним без opt-in переменной.
- Edge содержит только ingress, web, readiness, TURN и initializer. Нет БД,
  пользовательских media, DB/control/Matrix secrets. Фиксированные private bridge
  адреса задают точный PROXY trust и не зависят от порядка запуска контейнеров.
  Read-only filesystem, bounded tmpfs и log rotation отделены от публичных assets.
- `edge_turn.py` генерирует coturn config с временной REST-аутентификацией, квотами
  и запретом private/metadata peer destinations. Принимает один секрет либо два
  на период ротации. Локально проверены overlap old/new, отказ отозванного old и
  просроченного credential; orchestration A/всех edge пока не реализован.
- Клиент фильтрует TURN URLs по пересечению ответа A и своего проверенного каталога:
  постепенное добавление D не ломает ещё актуальный B/C-кеш. Неизвестные TURN names
  не получают credentials, пустое пересечение по-прежнему отклоняется.
- `check_role_config.py` нормализует реальные Compose configs и дважды запускает
  core configure в одноразовых volumes с signing/media sentinel files. Проба
  `voicechat-role-294c91301e73` прошла. Это не запуск полного core/миграция БД.
- `check_route_tls.py --role-bundle` запускает generated edge с тестовым private
  upstream, реальными Caddy/HAProxy/coturn и одноразовой CA. Проверены HTTPS, CORS,
  readiness/failure, PROXY spoof rejection, TURN TLS allocation/auth/permissions,
  rotation и отсутствие тестового query token в request error logs.
  Fixture использует один bridge с подстановкой upstream IP; host WireGuard
  не проверен. Рабочий web image заменён pinned Caddy для проверки proxy.

Прошли 31 Python-тест, 19 Flutter-тестов media/route coordinator/transport и полный
Flutter analyze. Сводка прав, команды и ограничения — `infra/THREE_VPS.md`.

## Пятая итерация: проверяемая публикация каталога

- `route_catalog.verify` проверяет точные байты Ed25519, ограниченные размеры,
  JSON/schema, identity, lifetime и revision. Duplicate JSON fields отвергаются.
  Публичный ключ задан независимо; закрытый ключ остаётся только у offline signer.
- `publish_catalog.py` записывает один публичный `routes.json`, который одновременно
  является high-water mark. Локальный flock сериализует публикации; tempfile,
  atomic rename и fsync исключают частичный документ. Уменьшение revision, конфликт
  содержимого, повреждение/потеря предыдущего состояния прекращают публикацию.
  Начальная установка требует явного `--initialize`; повтор существующей — без него.
- Проверены добавление/удаление/возврат D с возрастающими revision, неверная подпись,
  другая identity, сроки/размеры/schema, конкурентные писатели и ошибка до rename.
  Истёкший сохранённый каталог всё ещё защищает от отката; новый должен быть свежим.
- TLS role probe публикует реальный подписанный artifact, обновляет его под уже
  работающим Caddy, получает точные новые bytes по HTTPS и отвергает старую revision.
  Container ID/StartedAt/RestartCount прокси не меняются. Проба
  `voicechat-sni-f7a4346a441a` прошла вместе с TURN rotation и очисткой своего стенда.

36 Python-тестов прошли. Первый запуск health fixtures был ограничен sandbox bind;
повтор с разрешённым локальным loopback прошёл полностью. Production/VPS/DNS,
существующие Docker-проекты, рабочие credentials и системное TLS trust не менялись.

Это ещё не multi-host deploy: публикация на всех входах, orchestration lock,
сохранение high-water mark вне release directories и rollout/rollback открыты.
Живой LiveKit reconnect, настоящие звонки/E2EE/устройства и 15-секундная цель
по-прежнему не приняты. Машинная сводка этой итерации:
[role/catalog evidence](three-vps-evidence/2026-10-28-role-catalog.json).

## Шестая итерация: файлы при сетевых отказах

- `route_io_test.dart` проверяет реальными loopback HTTP-соединениями, что текущий
  streaming upload заканчивается на первоначальном B после выбора C, а следующая
  операция идёт через C. Потеря socket после принятой сервером операции не вызывает
  автоматической повторной отправки на другой вход.
- `route_file_probe.dart`, вызываемый нативным integration test после initialization
  криптобиблиотеки, проверяет `ChunkedFile`: truncated ciphertext и подмена байта
  отклоняются, не попадают в part cache; явный повтор через C расшифровывает исходный
  файл, последующий read берётся из уже проверенного кеша. NativeImplementations
  использует настоящее SDK AES/hash, не подставную расшифровку.
- В Matrix-пробу добавлены настоящий upload ciphertext в Synapse и fresh authenticated
  download/decrypt до и после отключения B/C, а также после reopen прежнего профиля.
  После отказа используется D; кэшированный plaintext не считается доказательством.
- Проба `voicechat-routes-f908c90ffbbc` прошла, её временные контейнеры/volumes и
  синтетический профиль удалены. Проверены также 21 Flutter-тест socket/media/routes.
  Первая попытка native crypto в обычном unit runner выявила отсутствие Rust init;
  криптографическая проверка перенесена в настоящий нативный runner, без mock crypto.

Функциональных изменений download/upload не потребовалось: существующий транспорт
и проверка part integrity выдержали эти сценарии. Это не проверка реальных устройств,
всех размеров/avatars/links и не медиазвонок. LiveKit in-place reconnect остаётся
открытым: асинхронный RoomReconnecting callback сам по себе не является безопасной
точкой смены URL/ICE перед resume, а SDK lifecycle/ключи нельзя менять без отдельной пробы.

## Седьмая итерация: Android updater через выбранный вход

- `main.dart` передаёт updater отдельный `RouteTransport.fork()` при совпадении
  установленного canonical origin с origin сессии. Аккаунт/Authorization не
  добавляются в публичные update requests; closure/cancellation downloader не
  закрывает Matrix HTTP pool. Для single-host/другой установки прежний путь сохранён.
- `fork()` теперь сохраняет текущий ручной выбор и без координатора; с координатором
  по-прежнему разделяет его динамический выбор. Настоящий socket test подтверждает
  выбор C и продолжение запросов чата после закрытия fork.
- Updater test получает metadata через B, скачивает тот же выбранный пакет через C,
  отвергает несовпадающий hash и удаляет partial файл. Только явный повтор с правильными
  bytes проходит; новое metadata не подставляется автоматически. Существующие
  проверки APK/явного согласия и native installation guards не ослаблены.

Это Dart-уровень Android updater, не установка на реальном Android. macOS Sparkle
пока сохраняет фиксированный feed/enclosure origin; его переключение требует
отдельной интеграции с сохранением signed feed/package verification. Push и P2P
также не объявляются закрытыми этим изменением.

## Восьмая итерация: macOS Sparkle через выбранный вход

- Flutter передаёт snapshot проверенного entry при явном `check` и ещё раз при
  явном `download`. Отсутствие доступного маршрута не запускает native check;
  после восстановления доступен обычный ручной повтор. Проверка и загрузка могут
  использовать B и C соответственно без подмены выбранного update metadata.
- `MacUpdateRoute.swift` связывает canonical origin с встроенным `SUFeedURL`,
  разрешает только HTTPS origins без credentials/query/fragment и переписывает
  сетевой адрес canonical archive URL, сохраняя его путь. Внешние origins, другой
  порт identity, traversal/encoded escapes и чужие пути отклоняются.
- `MacUpdater` использует штатные Sparkle delegates `feedURLString` и
  `willDownloadUpdate:withRequest:` из закреплённого Sparkle 2.10.0. Подписанный
  feed остаётся идентичным на входах, enclosure URLs остаются каноническими;
  `SUPublicEDKey`, signed-feed requirement и package verification не заменены.
- 31 Flutter-тест updater/routes/socket прошёл. Нативный Foundation mapper
  скомпилирован и проверен вместе с прежними release/signature guards: 5 Python-
  запусков тестов, включая реальную CryptoKit-проверку подписи тестового архива.
- macOS Runner собран с новым Swift файлом и существующими Sparkle delegates;
  Matrix/file integration `voicechat-routes-f8eaeaec9123` прошла. Холодный Pod install
  выявил ASCII locale в runner: заменён на существующий macOS `en_US.UTF-8`, как
  в release workflow. Это исправление затрагивает только локальный test runner.

Полный цикл Sparkle через внешние B/C с подписанным production archive, установленной
версией и перезапуском приложения не выполнен. Ничего не устанавливалось поверх
пользовательского приложения; эта сборка проверяет compile/integration, а не приёмку
установки. Работающий transfer автоматически не повторяется при смене entry.

## Девятая итерация: один физический VPS и последующее расширение

Согласованный старт теперь поддержан схемой: topology содержит 1–32 входа;
`host: core` у одного edge явно связывает две роли с одним физическим узлом.
Core/edge сохраняют разные Compose projects, secrets и volumes. Непреднамеренное
дублирование физических IP/SSH keys и два edge на портах одного core запрещены.
Перенос edge на отдельный хост требует нового verified host key и generation;
canonical Matrix identity не меняется. Примеры: `infra/single-vps.example.json`
и `infra/single-node-inventory.example.json`.

Проверки: 24 Python-теста контрактов и 20 Flutter-тестов; реальные Compose/core
configure (`voicechat-role-32b6c4f1173d`), edge TLS/TURN/catalog
(`voicechat-sni-7ce1e02b59e2`), native Matrix/files
(`voicechat-routes-222b1be15ec7`). Последняя сборка знала только B, получила C/D
из signed catalog, сохранила профиль и расшифровала файлы после выключения B/C.
Это не перенос текущего production: private interface, firewall, TLS, миграция
портов со старого single-host Compose и безопасный rollout ещё не выполнены.

## Десятая итерация: LiveKit resume/restart и общий TURN для P2P

`RoutedLiveKitEngine` — изолированный адаптер закреплённого SDK 2.13.1. Ожидает
повторный выбор пути и получение проверенных временных TURN credentials до SDK
resume/restart, меняет WSS destination и ICE servers, сохраняет остальные RTC
параметры, Room и key provider. При resume обновляет оба существующих peer; при
full restart SDK создаёт их заново. Cloud region hint не обходит signed catalog.
Проверяется актуальность каталога после await и callback владельца: завершённый
звонок, смена transport generation и закрытый screen не должны возобновляться,
даже если SDK ещё не закончил dispose. `.pub-cache` не изменяется; SDK upgrade
требует повторить unit и native lifecycle probes.

`mediaIceServers` переиспользуется direct VoIP, LiveKit и P2P. Для routed installation
TURN запрашивается через отдельный закрываемый HTTP pool с deadline, проверяются
TTL/формат и пересечение hosts с каталогом; pool Matrix sync остаётся рабочим.
Режим обычного single-host клиента сохраняет прежнюю выдачу TURN. У P2P остаются
прежние уведомления direct/relay и явная повторная отправка после разрыва передачи.

В новой native пробе `check_route_livekit.py` настоящий LiveKit и B/C работают на
loopback с одноразовыми credentials. После остановки B SDK автоматически resume
через C; отдельно принудительно проверен полный SDK restart. В запуске
`voicechat-livekit-1493cc9677af` получены 378 мс и 199 мс соответственно; данные
доставлены до/после обоих путей, key provider сохранён, participant SID при resume
тот же. Оба тестовых участника используют одинаковый отдельный E2EE key provider.
Первый пробный запуск выявил отсутствующий ключ у получателя; стенд исправлен,
ошибка не объявлялась успехом. Это не доказательство расшифровки аудио/видео звонка.

36 Flutter-тестов media/P2P/call/screen, включая реальные loopback TURN HTTP
запросы, прошли; analyze без замечаний. Полная цель 15 с на устройствах/внешней сети,
lease revocation под отказами, TURN/TLS media и screen capture всё ещё открыты.
Итоговая повторная native проверка после cancellation guard фиксируется в evidence.

## Одиннадцатая итерация: контракт role release

`infra/role_release.py` фиксирует schema, роль/узел, commit, identity, совместимость,
immutable digests и полный список hashes bundle. CLI требует чистые committed
исходники и сверяет bundle перед записью нового manifest. Ничего не публикует,
runtime/секреты не читает; никакой commit в этой задаче автоматически не создавался.
Подменённые файлы, даже с изменённым checksum в manifest, missing files, symlinks,
неизвестные контракты и mutable image tags отклоняются. Web-only разрешает менять
только web image и commit при прежних исходниках/config/node/остальных образах.
Для staged topology допускаются разные hashes каталога при одинаковой identity
и совместимых контрактах. Legacy guards не ослаблены.

30 Python-тестов role release/role config/inventory/topology/catalog/proxy прошли.
Это локальная часть V3-19, а не завершение V3-20: workflow, отдельные pointers,
orchestration locks, backup, последовательный rollout и rollback ещё открыты.

## Двенадцатая итерация: генерация и настоящая проверка WireGuard

`tunnel_config.py` создаёт отдельный node-local X25519 key через OpenSSL, сохраняет
его на повторе и сверяет public key с private registry и host generation. Ключевые
файлы требуют owner-only permissions, правильного владельца, regular file без
symlink; повреждение не заменяется новой identity. Private configs содержат только
свой private key и public peer keys. Рендерер не применяет host networking.

`check_tunnel_config.py` поднимает три изолированных Linux network namespaces с
WireGuard kernel interfaces и private HTTP API A. В финальном запуске
`voicechat-tunnel-a8ca4ee2a3e1` прошли B→A/C→A, остановка B, смена его ключа через
`wg syncconf` без restart A, отказ прежнему ключу, работа нового ключа и C. После
удаления всех remote peers private API A сохранился, что покрывает адрес интерфейса
для начальной одноузловой схемы. Результат не включает provider firewall или
реальный Docker host DOCKER-USER ACL.

Fixture исправлен по результатам запусков: ограниченное ожидание повторного
начального handshake, IP endpoints при остановленном контейнере вместо исчезающего
Docker DNS имени, поддержанный Compose 2.19 `up --no-recreate --wait` вместо
отсутствующего `start --wait`. Диагностика не печатает private keys/showconf/dump.
Все временные проекты удалены; прежний `voicechat-prototype` не запускался.

35 Python-тестов tunnel/release/roles/inventory/catalog прошли. В image закреплены
base digest и версии wireguard-tools 1.0.20210914-1+b1, iproute2 6.1.0-3,
iputils-ping 3:20221126-1+deb12u1; конкретный проверенный ID записан в evidence.
Host bootstrap, firewall, persisted routes/peers, TLS renewal и role deploy открыты.

Повторная native LiveKit проверка после lifecycle guard:
`voicechat-livekit-0ed8730e0724`, resume 670 мс, full restart 339 мс, доставка данных
после обоих путей. Эти значения относятся только к loopback fixture.

По дополнительному запросу владельца подготовлена
[схема сетевого взаимодействия](../architecture/network-topology.md): один VPS,
разнесённые роли, WireGuard, отдельный TURN→публичный SFU путь и signed discovery.

## Тринадцатая итерация: конфигурация CI candidates

`client_config.py --environment` принимает пару публичных CLIENT_ROUTE_CONFIG /
CLIENT_ROUTE_CATALOG_KEY, проверяет canonical identity, размер/дубликаты JSON и
канонический Ed25519 public key. Без пары сохраняется прежний single-host режим;
старый вызов без флага не читает окружение. Четыре workflow передают параметры
клиентской сборке. Android candidate сохраняет public client-config.json; reuse
проверяет точное совпадение перед repackaging, старому APK нельзя приписать новый
каталог/ключ. Routed production publish явно закрыт до готовности role deploy.
Ни Actions, ни публикация, ни изменение GitHub variables здесь не выполнялись.

Общий read_json ограничивает чтение 64 KiB и отклоняет duplicate keys/invalid UTF-8.
Его используют topology, inventory, role manifest, tunnel registry и candidate
config. Прошёл 51 Python-тест. Четыре YAML разобраны, 32 shell-шага прошли bash -n.

## Четырнадцатая итерация: отказ WSS при здоровом HTTPS

Readiness 200 не доказывает доступность конкретного API/WSS пути. Координатор
учитывает реальные ошибки отдельно для Matrix, control и signaling; неудачный
маршрут временно исключается, при отказе всех выбирается наиболее давно отказавший.
Один вход продолжает проверяться. HTTP transport сообщает network/502/503/504 без
повтора мутаций и без трактовки auth/rate-limit/cancellation как отказа сервера.
LiveKit сообщает сетевую ошибку начального connect, а CallProbe сохраняет владение
lease/retry. 401/403/429 и certificate pinning не запускают этот цикл. При resume
оборванный WSS меняется даже при readiness 200; здоровый WSS при ICE restart не
помечается ошибочным. Lifecycle guards сохраняются.

47 Flutter regressions прошли; analyze без замечаний. Native fixture теперь
отключает только upstream WSS B, оставляя front B и /health/route доступными.
`voicechat-livekit-d21d703be13d`: resume через C 398 мс, full restart 265 мс, данные
до/после обоих путей доставлены, participant SID при resume и key provider
сохранены. Это loopback LiveKit data proof, не E2EE audio/video, TURN-to-SFU или
полная аппаратная/lease приёмка 15 секунд. Временный проект удалён.

## Пятнадцатая итерация: read-only host preflight и общая регрессия

`host_preflight.py` добавляет проверку чистого physical host до установки.
Проверяет собственный SSH public key против inventory, initial Debian 12 amd64
профиль, systemd/time sync, ресурсы, TCP/UDP sockets и Docker DNAT publications,
route tables/Docker subnets против всех planned tunnel /32 и edge bridge.
Один core+edge проверяется как один physical node с объединением портов.
Ошибки/timeout чтения блокируют готовность, чужие службы и networking не меняются.
Установка dependencies, повторный rollout существующей роли и migration A этим
инструментом не выполняются.

Шесть содержательных тестов: роли/alias, host mismatch/resources/clock/fail-closed,
пересечения сетей, IPv6/IPv4 socket parsing, Docker DNAT без host socket и timeout.
С предыдущими infra regressions — 57 тестов. Read-only Docker fixture с network
none и cap-drop ALL обнаружил настоящий UDP 51820 и loopback route, сохранил
ошибки отсутствующих systemd/NTP/SSH identity. Это отрицательная collector проба,
не положительная приёмка чистой VM.

Полный Flutter test --no-pub: 319 passed, 3 skipped (опциональные визуальные capture
HALO_CAPTURE, HALO_POLISH_CAPTURE, AUTH_CAPTURE). Это VM/widget tests, не Android
или browser/hardware acceptance. Предыдущий analyze без замечаний.

## Шестнадцатая итерация: browser contracts и реальная подпись/кеш

29 общих HTTP/coordinator/media lifecycle/banner тестов прошли в Chrome через
`check_route_web.py`. Test-only defines встраивают исходные infra JSON fixtures,
не создавая второй источник конфигурации. В banner-тесте найдено зависание stream
callbacks под fake clock: tester.runAsync исправляет harness, native checks
сохранены (21 focused, затем 2 banner).

Установлены точные Rust 1.99.1/nightly-2026-10-24/rust-src/wasm target и crypto
tools из infra/crypto-tools.json. build_web_assets.py успешно пересобрал vodozemac
из pinned commit, E2EE worker и QR assets. Артефакты не публиковались.

`check_route_catalog_web.py` + CJS runner и tool/route_catalog_web_probe.dart
проверили обычную JS release-сборку в свежем Chrome profile. Настоящий WASM verifier
принимает подпись OpenSSL и discovered D; browser localStorage сохраняет revision.
Rollback, tamper, expired catalog, foreign identity и конфликт revision отвергнуты.
После настоящей перезагрузки страницы и offline обоих входов остаются D/revision 4;
старый список не принимается, отдельный synthetic account marker сохранён.
Это не проверка восстановления реального Matrix аккаунта или E2EE медиапотока.

Пробы выявили ограничения test environment: CanvasKit test iframe Flutter 3.47
не получает COEP при отдельном isolation flag; экспериментальный Dart/Wasm runner
несовместим с decoder текущего flutter_rust_bridge (JSValue/List cast). Эти пути
не объявлены успешными. Финальная проба использует production JS compilation
path и настоящий изолированный HTTP server с COOP/COEP, без правок SDK/cache и
без отключения browser security. Итоговый лог browser-catalog-js-release.log.

## Семнадцатая итерация: persisted WireGuard runtime

`tunnel_runtime.py` сохраняет один атомарный owner-only desired state и под lock
применяет только собственный wg-vc/private address/peer routes. Проверки collision,
чужого интерфейса/ключа, local identity, generation, malformed state и permissions
выполняются до mutation. После сбоя --resume повторяет сохранённое намерение;
private key/config не разнесены по независимо заменяемым файлам. Revoked peer
не возвращается автоматическим rollback. Default routes/firewall/forwarding/SSH
не меняются. Шесть новых unit-тестов; вместе 63 infra regression tests.

Реальный fixture `voicechat-managed-wg-3aecc890d684` прошёл: повтор без лишних
маршрутов, новый B на отдельном host IP/key, отказ старому B, работа C, добавление D,
добавление /32, неизменный StartedAt A при изменении peers, восстановление удалённого
wg-vc, перезапуск контейнера A из volume state, затем zero-peer A и retirement
старых маршрутов. Временные containers/volumes/network удалены.

Первый запуск выявил медленное восстановление после потери session state A при
keepalive только на edge. Общий renderer теперь задаёт 25 s на обоих концах;
это запускает новый handshake при link-up A. Поведение сверено с исходником
Linux WireGuard wg_open; финальный реальный повтор прошёл. Нет правок SDK/production,
нет ослабления readiness timeout. Полноценные systemd/reboot VM, provider/Docker ACL,
внешний MTU, package installation и role rollout ещё не приняты.

## Восемнадцатая итерация: firewall, DNAT и atomic runtime

Добавлены scoped nftables renderer/runtime. Private API и signaling доступны
из известных WG peers; co-located web/health допускаются отдельно от relay.
SFU media разрешены edge public IP/локальному coturn, прямые клиенты закрыты
согласно ТЗ. Исходные conntrack ports/direction учитывают Docker DNAT.
AllowedIPs проверяет источник, но не ограничивает назначение: дополнительные
правила запрещают peer использовать A как транзит в другие сети.

Runtime проверяет ownership, делает nft --check и atomic batch replacement,
сохраняет новое намерение перед apply, умеет --resume без возврата revoked peers.
Общий owner-only JSON/lock/fsync код вынесен в managed_state.py из WG runtime.
Добавлены 4 policy и 5 runtime tests; вместе 76 infra regression tests прошли.

Реальный fixture voicechat-firewall-c12e424a3ece прошёл: HTTP/UDP, INPUT/FORWARD,
DNAT, hostile WG transit, co-located bridge roles, повтор/resume после удаления
таблицы и сохранение чужих tables. nft 1.0.6 не отдаёт table comment в JSON;
ownership строго проверяется по anchored textual header/comment. Портам conntrack
потребовался meta l4proto; проверки не заменены mock assertions.

В harness исправлены блокировка routed destinations у internal Docker bridge,
пропущенный Compose третий network attachment и rename Docker interface. Последний
оставил ghost network voicechat-firewall-61bd4566a853_local: Containers пуст,
rm/disconnect отказывают active endpoints/not found. Это единственный известный
остаток неудачного fixture; Docker и другие проекты не перезапускались. Финальный
fixture создаёт настоящий bridge и полностью удалён. Только synthetic data,
нет опубликованных host ports или запросов в Internet.

Повторный WireGuard runtime voicechat-managed-wg-1e81209070d4 после extraction
state helper прошёл. Role configure voicechat-role-1a8552851834 и TLS/SNI role
voicechat-sni-645435c3e90b подтвердили stable bridge, private proxies, catalog,
TURN allocation/secret rotation и trust guards. Все эти fixtures очищены.

Схема обновлена: API/WSS через WG, TURN к публичному SFU с ACL, без прямого
client→SFU. Открыты packages/systemd boot ordering, IPv6/secondary bind controls,
provider/Docker-host acceptance, TLS automation и полный role rollout/rollback.

## Девятнадцатая итерация: bind/bridge isolation и общий network intent

Core bundle закрепляет legacy public binds за inventory IPv4, не наследуя
широкий BIND. Это исключает обход на IPv6/другом host address. Его default bridge
получил стабильное имя; firewall дополнительно блокирует напрямую маршрутизируемые
container IP, сохраняя внутренний core traffic. Preflight проверяет имя bridge.
Core namespace/volume names сохранены; переход существующего network требует
запланированной миграции, renderer работающую сеть не меняет.

Реальный firewall fixture voicechat-firewall-d70f6a89fd35 подтвердил прямой
container-IP bypass до установки filter и отказ после, при рабочем разрешённом
API/media и чужом DNAT на другом bridge. Core configuration fixture
voicechat-role-ba713a730ba7 проверил normalized binds и сохранение identity/media.
Оба очищены. Unit/regression assertions дополнены, без релиза/изменений VPS.

network_runtime.py хранит общий intent для firewall/WireGuard и применяет
ограничения перед сменой peers. Прерывание между шагами больше не оставляет
--resume с двумя разными inventory. 4 новых теста: обрыв с отзывом peer, потеря
обоих kernel components, foreign/unclaimed collisions и identity/lock guards.
Общая suite: 80 passed. Исходники networking и systemd units включены в role
bundles/manifests; web-only guard защищает их от частичной подмены.

Coordinated real Linux fixture voicechat-managed-wg-59f4c47ec578 прошёл B replacement,
D addition, сохранение C, recreation interface, restart A из общего persisted state
и zero-peer A. Контейнеры/тома/network удалены. Новый verifier image
sha256:e2ac5ac00e116d277e0e41bebb580bee5dd8836c8ec2b8ab5a4b5b71e81ff83f
добавляет pinned systemd 252.39-1~deb12u2 и Debian Python 3.11.2-1+b1.

voicechat-network.service и Docker drop-in проходят systemd-analyze verify,
missing state и negative dependency-cycle проверки в контейнере network=none,
cap-drop ALL, read-only mounts. Это parser/entrypoint proof, не PID 1/VM boot.
Установка пакетов/units, verified SSH orchestration и reboot acceptance остаются
открытыми; unit нельзя просто включить поверх чужого/немигрированного Docker host.

## Двадцатая итерация: verified SSH и установщик сетевого автозапуска

host_connection.py строит соединение по точной host identity из inventory,
отдельному temporary known_hosts и owner-only client identity. Нет наследования
SSH config/multiplexing/agent forwarding/TOFU/UpdateHostKeys. Remote argv остаётся
данными через shlex, секретные payloads проходят stdin. Timeout/failure не
превращается в успех; temporary trust file удаляется. 3 unit tests passed.

Реальный OpenSSH fixture voicechat-ssh-f371de388b81 прошёл: исходный login, неверный
host key не исполняет команду, shell metacharacters остаются literal, binary stdin
передаётся точно. После смены synthetic server key старый inventory отвергнут,
новое поколение принято. Первый fixture выявил необходимость абсолютного argv[0]
для sshd re-exec; harness исправлен, обе пробы очищены. Нет production SSH/DNS.
Tools image sha256:1777dd22a8397fbc30730d03924dfffd770ad59f11a0fb53ee1820d8a656a477
добавляет pinned OpenSSH 1:9.2p1-2+deb12u10; пакетные host keys удаляются из образа.

network_bootstrap.py устанавливает immutable code по source hash и два owned
systemd файла на уже подготовленном Linux node. До записи сверяются local SSH
host identity с network intent, running systemd/tools и все destination files.
Receipt/atomic file creation позволяют продолжить обрыв, без присвоения чужих
units/files, symlinks или перезаписи изменённого кода. Только та же версия может
повториться; upgrade отдельный. verify предшествует daemon-reload/enable/start;
успех фиксируется после active/enabled. Docker не перезапускается.

4 installer tests (filesystem + injected command failures), вместе 87 общих
infra regressions passed. Реальный VM installer/systemd start ещё не выполнен;
unit parser/runtime kernel proofs предыдущей итерации не выданы за boot proof.
Полный package/SSH bootstrap, TLS automation, role release/rollback и переход A
остаются открытыми. Все изменения локальны, без commits/push/VPS/DNS.

## Двадцать первая итерация: SFU-originated reply ACL

Расширенный kernel fixture воспроизвёл обход: SFU первым отправлял UDP клиенту,
и ответ проходил через существующий SNAT mapping в reply direction. Проверка
только original destination/port пропускала такой поток. Добавлены media reply
source guards для core bridge, включая remote edge и co-located relay.

Regression сначала упал на старом filter, затем voicechat-firewall-18f116093cb1
прошёл с исправлением: direct reply запрещён, remote B разрешён, после перехода
к single-host разрешён local relay и запрещён retired B. INPUT/FORWARD/DNAT,
transit/container-IP guards и чужой DNAT продолжают работать. Fixture очищен.

Core namespaces резервируют 50300-50400 через ip_local_reserved_ports, чтобы
эпhemeral DNS/client sockets не попадали под media ACL. Настройка не меняет host
sysctl. Отдельный network=none/cap-drop ALL kernel test с диапазоном назначения
50300-50401 подтвердил automatic bind только 50401 и разрешённый explicit 50302.
Role fixture voicechat-role-36200cb78267 проверил настоящий sysctl в configure,
нормализованные bind/bridge и сохранение identity/media; очищен.
24 focused policy/role/bootstrap/coordinator tests прошли; новые fixtures не
выдаются за actual app E2EE media или внешнюю сеть. Production не менялся.

## Двадцать вторая итерация: DuckDNS и TLS material / ACME controller

Владелец решил сохранить DuckDNS сейчас. Собственный домен + Cloudflare DNS only
и узкий зоной API token записаны в ТЗ/план как **невыполненная V3-T04**. Сохранить
Matrix identity, canonical/bootstrap compatibility; не менять действующие адреса.

`tls_material.py`: snapshot bounded PEM/key, SAN всех web/canonical или TURN имён,
matching key, serverAuth/strict full chain сейчас и на минимальный срок, отсутствие
CN fallback. Owner-only immutable generation публикуется одной операцией, старые
пары не изменяются. 5 тестов с настоящим OpenSSL/private CA, включая повреждение,
повтор, interrupted staging, missing intermediate/untrusted root и negative inputs.
Role bundle включает validator. Реальный Caddy/coturn role fixture
voicechat-sni-5e605f23ed78 прошёл через этот staging и очищен.

`acme.py`/acme-tools.json: lego 5.5.2 закреплён digest
1944e8c36055beec47c7de6f15202b41128be75eea0ffa257f0c14d93c5155fd.
DuckDNS allowlist, per-generation certificate IDs, contact/environment binding,
один controller lock для всех имён/входов. Provider token передаётся через private
file, provider diagnostics не выводятся. Контейнер cleanup предшествует проверке
пары; inflight marker блокирует следующие jobs при неопределённом результате.
6 tests покрывают сериализацию, отказ CA/timeout/cleanup/create, смену identity,
отсутствие разрешения CA terms и unclaimed state. Это injected runner tests.

Отдельно реальный закреплённый CLI запущен с fake token и `--network none`:
флаги приняты, сеть отказала, контейнер/token очищены. CA/DNS API не вызывались;
это не issuance proof. Scheduler, transport/activation/reload, настоящий DNS-01
renewal и role rollout остаются открытыми. Прежние ограничения устройства/VM
сохраняются, commits/push/VPS/DNS изменений нет.

Общий инфраструктурный regression: **98 tests passed**. Следующая локальная проба
TLS renewal/rollback (voicechat-sni-fd60e4e81b97) тоже прошла и очищена: immutable
пары + atomic current symlink внутри mount, Caddy SIGUSR1/coturn SIGUSR2, новые
handshakes подтверждают выбранный сертификат, прежний TURN allocation переживает
оба переключения, контейнеры не перезапускались. Первая попытка ed9db98c20d7
показала закрытие idle HTTPS socket на Caddy reload; ожидание бесшовного HTTP
keep-alive было неверным. Свежие HTTPS requests проходят; WSS/call continuity не
доказаны и остаются открытыми. Пока это fixture publisher, без production activation.

## Расширение разрешения владельцем

28 октября владелец сообщил, что отойдёт на несколько часов, и прямо разрешил
продолжать до завершения функционала, включая необходимые deploy и работы VPS/DNS,
самостоятельно выбирая рекомендуемые решения. Прежняя граница «только локально»
снята. На момент этой записи production/DNS ещё не менялись. Сначала завершить
необходимые инструменты и проверки, собрать actual baseline/backup/rollback;
разрешение не означает, что незавершённая реализация уже готова к выкладке.

## Интеграция с актуальным production и web push — 28 октября

После разрешения владельцем VPS/deploy выполнен изолированный Linux TLS probe
на текущем хосте. Production не менялся; [результат](three-vps-evidence/2026-10-28-vps-tls-runtime.json).
Выявлены Ubuntu 24.04 и совместный ingress Avito Helper на 80/443: необходим
отдельный безопасный переход, а не установка bundle поверх занятого порта.

Код задачи перенесён в `codex/three-vps-rollout` на main `2cca4d3`, содержащий
production `8bcbd91`. Новые изменения UI/звонков/P2P сохранены. 106 инфраструктурных
тестов и анализ Flutter прошли; единственная ошибка полного клиентского прогона
была отсутствующим каталогом выходного QR fixture и отдельно перепроверена.

Web push теперь использует отдельный routed HTTP pool из общего coordinator:
config/register/remove, включая отмену регистрации при ошибке local binding.
Запрос разрешения остаётся синхронным в пользовательском клике; worker/account
binding не переносится на origin входа. Redirect запрещён, POST не повторяется
на другом входе. Серверный push gateway и реальная доставка на телефоне остаются
отдельной приёмкой.

## Завершён блок TLS activation — 28 октября

Публикация, reload и подтверждение сертификата теперь связаны общим TLS writer
lock. Точный container/image/readonly mount проверяется до изменений, а процесс
не должен перезапуститься. Повтор не дренирует Caddy без смены пары. Сбой остаётся
pending, retry/rollback переиспользуют действующие immutable generations.

Контроллер прошёл настоящий изолированный VPS fixture с сохранённой TURN allocation
и rollback; [свидетельство](three-vps-evidence/2026-10-28-vps-tls-activation.json).
Production и соседний сервис не изменены, cleanup завершён. Общий Python набор
121 PASS; затем усилен guard release bundle против дополнительных Python modules,
7 focused manifest tests PASS. Это не приёмка автоматического внешнего ACME
renewal, role orchestration, WSS или реальных звонков.
