# VoiceChat

Личный мессенджер для друзей и семьи: Android APK и адаптивное веб-приложение.

Основной стек согласован: Flutter, Matrix/Synapse, PostgreSQL, WebRTC и LiveKit с E2EE. Добавлен локальный Flutter-прототип для проверки E2EE; это ещё не готовый MVP. Развёртывание планируется на одном VPS через Docker Compose и GitHub Actions.

- [Статус реализации и незавершённые работы](docs/implementation-status.md)
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
