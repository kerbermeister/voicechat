# Содержимое A/V после Web Audio: локальные измерения

03.11.2026, текущий production58. Только тестовый стенд; user acceptance остаётся
UA-08/09 в [едином реестре](../../user-acceptance.md). Команды и формат результата —
[call-network-lab.md](../../../apps/client/tool/call-network-lab.md#a-v-маркеры-после-product-web-audio-gain).

Два настоящих RTCPeerConnection через свой local TURN; источник — canvas и DTMF
IDs с checksum, видеочасы защищены header/CRC8. PCM наблюдаются после точного
product gain, только конечный sink выдаёт нули. Видео остаётся на комбинированном
stream; raw element muted. Микрофон, камера и аккаунт не используются; вместо
медиа сохраняются числовые временные метки. [Product script](product-source.json)
сверён с опубликованным58 по HTTPS.

| Прогон | Маркеры | Initial p95 abs / median | Recovery p95 abs | Итог |
| --- | --- | --- | --- | --- |
| [Обычный60с](short.json) | 27 | 89.4 / +73.3мс | 78мс | Предварительный80мс budget превышен |
| [Audio source +200мс](audio200.json) | 27 | 316.5 / +251.4мс | 284.3мс | Ожидаемый отрицательный контроль |
| [Video content +200мс](video200.json) | 27 | 139.8 / −127.3мс | 169.1мс | Ожидаемый отрицательный контроль |

[Калибровка](calibration.json): initial median сдвинулась на+178.1/−200.6мс;
оба знака/масштаба укладываются в выбранный допуск±50мс. Worklet decoder прошёл
42 tone/rate/gain combinations, ошибочный checksum/одиночный тон/шум отвергаются;
каждая одиночная ошибка video stamp отвергается. Всего Node3 tests PASS;
Python9 tests (1skip без сервера), live9 PASS. До прогона live boundary проверяет
Host/Origin/nonce, traversal, размеры и отсутствие записи произвольных полей.

Первый video-control остался на setup, без достоверного результата. Добавлены
stage/deadline и гарантированный cleanup; повтор измерен. Это ошибка/ограничение
стенда, не установленный дефект продукта. Frame callbacks повторного контроля:
max lateness0мс, AudioContext base/output latency5.3/32мс; это не внешняя акустика.

[30-минутный soak](soak.json) завершён:893 markers,2 unmatched,0 invalid video stamps.
Initial p95 abs71.5мс, recovery89.2мс; максимальный abs220.1мс,69 recovered samples
превысили80мс. Итог budget_exceeded, критерий не ослаблялся. [Пятиминутные окна](soak-summary.json):
median55.0→42.2→40.2→36.8→59.1→23.9мс, нарастающего дрейфа не наблюдалось;
это не исключает короткие рассогласования. AudioContext base/output5.3/24мс,
max callback lateness8.4мс. Низкоприоритетные Flutter tests/static analysis
отмечены в [host activity](host-activity.jsonl); совпадающий timing spike нельзя
приписывать только сети. Тяжёлые build/emulator/media пробы не запускались.
Тестовая вкладка закрыта, свой TURN namespace остановлен; idle-sleep guard
ограничен жизнью lab process и не меняет постоянные настройки системы.

Это browser-estimated presentation по getOutputTimestamp/expectedDisplayTime.
Порог80мс не подогнан под результат, но выход за него не доказывает слышимый
рассинхрон конкретного разговора с учётом разрешения/погрешности метода.
Это не физический iPhone/Safari/PWA/Xiaomi, не Matrix/LiveKit group E2EE, не
слышимая речь, не packet-loss seed/burst/reorder/rate matrix и не аппаратный SLA.
