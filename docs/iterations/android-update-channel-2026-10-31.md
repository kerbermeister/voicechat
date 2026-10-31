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
CLIENT_ROUTE_CONFIG/CLIENT_ROUTE_CATALOG_KEY. На первоначальном осмотре Android signing secrets отсутствовали
на обоих уровнях. Затем владелец разрешил перенос существующего ключа: production
secrets настроены, успешная CI-подпись подтверждена ниже. Значения acceptance не выставляются без телефона.

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
зелёный итог и список шагов. Отдельный автоматический [Prototype checks164](https://github.com/kerbermeister/voicechat/actions/runs/41203758710)
также завершился SUCCESS за15m46s.

Готовы оба пути: локальный принятый APK → штатный издатель и CI preflight без
подписи. После отдельного разрешения владельца постоянный keystore/пароли добавлены в
GitHub production secrets; проверочная CI-сборка завершена успешно. Acceptance
переменные остаются невыставленными до физической приёмки.

## Подпись GitHub Actions

Владелец отдельно разрешил перенос существующего Android keystore и паролей в
production secrets. Сохранены `ANDROID_KEYSTORE_BASE64`, `ANDROID_STORE_PASSWORD`,
`ANDROID_KEY_PASSWORD`, `ANDROID_KEY_ALIAS`; существующие SSH secrets не менялись.
`ANDROID_SIGNING_SHA256` задан прежним отпечатком сертификата. Значения secrets
не выводились в журнал, Git или отчёт; новый ключ не создавался.
Acceptance build/hash не задавались. Проверочный CI-кандидат получает32 по правилам
неповторяемых BUILD, версия1.15.0, функциональный код31 без изменений.

## Успешный подписанный CI-кандидат32

[Android release #3](https://github.com/kerbermeister/voicechat/actions/runs/41206010642)
**SUCCESS**: android job14m38s, весь run14m43s. Публикация выключена;
[машиночитаемое подтверждение](android-signing-ci32-proof.json).
Ревизия `c38b27a540b39c9288eafa548e1cfa2364888767`, чистый checkout,
версия1.15.0(32), minSdk24, armeabi-v7a/arm64-v8a/x86_64.
Прежний сертификат37d98de9…; приватный ключ не пересоздавался.

Точный размер нового CI APK: **158772182 байт**.
SHA-256: `9dbf914e5661009745bb94f23be4c15d1ed8c54983c12e3011a95e78ea5729de`.
Локальная копия:
`/Users/anton/IdeaProjects/VoiceChat/.prototype/android-ci32/candidate/voicechat.apk`.
ZIP скачан по выданному GitHub artifact URL; сверены digest ZIP с GitHub,
APK/hash/metadata, sourceDirty=false, production public config, затем локально
повторены apksigner и ZIP integrity. В артефакте ровно5 публичных файлов кандидата;
keystore, паролей и SSH credentials нет. Физическая приёмка не заявляется.

Первый build run#2 прошёл тесты и остановился до создания APK: sdkmanager не был
в PATH runner. В обоих местах release/reuse workflow теперь вызывается
`$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager`; для Cargo переиспользован
принятый в Prototype checks лимит2. Затем run#3 прошёл полный штатный путь.
Номер32 не переиспользован для другого APK, run#2 APK не создавал.

Точный source сохранён в `codex/android-candidate-32`. После физической приёмки
этого APK для публикации выбрать эту ветку и `source_run=41206010642`, `publish=true`.
Сначала выставить реальные acceptance build/hash; сейчас они не задавались.
CI-артефакт хранится30 дней; локальная копия сохранена для доставки штатным
издателем без пересборки и после истечения хранения GitHub. Latest.json по HTTPS
после сборки остаётся404, серверные службы и указатели релизов не менялись.

Diff клиента/vendor относительно production31 содержит только номер сборки в
app_version.dart и pubspec.yaml; функциональные исходники совпадают.

## Общая публикация32 по прямому запросу владельца

После сообщения об установленном APK31 владелец явно выбрал общий канал вместо
ограничения тестового подключения по IP. Это разрешение на публичную раздачу
до физической приёмки, а не подтверждение работы телефона. Автоматические
acceptance build/hash не выставлялись; запись о physical acceptance остаётся false.

Опубликованы точные байты CI-кандидата32 без пересборки и без изменения manifest:
`https://univc.duckdns.org/updates/android/latest.json` →32,
`https://univc.duckdns.org/updates/android/32/voicechat.apk`.
Проверены публичные manifest200/no-cache и APK200/размер/MIME/immutable;
издатель проверил полный SHA256 через HTTPS до атомарного latest. Private metadata
остаётся404, Matrix/control route healthy. Службы и managed release pointer
побайтно/по ID/StartedAt/RestartCount не менялись; server deploy не выполнялся.

[Подтверждение публикации](android-publication32-proof.json).
Тег `app-v1.15.0+32` указывает на исходную ревизию c38b27a.
Публикация выполнена стандартным низкоуровневым atomic publisher по разовому
разрешению владельца; штатный workflow gate физической приёмки не ослаблен.
Это первый APK в канале, предыдущего manifest нет: штатный withdraw отключит
latest, сохранив неизменяемый APK. Отзыв канала не понижает версию на телефоне.

Физический переход31→32, сохранность реального профиля и аппаратные сценарии
пока открыты в UA-37. IP-scoped режим и изменения Caddy не вводились.
