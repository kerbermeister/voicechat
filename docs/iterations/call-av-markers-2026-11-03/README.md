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

## RTP-корреляция после выпуска59

Только стенд и сводка; production runtime не менялся. Exact media_audio.js
совпал с HTTPS59 (тот же SHA, что у58). Schema2 добавляет ограниченные counters:
до150 снимков, только при duration≤300с, одна пара getStats одновременно.
Строгая граница500000байт, без RTP IDs/IP/SDP/ключей/медиа. Старые schema1
сохраняются; ранние schema2 без optional playout_path/stamp distance также читаются.

| Прогон | Markers/RTP | Initial/recovery p95 abs, мс | Итог |
| --- | --- | --- | --- |
| [Первый60с](rtp60.json), [сводка](rtp60-summary.json) |26/26|102/65|budget_exceeded|
| [Повтор60с](rtp-final60.json), [сводка](rtp-final60-summary.json) |27/27|83.4/159.4|budget_exceeded|
| [120с](rtp120.json), [сводка](rtp120-summary.json) |57/57|135.2/86|budget_exceeded|
| [Element source CONTROL60с](element60.json) |0/0|null/null|insufficient_markers; сравнение недоступно|

Ошибок getStats0, max3.1/2.2/2.3мс. Источник камеры/микрофон/Matrix аккаунт не
использовались. Снимок происходит после распознавания4 символов: на447–490мс
позже первого аудиосимвола, не в точный момент offset. В120с максимальная source-time
дистанция ближайшего video stamp10.7мс (бюджет matching80), так что только грубой
квантизацией видеометки весь135мс выброс не объясняется. Иные погрешности browser
output/display estimate остаются; это не физический замер.

В первом чистом участке120с marker3/135.2мс совпал с интервальным ростом audio
jitter buffer39.2→84.2мс, target23.6→81.4мс, concealed2040 и deceleration480 samples.
RTT2мс, cumulative packetsLost0, video drops0, encode/decode1.3/0.6мс, sender
limitation=none. Это наблюдаемая корреляция с адаптацией буфера; малая RTT и
нулевые потери не исключают краткий arrival/scheduling jitter. Источник адаптации
и причина исторического звонка не доказаны. Ручной fixed delay/новый jitter target
и другая адаптация в приложении не вводились.

CONTROL через MediaElementAudioSource не дал распознанных markers при работающем
видео. Его нельзя считать измеренной синхронизацией или доказанным улучшением;
приложение на этот путь не переключалось. Product gain на той же финальной
ветке стенда снова декодировал27 и57 markers. Это отдельный диагностический
ограничитель для H01, не исправление iPhone.

[14 live boundary PASS](rtp14-live-boundary.txt), в том числе неверная distance81
отклонена без записи результата; [unit14/1skip](rtp-final-boundary.txt),
[4 сводки/reset/missing/negative-control PASS](rtp-summary-tests.txt),
[Node3 PASS](rtp-final-node.txt). В сводках legacy8-элементная RTP строка имеет
stamp distance=null. Обновлённая сводка также считает interval codec time;
старые60с JSON-summary сохранены как исходное свидетельство. Команда запуска
и формат — в tool README. Все собственные namespace и вкладки закрыты.
