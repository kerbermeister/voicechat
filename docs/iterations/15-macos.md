# macOS Apple Silicon — журнал реализации

25 октября 2026. Рабочая ветка: `codex/macos-apple-silicon`; в main не сливать.
[ТЗ](../macos-spec.md), [план](../tasks/15-macos.md).

## Аудит зависимостей

- Используется закреплённый Flutter 3.47.7 из `.prototype/tools/flutter`, а не
  системный Flutter 3.32.2. Xcode 16.4; машина arm64/macOS 15.3.1.
- Нижняя цель — macOS 12.0. Сам закреплённый Flutter автоматически мигрирует
  deployment target 11.0 на 12.0. macOS 11 не заявляется поддерживаемой.
- Podspec/Package.swift текущих WebRTC/LiveKit, SQLCipher, secure storage,
  audioplayers, record, video_player и mobile_scanner заявляют macOS с минимумом
  не выше 12. Это аудит деклараций, не реальная проверка старой системы.
- `camera`/`camera_avfoundation` не регистрируют macOS. WebRTC MediaRecorder
  в Darwin-исходниках ограничен `TARGET_OS_IOS`. Для общего экрана видеокружков
  добавлен небольшой CameraPlatform-адаптер AVFoundation, без нового UI.
- SQLCipher не поддерживает SPM. Flutter-плагины подключаются CocoaPods;
  встроенный updater — отдельно закреплённый Sparkle 2.10.0 через SPM.
  Первый cold build выявил недостающий SourcePackages и неполную генерацию
  FlutterGeneratedPluginSwiftPackage; CocoaPods избегает этого пути.
- macOS использует login Keychain через `MacOsOptions(usesDataProtectionKeychain:
  false)`: совместное использование ключей с другими приложениями не требуется.
  Это рекомендованный документацией secure_storage путь без Keychain Sharing
  и machine-specific provisioning profile. SQLCipher остаётся обязательным.
- Действующих signing identities не найдено. Developer ID/notarization и
  доверенный подписанный переход N → N+1 пока не проверены.

## Уже выполненные проверки

- Swift typecheck `PlatformFiles.swift` и `NoteCamera.swift`, target arm64/macOS12:
  проходит с текущим SDK. Это не полноценная линковка или физическая проверка камеры.
- `macos_camera_test.dart`: 2 проверки общего CameraController, MP4-контракта
  и отказа разрешений; нативный канал подменён.
- `macos_update_test.dart`: 2 проверки отсутствия фоновой проверки/загрузки,
  явных действий пользователя и блокировки установки активным звонком.
- Реальный macOS build ещё проходит интеграцию; готовый артефакт не заявлен.

## Открытые проверки

Сборка/запуск всего приложения, нативные XCTest, реальные Keychain/SQLCipher,
микрофон/камера и звонки, уведомления, подписанный updater, macOS 12–14,
Developer ID/notarization, DMG и CI. До них этапы не отмечаются полностью готовыми.

## Итерация 2: runner и платформенные адаптеры

Добавлен runner arm64/macOS 12, CocoaPods для Flutter-плагинов и Sparkle 2.10.0
через отдельный SPM package. Общий Flutter UI сохранён. Реализованы системные
файловые панели с потоковым IO и атомарным завершением записи, внешние ссылки,
AVFoundation-адаптер существующего CameraController для MP4-видеокружков,
локальные уведомления с привязкой к сессии и ручной экран обновления через Sparkle.
Не настроенный канал обновлений закрыт для сетевых запросов и показывает ошибку
конфигурации по кнопке проверки. Подписанный feed и пакеты обязательны.

SQLCipher не создаёт новую БД до успешного чтения записанного ключа из Keychain.
Используется login Keychain без entitlement совместного доступа. Добавлен
интеграционный тест реального Keychain/SQLCipher на одноразовом профиле; пока
не запускался, поэтому сохранность ключей при реальном обновлении не подтверждена.

Проверено: Flutter analyze без замечаний; 6 целевых widget/unit-тестов камеры,
updater и уведомлений прошли. Swift-адаптеры компилировались Xcode 16.4; полная
сборка остановлена при распаковке Flutter engine: `No space left on device`.
Повтор после удаления только созданных этой задачей промежуточных артефактов
также исчерпал место. Это не успешная сборка .app. Полный Flutter-набор запускается
последовательно отдельно; результат фиксируется следующей итерацией.

Для connectivity_plus 7.3.2 добавлена узкая совместимость с SDK до 26: недоступный
в старом SDK признак спутниковой сети всегда false. Обычные состояния сети
сохранены; зависимость общего Android/web-клиента не понижалась.

Реальные камера/микрофон, сохранение файлов под sandbox, звонки/E2EE,
уведомления ОС, macOS 12–14 и подписанный переход N → N+1 не проверены.
Сертификатов подписи Developer ID в локальном Keychain нет.

## Итерация 3: успешная нативная сборка и реальное хранилище

После восстановления Flutter cache штатным `flutter precache --macos --force`
и исправления дублирующей фазы embedding Sparkle debug `.app` собран успешно.
Xcode сам встраивает framework SPM; ручная copy-фаза удалена.

Проверка каждого Mach-O обнаружила sqlite3.framework с minimum macOS 13. Это
транзитивная библиотека необязательного backend Matrix; наш native store работает
через sqflite_sqlcipher. Для `sqlite3` включён штатный hook `source.macos=system`,
остальные платформы не изменены. SQLCipher остаётся отдельным встроенным framework.
После смены hook пересоздан выходной `.app` и каталог generated native assets,
чтобы исключить оставшуюся от предыдущей incremental-сборки библиотеку.
Проверка arm64 и minimum OS ≤12 всех Mach-O, а также `codesign --verify --deep
--strict` прошла. Это проверка бинарных требований, не запуск на macOS 12.

Проверено на локальной macOS 15.3.1 / arm64 / Xcode 16.4:

- `flutter test integration_test/macos_storage_test.dart -d macos`: **1 passed**.
  Настоящие Keychain, Vodozemac и SQLCipher; одноразовый профиль удалён в finally.
  Ключ прочитан обратно, данные прочитаны после повторного открытия, plaintext
  не найден в БД. Потеря и замена ключа дали отказ, байты БД сохранились.
- `xcodebuild … test`: **RunnerTests passed** (границы чтения файлов).
- Обычный `lib/main.dart` собран заново. Реальный запуск и экран входа проверены
  через UI; текущий дизайн сохранён. Окно «О приложении» показывает версию 1.1.0/2,
  явная проверка возвращает «Канал обновлений этой сборки ещё не настроен»,
  закрытие возвращает на экран входа. Учётные данные пользователя не вводились.
- Общий Flutter-набор: **247 passed, 3 skipped**, analyze без замечаний.
  После дополнительной защиты от позднего завершения старой notification-сессии
  выполняется финальный повтор; итог записывается ниже.

Первый XCTest-проход упёрся в удалённый ранее compiler cache; после его
восстановления тест прошёл. Неуспешные попытки не считались проверкой функции.
Нет Developer ID identities; настоящая подпись, notarization и переход N → N+1
пока не выполнялись. Межплатформенные звонки, camera/mic, системные панели под
sandbox и macOS 12–14 по-прежнему требуют отдельной приёмки.

## Итерация 4: воспроизводимая поставка и серверный канал

Добавлен ручной workflow `macos.yml`: общий анализ/tests, реальное disposable
хранилище, XCTest, release build и development DMG/ZIP. Сам workflow ещё не
запускался на GitHub. `macos_release.py` проверяет все Mach-O, bundle ID, minimum
OS, manual-only updater и (в release-режиме) Developer ID/Team/hardened runtime.
Подписанный путь выполняет notarization/stapling, проверяет ZIP по встроенному
публичному ключу, сохраняет прежние совместимые items и подписывает appcast.

`publish_macos.py` проверяет точный принятый build/hash, неизменяемость архивов,
monotonic build даже после отзыва, исходный feed и атомарно меняет только feed
после публикации ZIP/DMG. Добавлены mount/runtime-каталог и отдельный Caddy route.
Production не обновлялся: первая настройка требует штатного full-релиза.

Проверки:

- 4 Python-теста контрактов/подготовки feed/публикации прошли. Они используют
  fixture-пакеты, не доказывают notarization или криптографическую установку.
- Реальный локальный Caddy в Docker: ZIP/DMG и Android APK доступны отдельно,
  feed/latest no-cache, архивы immutable, служебные пути/missing URL дают 404;
  SPA и Android-канал сохранены. Контейнер запускался без сети и удалён.
- 19 тестов deployment/full/web/backup прошли. Fixtures больше не зависят от
  свободного места ноутбука; отдельный тест подтверждает, что настоящий guard
  `<2 GiB` останавливает deploy до изменения служб/manifest. Сам guard не изменён.
- YAML Compose/workflow разобран Ruby YAML, Python-файлы компилируются.

Инструкция подписи/публикации: `infra/MACOS.md`. Developer ID/notarization,
подписанный update N → N+1, release-сборка, GitHub runner и реальные старые ОС
остаются непроверенными до отдельного успешного выполнения.

Финальный повтор после изменений notification lifecycle/native-assets:
`flutter analyze` — no issues; **247 tests passed, 3 skipped**. Системная SQLite
для optional backend не нарушила текущий общий Flutter-набор.

## Итог локальной упаковки

Фактическое железо: **Apple M1 Pro**, macOS 15.3.1. Тестовый development DMG/ZIP
создан из чисто пересобранного обычного `main.dart`; `hdiutil verify` и `unzip -tq`
прошли. Перед упаковкой output `.app` пересоздан после XCTest: внедрённые тестом
библиотеки XCTest не должны попадать в пользовательский пакет.

Локальные файлы (игнорируемый `.prototype`, не Git-артефакты):

- `.prototype/macos-development-candidate/VoiceChat.dmg` — около 70 MiB,
  SHA256 `01cee590da7229dec5802fc4edffe7ca1183fbc8387f239d0ac4fad7e02eea7a`.
- `.prototype/macos-development-candidate/VoiceChat.zip` — около 61 MiB,
  SHA256 `c70857f4ad545de3c8bb68de30f3698a33cadbc26cfd9a6fd69e66df32dae0fc`.

Это **Debug/development**, `distributable=false`, `sourceDirty=true` (в рабочем
дереве есть сторонние незакоммиченные файлы). По умолчанию сервер localhost,
канал обновлений не задан. Пакет не опубликован и не является подписанным релизом.
Для пользовательского релиза нужен Release с каноническим PUBLIC_URL, Developer ID,
notarization, публичным ключом/feed и полной физической приёмкой. Упаковщик
отдельно запрещает выдавать Debug/JIT `.app` за release даже при наличии подписи.

Дополнительный тест реальным CryptoKit прошёл: проверка ZIP принимает подпись
правильного публичного ключа и отвергает другой ключ/изменённые байты. Итого
**6 Python-тестов macOS**, включая отказ для Debug/JIT release-кандидата; это не заменяет подписанный цикл Sparkle N → N+1.

## 26 октября: установочная Release-сборка с production-сервером

По запросу владельца в той же ветке добавлен публичный build config
`apps/client/config/macos-production.json`; исходный commit `e08db86`.
Адреса: Matrix `https://univc.duckdns.org`, API `https://univc.duckdns.org/api`,
LiveKit `wss://univc.duckdns.org`. Endpoint `/_matrix/client/versions` успешно
проверен по HTTPS. Серверные службы/production и main не изменялись.

Перед сборкой проверен diff относительно production baseline `5fd75f4` из
журнала серверного выпуска; для этой задачи собран только macOS-клиент.
Выполнен `flutter build macos --release --target lib/main.dart
--dart-define-from-file config/macos-production.json --no-pub` с закреплённым
Flutter/Rust и локальным Xcode 16.4. Размер `.app` — 89.4 MB; версия 1.1.0+2.
Локальный override отключал debug symbols и explicit compiler modules для
ограниченного диска; режим компиляции приложения — Release/AOT, не Debug.

Проверено: все три значения присутствуют в Xcode DART_DEFINES и AOT-бинарнике;
Debug kernel отсутствует. Упаковщик проверил Mach-O arm64/minimum OS ≤12 и
целостность локальной code signature. После упаковки проверены DMG checksum,
ZIP CRC и SHA256 файлов. DMG смонтирован только для чтения: внутри повторно
проверены подпись, arm64, production-адреса и ссылка Applications; образ отключён.
Общий Dart-код не менялся, полный прежний набор тестов повторно не запускался.

Установочные файлы:

- `.prototype/macos-server-candidate-20261026/VoiceChat.dmg` — около 39 MiB,
  SHA256 `49754928f06126c14e02b673b329cb78de39b7a4d8eec08bfa177818cd184036`.
- `.prototype/macos-server-candidate-20261026/VoiceChat.zip` — около 35 MiB,
  SHA256 `820e7faaa94fff6564a70013ba34b46bf16d8acd0a8327d1ec49e2ce049e7185`.

Открыть DMG и перенести VoiceChat.app в Applications. Сохранённый ранее вход,
если он есть, сохраняет собственные адреса аккаунта: его не перезаписываем
новыми compile-time defaults. Для нового входа уже выбран production-сервер.

Это тестовый установочный пакет Release, без Developer ID/notarization и без
публикации в Sparkle (`distributable=false`, feed пустой). `sourceDirty=true`
честно отражает посторонние незакоммиченные файлы рабочего дерева; они не входили
в наши коммиты. Вход под аккаунтом владельца, звонки и macOS 12–14 не проверялись.
