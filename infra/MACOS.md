# Выпуск VoiceChat для macOS

Состояние29.10.2026: подписанный личный выпуск1.12.0(24) опубликован; на macOS15.3.1
проверен штатный Sparkle23→24 с прежними account/device/history и точным совпадением
285 файлов/ссылок с ZIP. [Свидетельство](../docs/iterations/three-vps-evidence/2026-10-29-macos24-published.json).
Ниже — порядок следующих выпусков; автоматической публикации нет.
`macos.yml` запускается вручную на выбранной ветке, не сливает её в main и не
обновляет VPS. Использует macos-15 arm64, закреплённые Flutter/Pods/Sparkle.

## Локальная и CI-проверка

- `flutter analyze`, `flutter test --concurrency=1` из `apps/client`.
- `flutter test integration_test/macos_storage_test.dart -d macos` проверяет
  настоящий Keychain/SQLCipher на уникальном одноразовом профиле, без сервера.
- `xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Debug
  -destination 'platform=macOS,arch=arm64' test` из `apps/client/macos`.
- `python3 -m unittest discover -s prototype -p 'test_macos_*.py'` из корня.
- `VOICECHAT_DOCKER_TESTS=1 python3 -m unittest discover -s prototype
  -p 'test_android_caddy.py'` проверяет оба канала локальным Caddy без сети.

Не путать unit/widget-тесты с фактической записью медиа, старой macOS и
подписанным обновлением. В CI нет приёмки камер/гарнитур владельца.

## Подписанный кандидат

Нужны Developer ID Application, неизменный Team ID, профиль `notarytool` в
Keychain и отдельная пара Ed25519 Sparkle. Приватные ключи хранятся вне репозитория
и артефактов. Проверенный SDK Sparkle 2.10.0 содержит `generate_keys`, `sign_update`.
Не генерировать новый ключ при каждом релизе: установленный клиент доверяет
публичному ключу, встроенному при первой установке.

Перед сборкой поднять общую версию/номер сборки штатным способом проекта.
Номер должен превосходить опубликованный macOS build. Xcode release build settings:

| Setting | Значение |
| --- | --- |
| PRODUCT_BUNDLE_IDENTIFIER | dev.voicechat.client |
| ARCHS | arm64 |
| MACOSX_DEPLOYMENT_TARGET | 12.0 |
| DEVELOPMENT_TEAM | постоянный Team ID издателя |
| CODE_SIGN_IDENTITY | Developer ID Application: … |
| ENABLE_HARDENED_RUNTIME | YES |
| VOICECHAT_UPDATE_FEED | https://<origin>/updates/macos/appcast.xml |
| VOICECHAT_UPDATE_PUBLIC_KEY | публичный ключ Sparkle в base64 |

Использовать Xcode configuration override вне репозитория через
`XCODE_XCCONFIG_FILE` при `flutter build macos --release` с обычным
`--dart-define-from-file` (см. README клиента). В override не хранить приватные
ключи. Не подписывать с изменением bundle ID или Team ID. Подпись вложенных
framework/XPC выполняет сборочная система; `codesign --deep` для переподписи не
используется. Упаковщик проверяет подпись, arm64 каждой Mach-O и deployment target.

Из чистого checkout, с уже подписанной `.app`:

```sh
python3 infra/macos_release.py \
  --app apps/client/build/macos/Build/Products/Release/VoiceChat.app \
  --output /tmp/voicechat-macos-release \
  --release --team "$MACOS_TEAM_ID" \
  --notary-profile "$MACOS_NOTARY_PROFILE" \
  --sparkle-bin "$SPARKLE_BIN" --sparkle-key "$SPARKLE_PRIVATE_KEY_FILE" \
  --notes /tmp/macos-release-notes.txt \
  --previous-feed /tmp/current-macos-appcast.xml
```

Только для **самого первого** выпуска опустить `--previous-feed`. Далее передавать
точный актуальный feed сервера. Скрипт проверит его подпись, сохранит старые
совместимые выпуски и запретит повтор/понижение build. Архив проверяется по
публичному ключу из Info.plist, feed подписывается отдельно. Нотаризация/stapling
выполняются на копии `.app`, затем на DMG. ZIP содержит уже stapled `.app`.
`release.json` фиксирует commit, dirty-флаг, контрольные суммы и hash исходного
feed. Каталог с ошибкой упаковки не публиковать; повторять в новом каталоге.

## Канал на сервере

Первая установка маршрута Caddy и mount `runtime/macos-updates` меняет Compose и
`deploy.py`: нужен штатный **full**-релиз после согласования production revision,
с backup/healthcheck/rollback. Режим web для этой настройки недопустим.
В рамках разработки macOS этот релиз не запускается.

После production core/edge миграции канал текущего cohost находится в
`/srv/voicechat-managed/edges/a/runtime/macos-updates`. `DEPLOY_ROOT` указывает на
координатор `/srv/voicechat-managed`; его `/runtime` не является каналом обновлений.
Публиковать в проверенный runtime канонической edge-роли; не менять старый legacy
канал, который после cutover больше не обслуживает URL.

После настройки канала новая версия публикуется отдельно, без пересборки VPS.
Перед публикацией выполнить физическую приёмку точного ZIP и DMG, включая
подписанный N → N+1 с существующей зашифрованной историей и активным аккаунтом.
Скопировать весь каталог кандидата и `infra/publish_macos.py` по существующему
проверенному SSH-соединению в уникальный staging-каталог на сервере. Затем:

```sh
MACOS_ACCEPTED_BUILD=<проверенный-build> \
MACOS_ACCEPTED_SHA256=<проверенный-sha256-VoiceChat.zip> \
python3 publish_macos.py --candidate /path/to/staging \
  --root /path/to/deploy/runtime/macos-updates --origin https://<origin>
```

Скрипту нужен Python 3.11+. Доверенная граница — подписанный и принятый кандидат,
переданный авторизованным издателем по SSH; сервер не обладает приватным ключом.
Сначала проверяются все хеши и исходный feed, затем под блокировкой публикуются
неизменяемые `<build>/VoiceChat.zip`, `<build>/VoiceChat.dmg` и атомарно `appcast.xml`.
Смена feed после подготовки кандидата останавливает публикацию. Повтор того же
кандидата безопасен. После публикации сверить публичный feed и SHA256 обоих
архивов через HTTPS. Caddy отдаёт feed с `no-cache`, архивы immutable, остальные
файлы канала — 404. Android-канал сохраняется.

Отзыв дефектного выпуска: сохранить текущий подписанный feed, удалить из его
копии только дефектный item, подписать копию тем же `sign_update`, проверить
подпись и заменить feed атомарно под той же `.publish.lock` с проверкой исходного
hash. Архивы старых выпусков не перезаписывать. Уже обновлённым клиентам выпускать
исправление с большим build; downgrade профиля не делать.

## Личный Mac без Apple Developer Program

`macos_release.py --personal` требует чистую release/AOT сборку с ad-hoc подписью,
настроенным HTTPS feed и ключом Sparkle. Передавать `--sparkle-bin`, `--sparkle-key`,
`--notes` и после первого выпуска `--previous-feed`, как для обычного релиза.
Этот режим пропускает только Developer ID/нотарификацию; проверки подписей
архива/feed, совместимости, неизменности артефактов и приёмки сохраняются.
`--release` по-прежнему требует Developer ID и нотарификацию.

Ключ создаётся один раз `generate_keys --account voicechat-personal` в login Keychain.
Публичный ключ и feed задаются через XCODE_XCCONFIG_FILE; секреты не попадают в Git.
Первую сборку с каналом установить вручную. При смене ad-hoc подписи Keychain
может запросить доступ повторно; не удалять профиль или ключи для устранения ошибки.
Проверить N → N+1 на Mac владельца, открыв старые зашифрованные сообщения.
Без нотарификации выпуск предназначен для личного использования и не имеет
подтверждённой Apple личности издателя. Системные защиты не отключать.
