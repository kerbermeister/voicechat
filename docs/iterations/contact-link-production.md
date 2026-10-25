# Одноразовые приглашения — публикация 25 октября 2026

В `main` влит `c60a347542b6f1b72680b096da7121397d552137`: одноразовая ссылка
добавления в контакты, E2EE-приветствие «Привет» и кнопка «Поделиться».
Опубликован на [univc.duckdns.org](https://univc.duckdns.org/) через
[Build and deploy #12](https://github.com/kerbermeister/voicechat/actions/runs/40169758109).
Режим `full`, `deploy=true`; результат Success, длительность 7 мин 11 с.

CI выполнил серверные/Flutter-тесты и анализ, восстановил проверенные crypto assets,
собрал обычный production web и оба immutable образа. Перед обновлением создан
согласованный Restic snapshot `e0db4d90`, проверка repository прошла.

`current.json` и образы запущенных control/web соответствуют `c60a347`.
`previous.json` указывает на `7b63b0e97650fd228eb59d08c6349cfedb453d14`;
предыдущий release-каталог сохранён. PostgreSQL, Synapse, control и web healthy,
TURN running. Существующий screen flag `1` сохранён без переключения.

База контактов имеет `integrity_check=ok`, все 20 прежних записей сохранены.
Таблица `contact_links` создана штатно при первом авторизованном API-запросе.
На двух временных аккаунтах через публичный HTTPS проверены создание ссылки,
предпросмотр без принятия, отказ при попытке принять свою ссылку, закрепление
за получателем и повтор без нового закрепления. Закрытая общая политика входящих
сохранена. Аккаунты деактивированы, их записи приглашений/политик удалены;
приветствия в production в этой проверке не публиковались.

Публичный `main.dart.js` совпал по SHA-256 с файлом в контейнере:
`9c96a8d672c8cbd4d0f9c33f28747f1d49f2548046d07a65aeb2db44cc3d3276`.
Сайт, health, Matrix versions, worker и WASM отвечают 200. Новый endpoint без
авторизации отвечает 401; admin/internal routes закрыты ответом 404.
`Cache-Control: no-cache`, COOP и COEP сохранены. Во встроенном браузере Codex
обновлённый экран входа загрузился без ошибок консоли; формы не отправлялись.

[Машиночитаемый результат](contact-link-release-evidence/verification.json),
[успешный workflow](contact-link-release-evidence/workflow-success.jpg),
[веб-клиент](contact-link-release-evidence/production-login.jpg).

Реальная расшифровка приветствия, потеря ответов создания комнаты/публикации и
повтор без дубликатов проверены на локальном Synapse перед выпуском:
[результат](../../prototype/verified-contact-links-run.json).
Физический Android и отправка в настоящий внешний мессенджер ещё не проверены.
Намеренный откат production не выполнялся; его pointer и предыдущие образы сохранены.
