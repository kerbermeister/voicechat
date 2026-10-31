# Android APK 1.15.0 (31) — 31 октября 2026

Подписанный локальный APK собран из чистого main `d5dc6be3b7f1a3d8ead9a92e757a3c12d7028c9c`.
Клиентские исходники и vendor совпадают с production revision `c33894a`.
Сервер и публичный Android-канал не изменялись.

Файл: `/Users/anton/IdeaProjects/VoiceChat/.prototype/android-build31/candidate/voicechat.apk`.
Размер: 158774558 байт. SHA-256:
`2843d29166b22043b86e5809e471f609ff9c37b1b577c6d7c773b5deedfd1a1c`.
Сертификат: `37d98de9eaf7151d8df38fe326711107d4ba4ac30bb03c6870269af84ac79ce4`.
Минимум API 24 (Android 7.0); ABI: armeabi-v7a, arm64-v8a, x86_64.

Использованы Flutter 3.47.7, обычный `lib/main.dart`, production HTTPS endpoints,
подписанный каталог и прежний публичный ключ из production-конфигурации31.
HTTPS Matrix/readiness отвечают200; актуальная подпись каталога revision1 проверена.
Release Gradle требует постоянный ключ, debug fallback не используется.

`pub get --enforce-lockfile`, analyze, release build, штатный Android packager,
apksigner и ZIP integrity — PASS. Восемь тестов Android release — PASS.
Полные439PASS/4opt-in skip для неизменённых исходников31 подтверждены
[предыдущим прогоном](chat-followups-2026-10-30/validation31.json), повторно не запускались.

Первый запуск с `build apk --release --no-pub` сохранил registrant с dev-only
integration_test и остановился на Java compilation. Штатная команда без `--no-pub`
пересоздала registrant для release; исходники и toolchain не изменялись.

Подключённых Android-устройств нет. Установка, обновление с сохранением профиля,
звонки, камера и фон на физическом телефоне этим результатом не подтверждаются.
Пользовательский остаток ведётся в [едином реестре](../user-acceptance.md), UA-37
и соответствующих функциональных пунктах. Публикация в HTTPS-канал не выполнялась.

Логи, public config, manifest, подпись и build-proof.json сохранены рядом в
`/Users/anton/IdeaProjects/VoiceChat/.prototype/android-build31/`.
