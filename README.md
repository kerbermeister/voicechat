# VoiceChat

Личный мессенджер для друзей и семьи: Android APK и адаптивное веб-приложение.

Основной стек согласован: Flutter, Matrix/Synapse, PostgreSQL, WebRTC и LiveKit с E2EE. Добавлен локальный Flutter-прототип для проверки E2EE; это ещё не готовый MVP. Развёртывание планируется на одном VPS через Docker Compose и GitHub Actions.

- [Единый реестр пользовательской приёмки — что ещё проверить](docs/user-acceptance.md)
- [Статус реализации и незавершённые работы](docs/implementation-status.md)
- [Windows 10/11: отдельная задача и требования](docs/windows-spec.md), [технический TODO WIN-00–WIN-15](docs/tasks/16-windows.md) — запланировано, включая установщик и встроенные обновления; реализация не начата.
- [Ручное обновление Android через APK](docs/android-apk-update-spec.md) и [план реализации](docs/tasks/13-android-apk-update.md) — опубликованный Android APK1.15.0+32 (физическая приёмка открыта), [канал edge/core и результаты проверки](docs/iterations/android-update-channel-2026-10-31.md); [правила версий](docs/app-versioning.md), [история изменений](docs/app-changelog.md).
- [ТЗ демонстрации экрана](docs/screen-sharing-spec.md) и [пошаговые задачи SS-00–SS-17](docs/tasks/08-screen-sharing.md) — Android/веб, один ведущий с перехватом. Реализация экспериментальная, default off; [результаты](docs/iterations/08-screen-sharing.md), [приёмка](docs/screen-sharing-acceptance.md), [как пользоваться](docs/screen-sharing.md).
- [Итерация 4: веб-вход и Lavender Soft](docs/iterations/04-web-session-and-lavender.md) — восстановление вкладки без паролей, отдельные люди/группы и настройки.
- [Итерация 3: основной мессенджер](docs/iterations/03-core-messenger.md) — аккаунты, контакты, переписка, медиа, очередь и звонки.
- [Итерация 2: веб-vault и проверка устройств](docs/iterations/02-web-vault-and-device-verification.md) — веб-вход с локальной фразой, шифрование IndexedDB и ручная сверка отпечатков.
- [Итерация 1: защита локальных ключей и отзыв устройств](docs/iterations/01-local-keys-and-revocation.md) — Android SQLCipher/Keystore, отзыв сессий и остановка звонков при изменении доступа. Ограничение веб-входа снято в итерации 2.
- [Требования v0.3](docs/requirements.md)
- [Выбранные технологии](docs/technology-proposal.md)
- [Основной визуальный референс: Lavender Soft](docs/design/README.md) — направление стиля для дальнейшего дизайна, не буквальная спецификация экранов.
- [Детальная архитектура v1](docs/architecture/README.md) — компоненты, данные, шифрование, звонки и эксплуатация.

Открытые вопросы и проверки интеграций отмечены отдельно от принятых решений. Команды локального запуска и проверки описаны в [прототипе](prototype/README.md); производственный CI/CD остаётся отдельным этапом.

- [Решения: один VPS, развёртывание и восстановление](docs/architecture-decisions.md)

- [Правила разработки](AGENTS.md) — минимальное полное решение, читаемость и обязательная проверка безопасности.
