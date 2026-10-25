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
