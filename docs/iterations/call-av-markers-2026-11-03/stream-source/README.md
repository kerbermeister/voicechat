# H01: исходный A/V MediaStream против отдельной audio-stream оболочки

03.11.2026, только локальный контрфактический контроль. Production media_audio.js
не изменён, SHA ae152bc3e5dc8c69e089b8d0d175562a0a8fca84a17133c391786d6c247c640d.
Тот же audio track object, canvas/DTMF, gain100/50/200/100, одна source/gain graph,
local TURN, все netem profiles delay0 и фактические qdisc drops0. Нет E2EE,
микрофона, камеры, аккаунта или записи медиа; sink выдаёт нули. Lightweight UI
проверки удалённых CI выполнялись параллельно; локальных build/analyzer/AVD не было.

Перехват constructor только тестовый: product аргумент — новый поток с одной
аудиодорожкой; combined аргумент — исходный DOM srcObject с той же аудиодорожкой
и видео. Все остальные bytes одинаковы ([inputs](inputs.json), [fixture](source-control-fixture.js.txt)).
[Подтверждение product](product120-source.json)/[combined](combined120-source.json):
ровно1 source call, same_audio_track=true, source_had_video=false/true.

| Вариант120с | Markers/RTP | Initial/recovery p95 abs | Итог |
| --- | --- | --- | --- |
| [Product](product120.json) |60/60|88.4/86.5мс|budget_exceeded|
| [Combined control](combined120.json) |60/60|80.6/73мс|budget_exceeded|

Разница одной пары7.8/13.5мс меньше выбранного допуска калибровки±50мс и не
доказывает улучшение. Ни один прогон не прошёл строгий guard abs≤80 у каждого
baseline/recovery marker. Нельзя выбирать только меньший p95 или объявлять это
исправлением iPhone. В приложение изменение не переносится; H01 и UA-08/09 открыты.

[Web Audio constructor](https://webaudio.github.io/web-audio-api/#mediastreamaudiosourcenode)
выбирает audio track, а не задаёт общий A/V scheduler. В [Chromium source](https://chromium.googlesource.com/chromium/src/+/main/third_party/blink/renderer/modules/webaudio/media_stream_audio_source_node.cc)
provider создаётся из выбранной дорожки с параметрами AudioContext; MediaStream
сохраняется отдельно. Вывод из источников: простая смена оболочки не даёт
стандартной гарантии lip-sync. Это не доказательство поведения точной сборки IAB
или Safari. Новая задержка/буфер/пресет качества не вводились.

Оба собственных TURN projects1af5ebc074/e5266cadfe удалены штатными lifetime
таймерами, process exit0. Вкладки закрыты. Единая пользовательская приёмка —
[UA-08/09](../../../user-acceptance.md), без отдельного checklist здесь.
