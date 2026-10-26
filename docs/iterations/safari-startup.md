# Быстрый первый экран web — 26 октября 2026

Пользователь сообщил о белом экране в Safari и установленном web-app на iPhone
в течение 2–4 минут. Production baseline: `5fd75f485a9ec2e685502e6de23e5fda7b4badb8`.
HTML по HTTPS получен за 0,30 с, но первая загрузка JS и CanvasKit превысила
30-секундный лимит измерения. Повторная передача main.dart.js заняла 5,68 с
(2 083 573 байта gzip). Это подтверждает зависимость запуска от загрузки больших
ресурсов, но не является трассировкой конкретного iPhone. DNS A корректен,
AAAA отсутствует; службы healthy. Предыдущий обход ожидания service worker уже
присутствует в baseline и сохранён.

Дополнительно найден дефект внешнего gateway: ответ рекламировал
`Alt-Svc: h3=":443"; ma=2592000`, но `deploy-caddy-1` публикует только TCP 443,
а UDP 443 не слушается на хосте. Для домена VoiceChat в отдельном gateway
`/opt/avito-helper/deploy/Caddyfile` добавлено `header >Alt-Svc clear`.
Это точечная правка существующего внешнего reverse proxy, который не входит
в release artifact VoiceChat. Конфигурация проверена `caddy validate`, исходник
сохранён рядом с именем `Caddyfile.voicechat-startup-<UTC>`, применён graceful
reload без пересоздания контейнеров. Публичный ответ теперь содержит ровно
`Alt-Svc: clear`. Другой virtual host не изменён. Вклад этой ошибки в задержку
конкретного iPhone без трассировки не измерен.

При пересоздании gateway сохранить в блоке домена:

```caddyfile
univc.duckdns.org {
    # UDP 443 is not published; clear cached HTTP/3 alternatives for this origin.
    header >Alt-Svc clear
    reverse_proxy voicechat-web:80
}
```

Объявлять HTTP/3 снова можно после публикации UDP 443 и проверки реального
соединения извне. Удаление заголовка внутри web-контейнера недостаточно:
заголовок добавляет внешний TLS gateway.

Изменения:

- Статический доступный экран запуска находится в HTML и не ждёт Flutter,
  внешнего шрифта или скриптов. После 15 с показывает подсказку и ручной повтор;
  ошибки скрипта/движка также показывают повтор. Автоматических перезагрузок нет.
- Экран убирается только по `flutter-first-frame`, а не по завершению `runApp`.
  Новый bootstrap совместим с прежним HTML при обновлении кеша.
- Preload главного JS и `defer` вспомогательных скриптов убирают последовательную
  загрузку перед запуском bootstrap.
- Web-образ заранее сжимает JS/WASM/шрифты и текстовые ресурсы Brotli q11 и gzip.
  Caddy отдаёт подходящий вариант; `no-cache`, ETag, COOP/COEP сохранены.
  Brotli — только инструмент сборки, удаляется из готового слоя.
  [Caddy precompressed](https://caddyserver.com/docs/caddyfile/directives/file_server),
  [Flutter initialization](https://docs.flutter.dev/platform-integration/web/initialization).

Проверки: шесть Node-тестов запуска, подключённых к обычному `flutter test` через
`test/web_startup_test.dart`. Они проверяют зависшую загрузку, ошибку ресурсов,
ошибки loader/engine/app, момент первого кадра, отсутствие ожидания worker,
порядок defer/preload и совместимость с прежним HTML.

Релиз предназначен для режима `web`: ветка создана от production, защищённые
backend-исходники не изменены. Независимые изменения macOS из main не включены.
Данные аккаунтов, ключи, настройки и service worker registrations не очищаются.

Ограничения: физический iPhone и его мобильная сеть не проверены. Статический
первый экран не равнозначен готовности чатов; полный холодный запуск Flutter
зависит от сети, CPU и кеша. Результаты выкладки и передачи файлов фиксируются
после успешного release workflow.
