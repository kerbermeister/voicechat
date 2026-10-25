# Halo — публикация 25 октября 2026

Исходники Halo объединены с актуальным GitHub `main`. Сохранены автоматические профили, SAS-подключение устройств, передача ключей и исправление допустимого расхождения часов при вызовах из предыдущего production-релиза.

Опубликованный commit: `7b63b0e97650fd228eb59d08c6349cfedb453d14`.
[Build and deploy #11](https://github.com/kerbermeister/voicechat/actions/runs/40168449201) завершён успешно за 6 мин 23 с, режим `web`, `deploy=true`.
Сайт: https://univc.duckdns.org/.

## Проверки и доставка

- После объединения локально прошли 189 Flutter-тестов, 3 опциональных теста снимков пропущены; анализатор без замечаний.
- Первая попытка CI остановилась до деплоя: 188 тестов прошли, один тест размещения форм ссылался на локальный путь Flutter SDK. Загрузка шрифтов во всех четырёх затронутых тестах переведена на активный SDK через `Platform.resolvedExecutable`; проблемный тест и анализатор повторно прошли локально.
- Повторный workflow прошёл серверные и клиентские проверки, восстановил проверенные криптографические ассеты из кеша, собрал обычный production web с HTTPS/WSS endpoints и опубликовал immutable web image.
- Защищённые исходники совпали с baseline VPS: `07c363febb1fe77296b4d06f7c71010dddd2e32abd1a5c02c04d425019389218`. Control image и runtime-конфигурация сохранены; ручной hotfix и обход release guard не использовались.

## Приёмка VPS

`current.json` и фактический web image соответствуют commit `7b63b0e`. `previous.json` указывает на `30e96d299b786006f3408b2f5615b6a5dd8527e1`, предыдущий каталог релиза сохранён.

Идентификаторы контейнеров, StartedAt, RestartCount и образы PostgreSQL, Synapse, control и TURN совпали со снимком до обновления. Заменён только web. Все службы running/healthy. SQLite screen schema осталась v2; существующий screen flag `1` сохранён без переключения.

Публичный `main.dart.js` совпал по SHA-256 с файлом в web-контейнере: `729e0fdbdab2799d55fe443bfdf8033ab3fdeb6d36e60d06499a30ff0420289c`. Сохранены `Cache-Control: no-cache`, COOP и COEP. Сайт, health, Matrix versions, worker и WASM отвечают 200; внешние admin/internal endpoints — 404.

Во встроенном браузере Codex проверены загрузка интерфейса и переходы «Вход → Создать аккаунт → Вход → Забыли пароль → Вход» на 1280×720, без ошибок консоли. Формы не отправлялись, палитра и данные браузера не сбрасывались.

[Машиночитаемый результат](halo-release-evidence/verification.json), [успешный workflow](halo-release-evidence/workflow-success.png), [вход](halo-release-evidence/production-login.png), [регистрация](halo-release-evidence/production-registration.png), [восстановление](halo-release-evidence/production-reset.png).

## Границы

Физический Android, реальная отправка почты, вход в production-аккаунт, расшифровка истории и активные медиазвонки в этом прогоне не проверялись. Не выполнялся намеренный production-откат; его предыдущий релиз и immutable образы сохранены. Эта публикация не меняла пользовательские базы или серверную схему.
