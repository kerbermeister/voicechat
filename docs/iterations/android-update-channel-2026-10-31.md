# Канал Android APK в edge/core — 31 октября 2026

Издатель подключён к managed baseline: список действующих edge, их pinned SSH,
отдельные role roots и проверка фактических read-only Docker mounts. Legacy
runtime не используется для routed APK. Перед записью сверяются install identity,
public config, подпись актуального каталога, роль/ревизия и отсутствие maintenance.
Все edge проверяются до первой публикации; каждый manifest меняется атомарно
под прежней блокировкой, immutable APK и предыдущий указатель сохраняются.
Повтор частично завершённой доставки безопасен; общей транзакции между VPS нет.

`Android release` получил `check_channel=true,publish=false`: отдельный Python-job
не собирает Android, не использует signing secrets и не меняет теги или latest.
Проверенный локальный clean-кандидат также можно доставить без повторной сборки.
Gate точного `ANDROID_ACCEPTED_BUILD` и `ANDROID_ACCEPTED_SHA256` сохранён до SSH
и повторно проверяется на edge. Сборка31 и её байты не менялись.

## Проверки

- Реальный production `--check`: edge-a,
  `/srv/voicechat-managed/edges/a/runtime/android-updates`, actual read-only mount PASS.
  Docker хранит путь через immutable release `infra/runtime` symlink; он проверен
  по разрешённому конечному пути, без ослабления запрета на чужие каталоги.
- Публичный каталог revision1 проверен прежним Ed25519-ключом клиента.
- Настоящий локальный cohost edge с HAProxy/Caddy/TLS: публикация APK fixture,
  mime/cache, повтор, отзыв первого выпуска и возврат предыдущего, 404 для private
  metadata — PASS. Container IDs/StartedAt до и после публикации совпали.
  Fixture не является установочным APK и не доказывает работу телефона.
- Python-регрессия издателя, конфигурации клиента, edge/roles, managed SSH и
  нативного Mac update routing: **52 PASS**.
- YAML и пять shell-шагов Android workflow разобраны и проверены `bash -n`.

Production сервисы не пересобирались и не перезапускались. APK/latest в production
не публиковались; 404 пустого канала остаётся ожидаемым состоянием до физической
приёмки. Внешние дополнительные VPS не подключены, их доставка проверена в unit
контрактах, а не объявлена доказанной работой реальных B/C.

## GitHub

Во встроенном браузере подтверждены production SSH/root/origin и repository
CLIENT_ROUTE_CONFIG/CLIENT_ROUTE_CATALOG_KEY. Android signing secrets отсутствуют
как на уровне environment, так и repository. Локальная подпись постоянным ключом
работает; его перенос в GitHub требует отдельного разрешения на передачу ключа и
паролей CI. Значения acceptance не выставляются без телефона.

Команды, повтор при частичном успехе и отзыв:
[infra/README.md](../../infra/README.md#ручные-android-обновления).
Пользовательский остаток: [UA-37](../user-acceptance.md), отдельного списка нет.

Изменены protected infra/workflow источники. Следующий production source release
должен пройти штатный full guard; backend fingerprint/current.json вручную не менялись.
Текущая доставка APK и её --check не являются backend deploy.

## Подтверждение GitHub Actions

Изменение опубликовано в main `e77c0c61c3ebbd4d81553f220001c4a3b0d15fe2`.
[Android release #1](https://github.com/kerbermeister/voicechat/actions/runs/41203809086):
**SUCCESS**, job channel31s, Android job SKIPPED. Выбраны `check_channel=true`,
`publish=false`, main. Проверка прошла через существующий production SSH без APK,
release-keystore и Android signing secrets. Во встроенном браузере проверены
зелёный итог и список шагов. Отдельный автоматический Prototype checks164 запущен
push-событием; его итог этим отчётом пока не подтверждён.

Готовы оба пути: локальный принятый APK → штатный издатель и CI preflight без
подписи. Для автоматической сборки/подписи CI ещё требуется разрешённый перенос
постоянного keystore/паролей в GitHub production secrets. Запрос владельцу отправлен;
до ответа ключи не передаются и acceptance-переменные не выставляются.

## Подпись GitHub Actions

Владелец отдельно разрешил перенос существующего Android keystore и паролей в
production secrets. Сохранены `ANDROID_KEYSTORE_BASE64`, `ANDROID_STORE_PASSWORD`,
`ANDROID_KEY_PASSWORD`, `ANDROID_KEY_ALIAS`; существующие SSH secrets не менялись.
`ANDROID_SIGNING_SHA256` задан прежним отпечатком сертификата. Значения secrets
не выводились в журнал, Git или отчёт; новый ключ не создавался.
Acceptance build/hash не задавались. Проверочный CI-кандидат получает32 по правилам
неповторяемых BUILD, версия1.15.0, функциональный код31 без изменений.
