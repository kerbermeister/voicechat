# OPT-08: нативная синхронизация после выпуска62

04.11.2026. LiveKit-исправление опубликовано штатным full-выпуском №104:
[workflow](https://github.com/kerbermeister/voicechat/actions/runs/41824931971),
ревизия da0dd92. Независимо подтверждены runtime source/digests, здоровье
служб, прежний rollback pointer и сохранность данных. Feed, Android manifest
и полные HTTPS-ответы ZIP/DMG/APK62 сверены по SHA-256; большие ответы
хешировались с VPS, внешняя доступность отдельно проверена с Mac. После одной неудачной пары речи macOS
выполнена заранее заданная сбалансированная серия из3 пар с включением всех
результатов. Прежние допуски STOI0,005 и уровня0,15дБ сохранены; итог прошёл. Единственная пользовательская приёмка —
[UA-08.C06](../user-acceptance.md). Физический Xiaomi недоступен; Android
ниже — выделенный API35/arm64-эмулятор. Синтетические метки не измеряют
физическую задержку динамика и дисплея и не закрывают приёмку устройств.

## Решение и границы изменения

У flutter_webrtc1.6.3 / WebRTC-SDK150.7871.04 нет публичного Java/ObjC аналога
браузерного jitterBufferTarget. Кандидат использует поддерживаемое нативным
WebRTC RTP-расширение playout-delay: сервер создаёт комнаты с одинаковыми
min_playout_delay=130 и max_playout_delay=130, без включения sync_streams.
Это минимальное изменение в CallStore._ensure_room для звонков LiveKit. Личные P2P-вызовы идут через DirectCall и
не получают RTP-параметры SFU; их нативный перенос остаётся незакрытым. Оно действует на новые комнаты; существующий звонок не перезапускается.

[Room service API](https://docs.livekit.io/reference/other/roomservice-api/).
В [закреплённом SFU v1.13.10](https://github.com/livekit/livekit/blob/e5655ac20267fa5005dccaf3f0e3bfc3ea688c07/pkg/sfu/downtrack.go#L427)
этот контроллер создаётся только для video. Аудиобуфер, кодеки, настройки
обработки речи, ключи и frame cryptor не меняются. Одинаковые границы
ограничивают накопление видеозадержки после паузы: вариант130..10000мс
позволял SFU/получателю сохранять лишнюю задержку и не прошёл80мс.

Diff относительно опубликованного нативного62 (596a80f) не содержит изменений
продуктового Flutter/Swift/Kotlin/SDK-кода. Штатный full-релиз сервера и web для этапа LiveKit выполнен. Установленные62 получают новую политику
при следующем звонке; отдельная перепаковка тех же нативных клиентов не нужна.

## Проверяемый путь

Настоящие клиенты LiveKit Flutter, закреплённый SFU, Opus/VP8,
640×360/20fps/500кбит/с, sender-specific AES-GCM. До установки ключа RTP
принимается, видеокадров/аудиометок нет, записанный PCM имеет нулевой пик.
После установки ключа декодируются контрольные суммы обеих модальностей
и синтетическая речь. Нет аккаунта Matrix или захвата камеры. На отправителе
PCM устройства ввода заменяется синтетикой до публикации; перед удалением
замены отправитель отключается. Сохраняется только синтетика.

Источник содержит движение и шум. Фоны подготовлены заранее; на Android
буферы видео и PCM подготовлены до измерения, чтобы сборка мусора стенда
не становилась измеряемой задержкой. Видео и звук используют один счётчик
аудиосэмплов; время создания каждой метки записано отдельно. Декодер аудио
тот же, что в браузерной квалификации: четыре DTMF-символа с ID и checksum.
Декодирование использует позицию PCM, затем преобразует её во время
соответствующего колбэка. Пакетная доставка колбэков проверена unit-тестом.

Android-квалификация использует отдельный нативный отправитель macOS.
Оба SDK не работают внутри одного эмулятора. В прежнем варианте эмулированный
захват сам создавал разрывы аудио (до2,4с concealed samples за120с), хотя
netem менял только видео. Такие попытки сохранены как диагностика, а не
как приёмка исправления. Межплатформенный кандидат: audio packetsLost=0,
concealed samples=1733, то есть36,1мс за весь прогон. Это не доказывает причину
исторического звонка на Xiaomi.

Сигналинг и результат остаются на loopback с одноразовым nonce. Для связи
Mac↔эмулятор зашифрованный RTP временно опубликован только на выбранном
локальном частном IPv4 интерфейсе: loopback-псевдоним10.0.2.2 доступен лишь
эмулятору. Проверяются принадлежность адреса хосту и отдельный account-free AVD.
Учётных данных production нет. Контейнеры и нативные точки входа восстанавливаются
при успехе и ошибке. Тестовый Swift/Kotlin не включается в release app.

Только video RTP/RTX задерживается150мс30с, затем блокируется12с; аудио
продолжает идти, далее58с восстановления. PT берутся из приёмного codec/SDP:
SFU перенумеровывает payload. Пауза подтверждена: за8с video packets+0,
audio packets>30, сохранены netem counters.

Guard: в clean и начиная с5с после восстановления одновременно
max(abs(received skew))≤80мс и max(abs(skew минус измеренное смещение
источника))≤80мс, не менее4/12 пар, смещение источника≤75мс. Окно аудиодекодера
21,33мс. Это renderer/sink qualification, не акустическая проверка.

| Получатель / кандидат | Максимум clean / recovery | С поправкой на источник | Статус |
| --- | --- | --- | --- |
| macOS, fixed130 | 56,3 /39,7мс | 20,9 /41,2мс | A/V, E2EE и речь pass; три кандидата прошли80мс |
| Android, отдельный Mac sender, fixed130 | 37,4 /28,6мс | 31,9 /72,3мс | A/V, E2EE и речь pass |
| Android, контроль без RTP-настройки | 97,7 /87,8мс | 102,1 /97,2мс | Дефект воспроизведён |
| Веб, product gain и прежний jitterBufferTarget130 | 52,6 /30,6мс | неприменимо | A/V pass; E2EE worker не менялся |

Отклонены: общая stream group (восстановление выше80мс), включая сочетание
с fixed130 на Android; диапазон130..10000мс; одиночный тон без checksum;
построение всех пикселей в каждом debug-кадре; netem с PT отправителя вместо
получателя. Изменение SDK для локального объединения SDP возвращено, его diff
сохранён только как свидетельство отклонённой гипотезы.

## Воспроизведение

Из подготовленного build checkout:

```sh
python3 apps/client/tool/check_sdk_key_publication.py --flutter /path/to/flutter \
  --av-marker-output /tmp/native.media.json --output /tmp/native.proof.json \
  --av-marker-network --av-speech /path/to/synthetic-mono48k-pcm16.wav \
  --video-playout-ms 130 --max-video-playout-ms 130
node --experimental-default-type=module apps/client/tool/score_native_av_marker.mjs \
  /tmp/native.media.json /tmp/native.analysis.json
```

Для Android: --device emulator-5554 --android-emulator --adb /path/to/adb
--av-sender-root /path/to/matching-macos-checkout --av-media-ip <local-private-ip>.
Оба checkout должны содержать одинаковую fixture; разрешён только
VoiceChat_KeyEpoch35. Для контроля убрать --video-playout-ms 130.
Сравнение compare_native_speech.py выполняется в окружении NumPy/SciPy/pystoi:
парные ID, отдельные clean/delay/pause/recovery, минимум4 клипа на фазу,
STOI не ниже контроля более чем0,005, разница уровня≤0,15дБ. Фазы определяются
часами получателя: отправитель и получатель могут иметь разные monotonic epochs.
Реальные записи, ключи, SDP и пользовательские идентификаторы в Git не входят.

Android: парное сравнение речи прошло во всех четырёх фазах; максимальное
снижение STOI 0,0012 при допуске0,005, разница уровня не более0,085дБ.

macOS: все3 кандидата прошли raw и source-corrected max80мс; максимум
после восстановления с поправкой на источник75,08мс. Контроли: один
превысил80мс (127,75мс), два прошли — дефект не воспроизводится в каждом
звонке. Совокупная речь:24/42/15/74 парных клипа по фазам; худшее снижение
STOI0,004870 при допуске0,005, разница уровня≤0,009дБ. Нельзя объявлять
нулевую потерю качества по одной статистике или выдавать её за прослушивание.

В [машинном свидетельстве](native-av-sync-after62.json) сохранены все
контроли/кандидаты серии, протокол, результаты речи и признаки E2EE.

Веб-речь против опубликованного web130: все4 фазы прошли прежние допуски;
худшее снижение STOI0,00388, разница уровня≤0,080дБ.

## Открытый личный P2P-тракт

DirectCall использует личный P2P, CallProbe — LiveKit. Серверная политика130
не меняет P2P. Нативная лаборатория использует настоящие PeerConnections,
два TURN relay, H264/Opus, синтетические метки и речь. Матрица аккаунтов
не создаётся. Неверный SHA256 DTLS fingerprint приводит к dtlsState=failed
и нулю принятых медиапакетов; правильный даёт декодируемое содержимое с
AES_CM_128_HMAC_SHA1_80. Это проверка DTLS-SRTP, а не AES-GCM missing-key
gate LiveKit. Настройки шифрования не меняются.

Нативный SDK адаптирует разрешение320/480/640. Первоначальный декодер P2P
читал фиксированные пиксельные координаты и пропускал уменьшенные кадры:
прежние P2P timing-числа предварительные, ими нельзя закрывать80мс.
Проверены все4 принятых LiveKit-кандидата: они сохраняли640×360 во всех
сэмплах, опубликованная квалификация не затронута. Новый декодер использует
координаты относительно размеров принятого кадра. Стенд ждёт фактический
декодированный кадр до замера и классифицирует все согласованные video PT,
включая RED/FEC/RTX; пересечение с audio PT запрещено. Во время outage
по-прежнему обязательны video packets+0 и продолжающийся audio.

| Проверка macOS, масштабируемый декодер | Максимум recovery | Вывод |
| --- | --- | --- |
| Исходная общая группа H264, обычный буфер | raw2010,2 / corrected2029,7мс | Дефект воспроизведён |
| То же, отрицательный DTLS-тест после измерения | raw2048,4 / corrected2064,3мс | Порядок криптопроверки не причина |
| Отдельный первый video msid с сохранением исходного потока, обычный буфер | raw104,9 / corrected56,6мс | Большой дрейф устранён, строгий raw80мс не пройден |
| Глобальный нативный fixed100 в LiveKit с серверным130 | clean raw86,5мс | Отклонён: нельзя распространять на все звонки |

Дополнительный первый video msid позволяет разделить нативную группу
синхронизации, сохранив исходный поток с обоими треками для Matrix metadata
и UI; фактическое членство проверено на получателе. Продуктовый кандидат реализован, пока не выпущен. Приватные ABI/vtable-вызовы не добавлены.
В C++ SDK есть SetJitterBufferMinimumDelay(optional<double> seconds), в
публичных Java/ObjC wrappers setter отсутствует. Простой SDK upgrade не
считается решением без проверки API и поведения.

Сравнение речи с исходной общей группой улучшило STOI, но не прошло
прежний допуск изменения RMS0,15дБ; этот результат не удалён. Отдельный
контроль влияния буфера при одинаковой раздельной группировке (обычный
буфер против100мс) прошёл прежние STOI/RMS-допуски во всех4 фазах;
52 парных декодированных речевых клипа побайтно совпали:9/13/5/25.
Геометрическая ошибка видеодекодера не влияет на эти PCM-свидетельства.
Это не физическое прослушивание и не утверждение, что прежний RMS-тест прошёл.

Следующий протокол источника выбран до новых результатов: видеокадр с
новой меткой ставится на отдельную очередь при границе аудиометки, сохраняя
номинальный20fps таймер (до0,5 дополнительного кадра/с). Аудиоволна не меняется,
работа не переносится в realtime audio callback. Это исключает независимую
квантизацию визуального начала периодом50мс самого стенда. Raw и corrected
80мс остаются обязательными; дополнительно проверяется max source offset20мс
для всех отправленных меток, включая не дошедшие до получателя. Такой
контролируемый источник не заменяет физическую проверку камеры и динамика.

Первый фактический продуктовый прогон `product0-coherent` прошёл: raw clean
49,28мс / recovery55,53мс, corrected50,16/57,09мс, максимум источника7,38мс.
Проверены два video msid, исходный поток с обоими треками и отрицательный
DTLS-контроль; буфер SDK, H264/Opus, обработка звука и криптография не изменены.
Это один прогон, не завершённая квалификация. До следующих результатов
задан протокол: ещё два независимых прогона с теми же80/20мс пределами,
каждый сравнивается с одним свежим обычным аудиозвонком по прежним
STOI0,005/RMS0,15дБ; все результаты учитываются отдельно. После этого —
Android с отдельным Mac-отправителем и регрессии. Неуспешные запуски
подготовки аудиоконтроля не засчитываются в качество медиапотока.

Остаток и версии ведутся только в [UA-08.C06](../user-acceptance.md):
квалифицировать минимальное P2P-исправление, Android с отдельным нативным
отправителем, регрессии речи/E2EE и затронутого LiveKit, затем выпустить
подписанные нативные клиенты, если меняется продуктовый код. Физические
Xiaomi и iPhone Safari/PWA остаются недоступными для текущего стенда.

Свежий обычный аудиоконтроль завершён: DTLS negative blocked, Opus,
relay-only, аудио продолжалось во всех фазах. A/V-score для него ожидаемо
`insufficient_markers`, поскольку видео не отправляется. Сравнение с первым
продуктовым прогоном не прошло STOI в delay:0,9805268 против0,9891161
(допуск0,005), RMS прошёл. Результат сохранён, не усредняется и не исключается.
Потерянных audio packets в обоих прогонах0, но concealment вырос с1686 до5134
samples в delay кандидата; требуется установить влияние графика доставки/
нативного playout. Продуктовый выпуск остаётся закрыт этим результатом.

Итог заранее заданной продуктовой серии (обычный буфер): A/V2/3 PASS,
речь1/3 PASS. Второй прогон: recovery223,03мс raw /217,90мс corrected при
валидном source7,41мс. Третий: raw43,84/56,72мс, corrected52,17/60,83мс,
source8,68мс; речь PASS. Продуктовая серия отклонена, а не усреднена.
Следующий пилот до результатов задан как video min20/max100мс, прежние
raw/corrected80мс, source20мс и STOI/RMS. В исходниках закреплённой ветки
WebRTC7871 подтверждены ForcePlayoutDelay в RTP video receiver и ограничение
render time. Нулевой minimum с max<=500 включает вывод без сглаживания,
поэтому выбран положительный minimum20. Сначала P2P и LiveKit AES-GCM,
затем полноценная квалификация, если пилоты пройдут. Это не выпуск.

Пилоты с тем же источником и прежними допусками:

| Вариант | A/V clean/recovery raw, мс | Речь | Итог |
| --- | --- | --- | --- |
| P2P video20–100 |38,69/93,21; corrected recovery94,88; source7,50 | PASS | Отклонён: видео опережает аудио |
| P2P fixed100 |51,91/46,45; source7,42 | PASS | Один пилот, не квалификация |
| LiveKit AES-GCM fixed100, SFU130 |80,12/59,75; corrected79,07/58,64; source2,44 | PASS | Отклонён по raw80,12; ключевой контент-гейт пройден |

После этих результатов до следующего прогона выбран fixed90 для обоих
маршрутов. Не округляем80,12 до проходного80 и не меняем STOI/RMS-пороги.
Первичные исходники SDK: [RTP video receiver, ветка7871](https://webrtc.googlesource.com/src/+/refs/branch-heads/7871/video/rtp_video_stream_receiver2.cc),
[video timing](https://webrtc.googlesource.com/src/+/refs/branch-heads/7871/modules/video_coding/timing/timing.cc).

Fixed90 оба пилота прошли: P2P raw29,08/68,29мс (corrected25,34/71,24),
LiveKit21,69/31,27мс (corrected23,85/33,56), речь и криптогейты PASS.
Настройка перенесена в нативную инициализацию Darwin/Android; SDK binaries,
кодеки, DSP и cryptors не изменены, это подтверждено сверкой с архивом1.6.3.
Фактический Mac plugin SHA-2563f1171b2fb220a145b69711ed9a87886fc215322608d4c61559d074d2cb60a36.
Серия продуктового default90 без стендового override: первые два A/V PASS
(recovery67,46/65,92мс), третий invalid_source_timing21,44мс>20, при этом
raw102,28/corrected80,84мс тоже не приняты. Речь3/3 PASS. Серия не закрывает
выпуск. Генератор видео перенесён на очередь userInteractive (звук не меняется),
до новых результатов заданы3 свежих P2P-прогона с прежними20/80мс и STOI/RMS.
Исходный неуспешный прогон сохранён. Затем3 actual LiveKit и Android/web.

После QoS исправления3/3 продуктовых Mac P2P-прогона прошли A/V80мс
(max corrected74,79мс, source max4,92мс). Последовательная речь1/3 PASS.
A/A того же бинарника также нарушает STOI: clean−0,00852 и pause−0,02418;
это не позволяет приписать разницу кодовому изменению. Все результаты сохранены.
Замороженная серия actual-default90 LiveKit:3/3 A/V, речь и AES-GCM PASS,
max raw75,05мс /corrected73,50мс. PluginSHA во всех прогонах один3f1171b2…
Пилот одновременного обычного аудиозвонка и видеозвонка прошёл прежние
STOI/RMS во всех фазах; P2P recovery45,37мс raw/46,47 corrected, source4,02мс.
Дорожки/приёмники различны, источник/часы общие, Opus SDP совпадает, оба
соединения прошли свои положительные и отрицательные DTLS-контроли.
Аудиоконтроль не отправляет видео, его A/V-анализ ожидаемо insufficient_markers,
при этом62 CRC-аудиометки декодированы. До результатов заданы3 свежих парных
прогона с перестановкой порядка запуска во втором, все должны пройти;
никакие старые провалы не исключены из журнала.

### 04.11: одновременный контроль и исправление SDK

Свежая серия трёх одновременных пар завершена:2/3 проходят A/V и речь;
один звонок raw97,99/corrected100,80мс плюс регрессия речи. Кандидат
split-msid/global90 отклонён, все результаты сохранены. Обычная общая
синхронизация с фактическим global90 воспроизвела recovery2105,44мс
и задержку аудио до2240,07мс. Ограничения видеобуфера недостаточно.

В точном исходнике SDK150.7871.04 (a545de45259b47dfac5f3635863e47cb601f1bb2)
`VideoReceiveStream2::GetInfo()` получает неограниченный `TargetVideoDelay`,
тогда как `RenderTime()` ограничивает current delay min/max playout.
Подготовлен отдельный `TargetVideoDelayForSync()` с верхним пределом.
Старый getter сохранён для защитного reset в VideoStreamBufferController.
Четыре файла; кодеки, аудио DSP, шифрование и CA-набор SDK04 не меняются.
Два новых C++ теста должны сначала упасть на старом поведении, затем весь
VCMTimingTest должен пройти. Сборка в изолированном CI, не на пользовательском
Mac с ограниченным диском; после неё нужны реальные shared-stream P2P, речь,
LiveKit AES-GCM и Android. Патч пока не считается доказанным исправлением.

GitHub CLI авторизован пользователем, вход завершён; scopes repo/read:org/gist,
хранение keyring. SDK source branch `codex/native-sdk-av-sync`, полный журнал
запуска и хеши будут добавлены после CI. Новая версия63 не опубликована.

SDK build inputs сохранены плоскими файлами `infra/build_webrtc_sdk.py`,
`infra/webrtc-sdk.json`, `infra/webrtc-bounded-sync.patch`, `infra/WEBRTC_SDK.md`.
Это сохраняет существующий контракт frozen migration sources;19 migration
тестов PASS. Первые CI-прогоны с вложенным каталогом отклонены, код
миграции/проверки безопасности не ослаблялся. Изолированный GN test target
зарегистрирован в корневом графе; исправленный SDK workflow:
https://github.com/kerbermeister/voicechat/actions/runs/41873429695.

Подготовлен shared-stream paired-speech fixture: обычный аудиозвонок и
видеозвонок имеют отдельные дорожки/приёмники, единые часы источника и
одинаковые Opus SDP; аудио/видео основного звонка теперь явно должны иметь
один общий stream ID.4 Python и2 Node проверки стенда PASS, targeted Dart
analyze PASS. Полная локальная серверная проверка до setup нового worktree
невалидна (нет локальных test secrets, а путь .prototype нарушает существующую
assertion стенда); чистый CI выполняет штатный setup и полный набор.

Текущий SDK CI4631d2f:
https://github.com/kerbermeister/voicechat/actions/runs/41875798369.
Исправлен обязательный путь Android build_aar внутри source checkout.
Общий Prototype CI54ca593 завершён успешно:854 серверных теста, analyze,
Flutter tests и обычный Android preview.5 проверок доставки SDK SHA/размеров,
кеша, Maven metadata и границ источника PASS. Подготовлены отдельные source
и artifact manifests, чтобы публикация хешей не запускала сборку SDK заново.

До результатов новых SDK-звонков закреплены3 shared-stream simultaneous
Mac P2P пары,3 native LiveKit,3 Android P2P и3 Android LiveKit с речевыми
контролями. Все валидные прогоны должны пройти прежние source20/AV80мс и
STOI/RMS, без усреднения провалов. Дополнительно нужны2 Mac и2 Android
зеркальных audio-only RTP stall: аудио останавливается, видео продолжает
получать пакеты, затем обе оценки A/V после восстановления <=80мс. Стенд
для зеркального случая подготовлен, медиапроверка ещё не выполнена.
Публикация Android по существующим правилам требует физической приёмки точного
APK; удалённый Xiaomi нельзя заменять результатом эмулятора.

### Уточнение корневого исправления: текущая задержка вместо целевой

Повторная оценка исходного adaptive/shared0-coherent: recovery video sink
median25,41мс, max100,67мс; audio sink median707,84мс, max2244,55мс.
Это поддерживает исправление самого несоответствия TargetDelay и CurrentDelay,
а не обязательный fixed90. Фиксированный верхний предел также ограничил бы
легитимную синхронизацию с более медленным аудиоустройством.

В актуальном патче `VideoDelayTimings::CurrentDelay()` возвращает ту же
эффективную задержку, что рендерер:0 для low-latency path, иначе clamp текущей
задержки между min/max. `RenderTime` и `VideoReceiveStream2::GetInfo` используют
один этот расчёт; raw TargetVideoDelay остаётся для защитного reset. Три новых
C++ теста охватывают jitter target2s при current20ms, границы/минимум аудиоустройства
250ms и low-latency mode. Нативные factory defaults возвращены к upstream;
адаптивный буфер и учёт гарнитур сохранены. Матрица и допуски проверок прежние;
ни одного медиапрогона этого SDK ещё нет. Альтернативный bounded-target SDK
остаётся историческим кандидатом и не предназначен к выпуску.

CurrentDelay C++ gate в1c848bb пройден:
https://github.com/kerbermeister/voicechat/actions/runs/41884712502.
На старом TargetDelay поведении все3 SyncDelay regression tests падают;
с исправлением21/21 VCMTimingTest PASS,0 failures/errors/skips.
XML и receipt сверены с patch SHA8f9c5903638c6117f68269fed254defa5fbf44e9fa1ae07c2cfc5664bb1df9f7.
Это доказательство расчёта в C++, не медиаприёмка. Собираются native SDK
Mac/Android; новых нативных звонков/обновлений пока нет.
Дополнительный P2P gate: excess voice delay относительно одновременного обычного
аудиозвонка <=80мс в clean, после5с video pause и после5с recovery.
Так исключаем исправление lip-sync искусственным накоплением обоих потоков.


04.11, продолжение сборки: Android job126777599005 остановился до C++:
штатный build_aar вызывает Siso, которому не подходит Ninja-флаг `-j2`.
В6004dfe заменён только лимит параллелизма на `-local_jobs=2`;
повтор41890363278 выполняется с тем же8f9c5903 C++-патчем.
Исходная macOS job126777598847 дошла до компиляции4239 targets на срез.
Ни один результат этих SDK ещё не считается медиаприёмкой.

Для Android ordinary audio-only control добавлен в cross-device fixture;
аудиобуфер измеряется по delta jitterBufferDelay / delta jitterBufferEmittedCount
с монотонными временами samples и фактическими фазами. До новых результатов
зафиксирован дополнительный порог: максимальная средняя задержка за интервал
минус медиана обычного аудиозвонка не более80мс в clean/video-pause/recovery
после5с. Контроль gates:79,5мс проходит,80,5мс и2с отклоняются;
отсутствующее свидетельство не принимается. Это не проверка физического DAC.


04.11, упаковка Mac: обе архитектуры успешно скомпилированы в41884712502,
но моя команда `lipo -verify_arch ... <file>` имела неверный порядок аргументов.
Сборка остановилась до готового SDK ZIP; артефакта исправленной библиотеки пока нет.
В8b2aaae проверка исправлена и добавлено сохранение промежуточного framework
с source/hash receipt до упаковки, а вf5d9a58 выбран arm64 — фактическая
архитектура установленного `/Applications/VoiceChat.app` и текущих выпусков.
Повтор41899866524 использует точные C++-свидетельства6004dfe:
повторно проверены3 отрицательные регрессии,21/21 зелёных и0 skipped/notrun.
Четыре теста верификатора доказывают отказ при другом source pin, skipped test
и отсутствии отрицательного контроля. Нативная упаковка f5d9a58 отдельно
прошла реальными xcodebuild/lipo/ZIP на копии штатного SDK; это не медиаприёмка.

Итоговое подключение упрощено: flutter_webrtc остаётся hosted1.6.3 из прежнего
pubspec.lock, его копия в vendor не нужна. Android централизованно выбирает
проверенный SDK через Gradle resolutionStrategy, оба исходных зависимых build
файла остаются штатными. Mac использует относительный podspec и существующий
CocoaPods-путь; SwiftPM остаётся выключенным как в опубликованном клиенте.

## Второй нативный дефект: удержание A/V-задержки (04.11)

SDK vc1 собран: 21 C++ тест прошёл, три отрицательных контроля воспроизвели
ошибку getter. Android AAR и macOS arm64 framework проверены по receipt/SHA;
опубликован только prerelease зависимости, не обновление приложения.
Первый настоящий P2P-вызов Mac→Android API35 с точным JNI vc1 не прошёл:
clean 28,704 мс (27,806 с поправкой), recovery 384,772 мс (385,652 с поправкой).
Отрицательный DTLS fingerprint и положительная расшифровка контрольных меток
прошли. Это не квалификация FrameCryptor E2EE через SFU и не сравнение речи.

Во время 12-секундной остановки видео аудиобуфер держался около 510 мс,
его цель — 483 мс. В исходнике RtpStreamsSynchronizer при отсутствии новых
пакетов выполняется return без снятия ранее установленного minimum delay.
Кандидат vc2 снимает только добавку A/V-синхронизации после двух секунд без
одного потока; сбрасывает накопленное состояние контроллера и освобождает
старую пару при detach/reassign/destruction. Пакеты, NetEq DSP, base/device
latency, криптография и границы video playout не меняются. Добавлены пять
детерминированных тестов настоящего C++ синхронизатора; их выполнение ожидается
в CI вместе с 38 существующими timing/stream-sync тестами.

Отдельный дефект стенда: lifetime TURN был 120 с записи +120 с подготовки;
холодная сборка съела запас, и транспорт остановился примерно на 98-й секунде
записи. Рассинхрон 385 мс возник до истечения срока и остаётся отрицательным
результатом, но попытка не считается полным 120-секундным прогоном. Нативным
стендам дан отдельный setup grace 900 с и добавлена проверка роста счётчиков
обоих RTP-потоков в последние десять секунд. Первый повтор остановлен до
измерения: remote candidate оказался prflx вместо требуемого relay; guard
сохранён, результаты не засчитаны. Повторная диагностика завершена: полный120-секундный прогон, в конце audio+503/video+1366 RTP-пакетов и206 декодированных видеокадров за10с. Clean67,627мс и recovery416,472мс с поправкой на источник; максимальное смещение самого источника1,310мс. Native logs: audio current delay до906мс, после паузы814мс; прежний код сохранял большую задержку при отсутствующем видео. DTLS-SRTP negative/positive controls снова PASS. Это независимое подтверждение дефекта vc1 без истечения TURN.

vc1 запрещён к продвижению в клиентский выпуск. Для vc2 ещё нужны C++ green
с red-контролями, новые SDK обоих платформ, полная серия P2P/SFU, сравнение
речи с обычным звонком и проверки E2EE. Клиентские каналы остаются 1.19.14(62).

Проверка живого транспорта расширена на общий scorer P2P/LiveKit: в последние
10 с должны расти audio/video packetsReceived и video framesDecoded; у
обычного audio-only контроля проверяется звук. Новый тест даёт корректные
метки в начале recovery, затем замораживает декодер при продолжающемся RTP:
старый SFU scorer ошибочно PASS, исправленный — stalled_transport. Все четыре
Node-теста PASS. Повторный анализ прежнего успешного macOS SFU130 сохранил
PASS (audio+407/video+651 packets,201 frames за10с); полный vc1 Android вызов
сохранил budget_exceeded416,472мс при живом транспорте. Это повторный анализ
сохранённых данных, не новый медиапрогон vc2.

vc2, первый C++ gate (run41917176968/sourcee3c4875):43/43 PASS, все8
отрицательных регрессий воспроизведены, пропусков нет. Артефакт с receipt/XML
сохранён. До платформенной сборки завершён охват штатного upstream target:
video/BUILD.gn получил зависимости environment_factory и time_controller для
добавленных тестов. C++-алгоритм не менялся; финальный патч теперь включает8
файлов, поэтому нужен новый exact-source gate. Старые платформенные jobs
остановлены до существенной сборки; этот green не выдаётся за проверку нового
GN fingerprint или звонков vc2.

Финальный8-файловый gate41920380791/sourceae0c317 завершён:43/43 PASS,
8/8 red-контролей,0 пропусков. Receipt, SDK/toolchain pins и XML сверены
локальным verifier. Mac job126898436620 и Android126898436636 собираются.
Медиапрогонов vc2 ещё нет. Первый пилот заранее усилен: macOS одновременно
с обычным голосовым контролем, Android с новым обычным control перед A/V;
сразу проверяются лишняя задержка голоса и речь по прежним80мс/0,005 STOI/
0,15дБ, чтобы отклонить неполное решение до всей серии. Это усиление проверки,
допуски не ослаблялись; новые пользовательские пункты приёмки не создаются.

macOS SDK vc2 собран и опубликован только как dependency prerelease. SHA-256
8b9f68f70041ce67b01cdc6c4a74e2febe563f3b975fa00208023aa37568a855,
arm64 UUID f11b61e7-1a79-31d6-9eaf-90c8904e8f8e; прямой HTTPS GET совпал
по SHA/размеру. Нативный медиапилот ещё не выполнен, Android ещё собирается.
Mac-only интеграция для внутренних испытаний остаётся локальным коммитом до
полного Android manifest; клиентские каналы62 не менялись.

## vc2 paired pilot: A/V pass, voice fail; vc3 prepared (05.11 local)

Exact SDK UUID f11b61e7-1a79-31d6-9eaf-90c8904e8f8e was verified inside the
running native Mac app, with the original hosted wrapper and no fixed90.
The actual P2P/DTLS-SRTP paired call passed transport and final decoded-content
liveness; clean51.275/recovery51.686ms source-corrected A/V, source3.887ms.
It failed the ordinary-voice gate: clean-0.262ms, video-pause1165.610ms,
recovery23.057ms added delay. Candidate audio queue reached1992ms while its
ordinary simultaneous control stayed~51ms. The target reached2412ms, then the
stale reset lowered it to40ms; already queued speech took time to drain.
Only3 paired pause speech clips remained (required4), so quality is unqualified.
This is a failed pilot, not an accepted improvement. Lossless synthetic media,
voice/queue diagnostics and binary identity are retained; SDK vc2 release notes
explicitly prohibit application promotion. Public client channels remain62.

vc3 bounds both the audio delay controller state and output to80ms beyond its
explicit base, preventing the buildup before a video outage. Natural adaptive
NetEq/device delay and video synchronization for slow audio hardware remain
independent. The existing stale/reset cleanup remains. A new real-controller
cap regression and explicit-base test extend the gate to45 C++ tests/9 negative
regressions. Fresh compiled SDKs and all native media gates are still required;
none of the latency, speech or encryption criteria were relaxed.


## vc3 compiled gate and continuous-RTP recovery (05.11 local)

Run41931657101/source3c68506 compiled the pinned patch17965b9e:45/45 real
C++ tests pass, zero skips/errors; all9 required regressions fail with the
original getter/synchronizer. The downloaded receipt matches every source and
toolchain field. Platform SDK builds started; no vc3 media has run yet.

Before vc3 media, two additional paired trials per platform are specified:
video delay starts at20s and ends at50s without blocking RTP. Both streams must
continue through52..60s. A/V and added voice-delay recovery budgets start at55s,
not67s. The scorer regression inserts120ms lag at56s and rejects it in this
scenario while preserving the full-outage window. Existing speech, crypto,
source-timing, sample-count and80ms limits remain unchanged. Four Node tests and
Dart analysis of all three P2P fixtures pass. This adds laboratory coverage,
not physical-device acceptance; UA-08.C06 stays open and app channels stay62.


### Continuous-RTP negative control on rejected vc2

One fresh native Mac paired call used the exact vc2 UUID above and the new
bc35f01 fixture: video delay20..50s, clean from50s, no RTP outage. All native
transport assertions passed; final audio503/video1874 packets and206 decoded
video frames prove continued media. Source offset4.370ms; clean A/V49.433ms.
Recovery from55s failed at raw1877.494/corrected1878.354ms: audio, not video,
was late. Added voice delay reached1942.144ms; measured audio queue2126.481ms,
with target2071.296ms at57.2s. Interval queue averages stayed above100ms
for38.031s after clean networking returned; this is receiver buffering, not an
acoustic-latency measurement.
Speech also failed the unchanged gates (delay STOI0.8472 vs ordinary0.9891;
recovery0.9021 vs0.9945). All four phases had enough paired speech clips.

This is a rejected-vc2 negative control, not a vc3 media result or proof on a
physical Xiaomi/iPhone. It reproduces the persistent desync and audio degradation
without an RTP stop, supporting the vc3 controller-state bound. Lossless
synthetic media, pairs with offset direction, queue diagnostics, ordinary-voice control
and speech metrics are retained privately. Public application channels remain62.


### vc3 macOS SDK ready; media pending

Run41931657101/source3c68506 produced a verified macOS arm64 SDK. Public HTTPS
archive SHA-25690af747f20b2343bfdfffad37763c8bf2200fd004b41ef5fa6edab7599263b06,
size6341609; UUID50a0c7b4-176b-3f63-b31e-2584b0ac50c7. Normal generated third-party
notices and all source/C++/build receipts are in the dependency prerelease.
The Mac-only pin is for internal qualification while Android builds; no incomplete
Android manifest is pushed to the shared branch. Native media and application
publication are still pending. CocoaPods checksum is generated by `pod ipc spec`
using the format first checked against the existing lock, then confirmed by
normal pod resolution. Application channels remain62.


### vc3 initial Mac pilot: voice fixed, A/V still fails

The exact new SDK UUID50a0c7b4-176b-3f63-b31e-2584b0ac50c7 was verified in
Pods and the rebuilt test app, using the unchanged hosted plugin. Initial
same-version `pod install` had reused the vc2 external spec; the UUID guard found
this before media and that setup was aborted (`No tests ran`). A targeted
`pod update WebRTC-SDK --no-repo-update` installed vc3 and reproduced the
platform-generated lock checksum0aa2856f6f7c8ddd25d9110220efb2cd390dd22c.

The actual vc3 paired pilot passes added voice delay (clean10.853,
video-pause10.582, recovery10.928ms) and all speech gates: STOI, SI-SDR and level
match ordinary voice in all four phases. Source max5.399ms is valid.
Clean A/V63.458ms passes; recovery99.364ms fails80ms. One of26 recovery pairs
exceeds the budget (id44,18.243s after recovery); most remaining offsets are
negative50..78ms, with video arriving earlier than audio. Both RTP streams and
decoded video remain live. This is not an accepted candidate. The failed pilot
is retained, dependency notes mark the failed A/V gate, and app channels stay62.
Further diagnostics add callback-vs-native-render timestamps and existing SDK
sync logs, without changing the scorer or thresholds. No vc3 SFU FrameCryptor
qualification or physical-device result is claimed.


### vc3 render diagnostics and both SDK archives

Android AAR completed from the same source/gate, SHA-256
5bdfad08959a68b105e9ae8979b3765d0f89a61f2cc898013b1150b83d31ef01,
size36273763; all three JNI ABIs, Java bindings, receipt and public HTTPS bytes
verified. This completes the dependency pins, not Android media acceptance.

A fresh instrumented Mac call still fails recovery at100.681ms. Native video
callbacks occur about9ms before their scheduled presentation (the existing
renderer allowance). When aligned in time, native current delay155ms matches
nearby video latency159ms; comparing it with a later64ms median would be wrong.
The failing marker instead has audio167.776/video67.095ms end-to-end latency.
This is not evidence for changing the timing units or relaxing the80ms gate.
The fixture now retains render clocks and reuses the bounded native-log collector.
Diagnostic settings stay off in normal runs; no test hook enters the app.

Before any result, a separate diagnostic is selected with native video
min=max130ms and the same vc3 audio cap, shared streams and ordinary-voice
control. It tests the user's requested130ms policy with unchanged A/V, voice,
speech and encryption gates. It is not an application configuration yet and
does not erase either failed adaptive pilot. A successful diagnostic still
requires production initialization plus the complete fresh qualification series.


## Native130ms diagnostic passes; vc4 initialization prepared

One actual vc3 Mac paired diagnostic with native min=max130ms passes all gates:
clean raw59.138/corrected57.846ms, recovery raw53.484/corrected50.769ms;
source4.368ms. Added voice latency max23.166ms and speech comparison pass.
Native sync logs show current video delay130ms throughout, proving the option
was applied, not merely written to the report. Both streams/decode remain live.
This single diagnostic does not erase the failed adaptive trials or qualify vc4.

vc4 preserves the exact vc3 C++ timing/voice fixes and configures the130ms policy
in the Objective-C/Java initialization entry points used by the hosted wrapper.
It preserves explicit field-trial settings, other options and existing invalid-
input validation. Local checks:9 Foundation cases pass for the actual method and
helper;9 Java exact-helper cases pass. The original Mac method and actual vc3 AAR
constructor fail the new default check as expected. Full vc4 AAR constructor
checks, compiled binary checks, fresh45/9 C++ gate and native media are pending.
The12-file patch applies cleanly and all original/patched hashes match. No SDK4
media result is claimed. SDK notices are also retained in final framework/APK
resources; a packaging smoke on copied SDK3 preserves signatures and all original
Android classes/JNI bytes. It is packaging evidence, not SDK4 runtime evidence.
