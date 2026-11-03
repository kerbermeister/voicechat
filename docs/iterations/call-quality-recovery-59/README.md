# Устойчивое восстановление оценки личного звонка

03.11.2026, production1.19.10(58). Локальное исправление, ещё не выпущено;
кандидат1.19.11(59). Единственная очередь —
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
directional browser probe PASS; обязательный native/web выпуск ещё выполняется.

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
