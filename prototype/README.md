# Локальный прототип E2EE

Это лаборатория на одноразовых аккаунтах, а не готовый мессенджер. Основной клиент находится в `apps/client/lib/main.dart`, автоматический сценарий — в `lib/lab_main.dart`. Используются настоящие Synapse, Matrix SDK/vodozemac и LiveKit. Медиа-ключи передаются через зашифрованные Matrix to-device события; сервер выдачи JWT их не получает.

Успешный сквозной прогон и его границы: [RESULTS.md](RESULTS.md).

## Инструменты

Проверяемая конфигурация: Flutter 3.47.7 / Dart 3.13.5, JDK 21, Android SDK 36, эмулятор Android 35 ARM64 с Google APIs, Docker Compose, Python 3. Flutter SDK вне репозитория; системный Flutter не заменяется. Версии Dart-зависимостей закреплены `pubspec.lock`, образы — digest в Compose.

Для web нужны Rust stable и nightly с rust-src, `flutter_rust_bridge_codegen` 2.13.0, `wasm-pack`, `wasm-bindgen-cli` 0.2.100. Нативные библиотеки Android собирает пакет flutter_vodozemac; нужен Rust в PATH. На macOS используйте `LC_ALL=en_US.UTF-8 LC_CTYPE=en_US.UTF-8 LANG=en_US.UTF-8`: системный Perl/shasum из Cargokit не поддерживает `C.UTF-8`.

## Запуск локальных серверов

Из корня репозитория:

```sh
python3 prototype/setup.py
docker compose -f prototype/compose.yaml up -d
python3 prototype/seed.py
python3 prototype/token_server.py
```

Дождаться ответа `http://localhost:8008/_matrix/client/versions` перед seed. Пароли для ручной проверки находятся в `.prototype/accounts.json`; весь каталог исключён из Git. Последняя команда работает в отдельном терминале. Контейнеры доступны только через loopback. `docker compose ... down` сохраняет данные; `down -v` уничтожает их, включая историю и резервные копии ключей.

```sh
cd apps/client
flutter pub get
cd ../..
python3 prototype/build_web_assets.py
cd apps/client
flutter build web
cd ../..
python3 prototype/serve_web.py
```

Открыть `http://localhost:7357`. Сервер выставляет COOP/COEP для WASM. В обычном клиенте можно войти, создать зашифрованную комнату, отправить текст, создать/восстановить recovery key и подключиться к звонку с одинаковым идентификатором сессии. Ключ восстановления показывается пользователю; не сохранять его в Git или логах. Lavender Soft — начальная тема, Ocean Calm и Midnight переключаются и сохраняются локально.

## Android ↔ web: сквозной сценарий

Эмулятор должен быть запущен заранее. Для этого локального стенда медиа идут через ICE/TCP и adb reverse; это не проверка реальной мобильной сети.

```sh
adb reverse tcp:8008 tcp:8008
adb reverse tcp:8090 tcp:8090
adb reverse tcp:7880 tcp:7880
adb reverse tcp:7881 tcp:7881
python3 prototype/prepare_run.py
cd apps/client
flutter build web --target lib/lab_main.dart --dart-define-from-file=../../.prototype/web.json
flutter build apk --debug --target lib/lab_main.dart --dart-define-from-file=../../.prototype/android.json --target-platform android-arm64
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell pm grant dev.voicechat.voicechat_probe android.permission.RECORD_AUDIO
adb shell am start -n dev.voicechat.voicechat_probe/.MainActivity
```

Открыть две отдельные вкладки `http://localhost:7357/` и `http://localhost:7357/?role=carol` в Chrome с доступом к микрофону (для автоматического запуска: `--use-fake-device-for-media-stream --use-fake-ui-for-media-stream --autoplay-policy=no-user-gesture-required`). Затем из корня:

```sh
python3 prototype/check_reports.py
```

Сценарий проверяет двустороннюю расшифровку текста Android ↔ web и отсутствие текста в серверном событии; останавливает старые клиенты; входит новым устройством; отвергает неверный recovery key и восстанавливает оба сообщения правильным ключом. Затем три участника (Android + два web-клиента в отдельных вкладках) должны получить подтверждение расшифровки каждого удалённого аудиопотока через событие cryptor `kOk`. Одного успешного подключения к SFU недостаточно для PASS.

Каждый повтор начинается с `prepare_run.py` и пересборки **обоих** клиентов. Не распространять лабораторные сборки: в них вкомпилированы одноразовые тестовые пароли. Обычные сборки используют `lib/main.dart` без define-файлов.

## Автоматизация

`.github/workflows/prototype.yml` запускает анализатор, Flutter-тест интерфейса и Python-тесты допуска к звонку. Это не замена сквозному прогону на эмуляторе. Производственный деплой из GitHub Actions в этом прототипе не настраивается.

## Быстрые проверки

```sh
python3 -m unittest discover -s prototype -p 'test_*.py'
cd apps/client
flutter analyze
flutter test
```

## Границы прототипа

- HTTP/WS, локальный издатель JWT и диагностические `/report` предназначены исключительно для loopback. Для VPS требуются HTTPS/WSS, производственная авторизация и деплой по архитектуре.
- Локальное хранилище Matrix ещё не защищено Android Keystore/паролем пользователя; браузерное хранилище доступно коду origin. Только тестовые данные.
- Подпись устройства и Matrix Olm защищают доставку ключа, но UI проверки личности/SAS ещё нет. Злонамеренный сервер при первом знакомстве устройств не исключён. Нельзя заявлять полную защиту от подмены личности.
- Ключ отправителя уникален на подключение, привязан к комнате/сессии/устройству и передаётся только текущим участникам. Производственная смена эпохи при удалении участника, отзыв доступа и защита от гонок требуют отдельного протокола. Текущий звонок нельзя использовать для секретных разговоров.
- Пока нет отправки файлов/голосовых сообщений, push/фоновых звонков, сетевого восстановления, регистрации через почту и остальных функций MVP. Здесь проверяются совместимость криптографии, восстановление истории и E2EE медиа.
- Эмулятор с синтетическим звуком не подтверждает качество микрофона, эхоподавление, Bluetooth, работу под блокировкой, десять участников или нестабильную сеть.
