# Групповое приглашение при расхождении часов — 24 октября 2026

При проверке screen share на опубликованном `39abf2d` личный звонок прошёл
показ/перехват/stop с видимыми пикселями и сохранением voice/camera. В группе
приглашение не появилось у получателя. Серверное время измерено по SSH:
VPS опережал Mac на 28.796 s, погрешность оценки ±0.679 s.

`CallController.receive` отбрасывал любой отрицательный age, хотя timestamp
назначает homeserver. Добавлен ограниченный допуск будущего timestamp до 1 минуты;
события старше 10 минут и более чем на минуту впереди по-прежнему отвергаются.
Проверки encrypted room, redaction, формата session, sender и отмены не менялись.
Формат сигналинга, backend и schema не меняются. Это исправление общего Flutter
кода; текущая выкладка проверяет web, физический Android остаётся отложенным.

Новые assertions в существующем тесте воспроизвели отказ до исправления:
будущий invite +30 s не появился. После исправления все 13 tests файла
`chat_actions_test.dart` PASS, Flutter analyze без замечаний. Проверены обычный
invite/end, malformed session, 11-минутное событие, +2 min, чужой end, +30 s invite/end.
Полный набор и web release прошли штатный [Build and deploy №9](https://github.com/kerbermeister/voicechat/actions/runs/40127768357)
в режиме web, SUCCESS. Публичный group screen smoke после выкладки PASS;
[свидетельство](screen-vps-evidence/verification.json).

Операционное включение screen preview и последующая VPS приёмка фиксируются
отдельно; этот адресный тест не является доказательством Android/media-нагрузки.
