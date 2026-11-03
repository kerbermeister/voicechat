# Устойчивое восстановление оценки личного звонка

03.11.2026: web/Mac/Android1.19.11(59) опубликованы.
Source `b7b351928a5d54433869904ac5eab1ad19910449`, тег `app-v1.19.11+59`. Единственная очередь —
[UA-04.C32](../../user-acceptance.md#ua-04), связь с OPT-03 исходного исследования.

Подтверждено3 [red-регрессиями](red.txt): StableCallQuality считал только точные
повторы одной оценки. После poor чередование excellent/good навсегда оставляло poor;
после excellent чередование poor/good скрывало устойчивое ухудшение. Класс питает
индикатор личного звонка и Auto cap исходящего видео; групповой SDK score другой.

Исправление подтверждает общий предел подряд идущих samples одного направления:
poor → excellent/good/excellent даёт good после3 samples; excellent → poor/good
даёт good после2. Единичный poor не выбирает low, excellent требует собственного
устойчивого подтверждения. Opposite trend, unknown и прежняя оценка прерывают окно;
ICE lost остаётся немедленным, expiry3 missing и ручной preset прежние.

[13 адресных PASS](green.txt), включая4 новых cases и прежние controls;
[изменённые Dart-файлы/fixture analyzer](targeted-analyze.txt) чистые. Форматирование
после теста не меняло семантику. [763 full Flutter PASS/4skip](full-tests.txt), [app analyzer](full-analyze.txt)
и [8 version/package PASS](package-tests.txt). Кандидат1.19.11(59); настоящий
directional browser probe и обязательный native/web выпуск PASS.

Это доказанное залипание оценщика, не установленная причина прежних кратких
просадок пользователя или физического рассинхрона. Связь/Opus/шифрование/доверие,
capture/publication, timers авторизации и server revocation не менялись.

## Освобождение browser renderer

В SDK flutter_webrtc1.6.3 dispose удаляет audio element из DOM, но оставляет
его srcObject. Нормальный close DirectCall очищал источник отдельно; позднее
завершение _render после закрытия и error cleanup вызывали только dispose.
Общий web renderer теперь сначала вызывает штатный setSrcObject(null), затем
SDK dispose. Общие tracks не останавливаются, нативный renderer не меняется.

Настоящий loopback browser red достиг новой проверки и сообщил
«Disposed renderer retained its remote audio source». Green прошёл дважды,
включая независимую перезагрузку страницы. Проверка подтверждает null у
захваченного прежнего audio element и live у общего audio track. Первый green
не дошёл до assertion из-за deadline начальных кадров при connected ICE;
повтор без изменения runtime прошёл. Это не объявляется доказанным исправлением
слышимого дублирования или физического lip-sync. Production media_audio.js не менялся:
дополнительный gain/replaced/retired-element контроль прошёл уже на58.

## Порядок ICE в тестовом стенде

До финальной проверки fresh TURN outgoing/incoming по одной первой попытке
остановились на ICE checking. Повтор outgoing без изменения продукта прошёл:
42 samples,4 encoding updates, финальный Auto/640 и оба направления excellent.
В fixture обнаружена передача ранних кандидатов без ожидания remote SDP.
По [контракту WebRTC](https://www.w3.org/TR/webrtc/#dom-rtcpeerconnection-addicecandidate)
addIceCandidate при null remoteDescription отклоняется. Добавлена локальная
очередь как в существующем A/V marker fixture и guard после cleanup; runtime
DirectCall/Matrix не менялся. Это устранение риска гонки стенда, не доказанная
причина конкретного initial timeout. Оба направления повторяются после сборки.

Финальная сборка после очереди ICE прошла с первой попытки в обоих направлениях:
[incoming42 samples](incoming.json), [outgoing42 samples](outgoing.json).
Входящие15% потери не меняли Auto/640 исходящего видео (1 encoding update),
исходящие15% потери дали low/320 и последующее Auto/640 (3 encoding updates).
Оба потока восстановились по настоящему TURN relay, final excellent/excellent;
assertions disposal/pause/resize/ICE restart также PASS. [Asset hashes](renderer-final-assets.json)
и [финальный fixture analyzer](fixture-final-analyze.txt). Первые попытки до
очереди ICE сохранены как ограничение диагностики, не как успешное прохождение.

## Выпуск

[WEB99](https://github.com/kerbermeister/voicechat/actions/runs/41602842372)
SUCCESS15m12s; [CI233](https://github.com/kerbermeister/voicechat/actions/runs/41602753478)
SUCCESS15m42s. Main и тег указывают на тот же проверенный source. Автоматические
[CI234 main](https://github.com/kerbermeister/voicechat/actions/runs/41605175531) и
[CI235 tag](https://github.com/kerbermeister/voicechat/actions/runs/41605175715) SUCCESS; runtime не пересобирался ради изменения документации.
[Независимая production-проверка](production-verified.json): core58/fingerprint
прежние, web59/digests/HTTPS/rollback/data identity PASS. Все nonweb контейнеры,
включая control/Synapse/PostgreSQL, сохранили ID/StartedAt/RestartCount. Обычный
клиент no-cache, worker/WASM доступны; unauthenticated API401, private routes404.
Администраторский screen flag сохранён, default off не менялся.

[Mac-кандидат](macos-candidate.json): ZIP/DMG285 одинаковых entries, strict codesign,
постоянный Sparkle key/feed как у58. Проверенная app/profile backup58 сохранена
вне репозитория; Keychain не менялся. [Публикация](macos-publication.json) штатным
publish_macos.py; публичные SHA/feed сверены. [Установка58→59](macos-installation.json)
через кнопку: автоматический [новый PID](macos-auto-relaunch.json) наблюдался до
getApp,285 exact entries, прежние account/device, выбранная старая QA-история,
About59/latest-check PASS. Старое аудио отдельно не проигрывалось.

[Android58→59](android-installation.json): отдельный API35 эмулятор, без wipe,
точный подписанный APK/постоянный сертификат, эмулятор завершён. Аккаунт на нём
не сравнивался; физический Xiaomi не проверен. [Публикация preview](android-publication.json)
по ранее запрошенному владельцем каналу; сервисы и managed pointer не менялись.
APK SHA256 `39af31a9c416d579ef61826acbfff5d2837b32cb246eaffd77a63a7a381c805d`.

Единственная очередь приёмки — [общий реестр](../../user-acceptance.md).
Остаются UA-08/09 (физический A/V/route/gain), UA-05.C39/OPT-07 (group epochs)
и UA-05.C41/OPT-16 (backup continuity). Этот выпуск их не закрывает.
