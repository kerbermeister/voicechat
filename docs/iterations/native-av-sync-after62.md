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

В опубликованном этапе full104 относительно нативного62 (596a80f) не было изменений
продуктового Flutter/Swift/Kotlin/SDK-кода. Последующие нативные кандидаты ниже
ещё не выпущены. Штатный full-релиз сервера и web для первого этапа LiveKit выполнен. Установленные62 получают новую политику
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
## Fresh vc4 C++ gate verified; native builds in progress

Run41947763477/sourcee688a36 passes all45 native tests with zero failures/skips
and all9 original-behaviour negative regressions. The downloaded receipt matches
the exact12-file patch ea71b607 and every SDK/toolchain pin. macOS/Android binary
builds have started; their9 configuration cases and media qualification remain
pending. Application channels stay62.

The SDK3 adaptive Android before-control initially stopped before measurement:
the cross fixture skipped its video track but its default offer still advertised
a recvonly video m-section. The receiver's strict audio-only SDP assertion caught
this. The fixture now uses the existing explicit audio-only offer constraints
for both negative and positive rounds. Analysis passes; the fresh ordinary audio-only native cross call
passes, with both encryption-control rounds and live transport. The A/V candidate
capture remains in progress. The failed setup and logs are retained separately and do
not count as a media failure or successful SDK4 evidence.

## SDK3 adaptive Android baseline completed

A fresh ordinary audio-only call and a separate actual Mac-to-Android-emulator
P2P video call pass: clean raw77.307/corrected78.279ms; recovery raw62.959/
corrected62.070ms. All-source offset2.733ms; audio/video packets and206 decoded
frames remain live in the final recovery window. Extra interval audio queue is
70.000ms clean and11.795ms recovery; matched speech passes the unchanged0.005
STOI/0.15dB limits. Both actual DTLS-SRTP negative/positive controls pass.
This is one SDK3 adaptive diagnostic on the owned API35arm64 emulator, not SDK4
qualification or physical Xiaomi acceptance. The Mac adaptive failures remain.
A separate SDK3 LiveKit AES-GCM diagnostic is running while SDK4 binaries build.

## SDK3 LiveKit: RTP130 alone still exceeds A/V budget

A real native Mac LiveKit call with SDK3's adaptive factory and SFU RTP
min=max130ms passes speech and actual AES-GCM controls: encrypted packets arrive
without decoded media while the receiver lacks its key; installing the key
produces checksum-protected audio/video and matched speech. Final recovery still
has408 audio/653 video packets and201 decoded frames. A/V clean raw44.715/
corrected45.541ms passes, but recovery raw96.001/corrected97.951ms fails.
Source6.984ms is valid. This diagnostic used native factory override0: its130ms
was the SFU RTP setting, not the new SDK default. No release gate is relaxed.
A distinct SDK3 diagnostic with explicit native factory min=max130ms is running
to test the proposed policy in the same real encrypted SFU path. SDK4 binaries
and their own full qualification remain pending.

## Global native130 rejected by real encrypted SFU diagnostics

SDK3 plus explicit native factory130 fails independent-stream LiveKit: clean
raw110.983ms/recovery113.640ms, and clean STOI regresses0.005879 beyond0.005.
Actual AES-GCM controls pass. Measured video latency is176–179ms while natural
audio is66–78ms: the fixed video floor overshoots independent audio. A distinct
shared-sync130 call improves recovery to57.143ms, but clean81.013ms and speech
still fail. Source offsets remain valid. Neither failed result is discarded.
SDK4's global130 policy must not release on the earlier P2P diagnostic; its
platform-build cancellation was requested, with its fresh45/9 C++ proof retained.

Before capturing any new candidate, a70ms diagnostic protocol was recorded:
it aims video near118ms, centered in the observed independent SFU audio65–147ms,
without delaying ordinary speech. All old80ms/STOI0.005/level0.15dB/count gates
remain. Test-only inputs now permit70ms; no app default or production service
has changed. Three paired P2P and three AES-GCM SFU diagnostics are planned,
retaining every attempt, followed by fresh binary qualification if accepted.
The first70ms SFU diagnostic is running. This is a hypothesis, not a release.

## Fixed70 diagnostic: SFU passes, P2P still fails; next diagnostic90

The first SDK3 fixed70 AES-GCM SFU call passes: clean raw55.775/corrected56.766ms,
recovery raw28.056/corrected31.153ms, speech and missing-key/positive-content
controls. Mirrored audio-RTP interruption also passes raw/corrected recovery
35.115/36.001ms. But the paired P2P video-RTP interruption fails recovery
raw87.697/corrected89.317ms; speech and extra voice<=44.923ms pass. SDK70 is not
accepted and no native default changed. Its planned repeats do not count as
completed; a new90ms hypothesis is recorded before capture with the same gates.
The pinned sender source uses WebRTC-ForceSendPlayoutDelay, a separate key from
the receiver's WebRTC-ForcePlayoutDelay: the tested receiver default does not
force outgoing RTP hints. The90ms paired diagnostic is now running. A common
policy still requires both paths and every full native binary qualification.

## SDK5 prepared: receive-relative render delay and90ms receiver default

Both first SDK3 native90 precursor calls pass: P2P clean41.428/recovery34.827ms,
extra voice<=10.785ms and speech/DTLS controls; SFU clean60.551/recovery62.765ms,
speech and actual AES-GCM controls. These are diagnostics, not SDK5 evidence.

Time-aligned70ms P2P clocks expose an additional mismatch: nominal video delay
stays70ms while scheduled output for markers37/38/40 is−9.566/4.954/27.216ms
from capture. Actual callback is6.108/13.480/18.683ms from capture. Thus the
clamped buffer alone is not the remaining delay from the packet's arrival when
the RTP extrapolator shifts after jitter. SDK5 uses the same RenderTime function
as rendering and subtracts latest_receive_time, clipping expired schedules at0.
A new actual timing regression tests arrival-relative20/110/0ms, missing clock
fit and low-latency cases. CI must first reject the former nominal-buffer
calculation, then pass all46 C++ tests and10 negative regressions. The80ms audio
cap, stale reset, raw jitter estimate, codec/DSP/crypto/certificate logic remain.

The SDK5 default is90ms receive-only, with explicit0/90/130 and malformed input
behavior preserved. It is distinct from rejected old fixed90/split wrappers.
The pinned sender reads a separate ForceSendPlayoutDelay key, so remote hints
are not forced. Local Foundation9 cases pass; source/hash/apply and Python
checks pass. SDK5 binary builds and actual media are still pending. App62 stays.

## SDK5 C++ gate verified; SDK3 repeat exposes a speech defect

Fresh SDK5 run41955022535/source7339294 passes all46 C++ tests with zero failures/
skips; all10 original-behaviour negative regressions fail as required, including
the new receive-relative schedule test. Receipt/source/toolchain hashes match.
Native SDK5 binary builds have started; no SDK5 media or app release is claimed.

The SDK3 fixed90 precursor series passes audio-stall recovery20.146ms and
continuous-RTP delay recovery19.408ms, voice<=22.925ms and matched speech. Its
second P2P pair passes A/V37.006/31.238ms and voice<=22.542ms but fails pause
speech: aggregate STOI0.983761 versus control0.991192, difference−0.007431.
The series stops there; SFU2/3 and P2P3 were not run or counted as passed.
All outcomes remain retained; acceptance limits stay unchanged.

Offline clip analysis localizes the pause difference to marker30: individual
STOI0.925720 versus0.986180, while the other five pause clips match control.
There is no packet loss/concealment in that window. NetEq removes763 candidate
samples versus249 control samples, an extra514 samples (10.708ms), around the
synchronization-floor release. This supports investigating time scaling as a
cause; the counters alone do not prove causation or qualify SDK5's correction.
The synthetic control/candidate clips are retained locally for diagnosis. SDK5
must independently pass the full speech, voice, A/V and encrypted-content gates.


## SDK5 actual Mac pilot rejected; Android verifier toolchain mismatch

SDK5 run41955022535 produces the exact Mac archive281b6b82…89fb16, UUID
2625555c-0df2-3fb2-86f0-4ca5ab07172c. The9 compiled native configuration cases,
source/receipt hashes, notices and framework signature pass. Targeted CocoaPods
update and embedded UUID confirm the real SDK5 before media, rather than an old
same-version cached SDK. Generated Pod checksum is d5e50c5228c248bddd7755a0019cdc54475b1a99.
The dependency prerelease is not an application update and is not qualified.

Actual Mac paired P2P pilot current-8f742bdb-pilot-1 fails: clean raw36.329ms,
recovery raw126.919ms/source-corrected125.904ms. Added voice<=23.087ms and matched
speech pass; source offset<=3.525ms. DTLS positive/negative transport checks pass;
this is not a FrameCryptor/SFU acceptance claim. The series stops after this
first failure, with all original80ms/STOI0.005/level0.15dB gates retained.

Recovery marker37 arrives214.600ms after source although its scheduled timestamp
is43.761ms before source. Several next frames arrive8–16ms after source despite
the90ms receive default. This identifies both a late decoded output and an early
schedule; it does not yet prove which timing mechanism caused them. Investigate
RTP-to-local extrapolator recovery after the network pause rather than selecting
another fixed delay solely to pass. Exact media/logs retained locally.

Android job127013749249 compiles all3ABIs/AAR, then fails the actual policy check:
PeerConnectionFactory.class version65 (Java21) versus runner javac17/version61.
AAR and notices are retained, but no final build receipt or policy report was
produced. Fix the verifier to use the producer SDK JDK before the next accepted
candidate; do not fabricate successful CI evidence or rebuild rejected SDK5 just
for publication. Published Mac/Android remain62; physical acceptance is open.

The verifier now prefers the SDK producer JDK at third_party/jdk/current/bin,
with the existing host fallback for partial local source trees. On this Mac,
the exact downloaded AAR passes all9 actual builder cases using JDK21; a second
assertion check selects the producer JDK even when PATH supplies only the system
Java shim. This is local post-check evidence, not a replacement CI build receipt.
A separate predeclared diagnostic uses the existing timestamp-extrapolator
field trial hard_reset_timeout:2000ms, leaving SDK5 default90 and all gates intact.
It tests stale clock-fit recovery without another SDK rebuild or product change.

The2s timeout diagnostic also fails: raw recovery84.208ms, corrected86.245ms;
voice<=33.222ms and speech pass. It does not establish a sufficient fix. A second
predeclared diagnostic changes only the existing reset_full_cov_on_alarm trial,
leaving the10s timeout and90ms video policy intact. The pinned upstream source
explicitly notes that resetting only offset variance can affect frequency on a
delay spike. Expanded filtered native logs now also retain timing-reset alarms.

Full-covariance diagnostics1/2 pass unchanged P2P gates: raw recovery26.412/
68.532ms, corrected28.744/69.437ms; speech passes, added voice<=45.644/22.909ms.
The second starts the simultaneous ordinary reference first. These are the
existing SDK5 binary with an explicit supported field trial, not a new compiled
default or completed qualification. Third P2P and actual LiveKit AES-GCM series
are predeclared; stop on first failed gate. No app update is published.

Third full-covariance P2P diagnostic passes: clean raw51.763/corrected50.900ms,
recovery raw28.506/corrected29.407ms, voice<=22.295ms and speech pass. All three
predeclared P2P pairs pass. First actual LiveKit AES-GCM diagnostic now runs; its
speech comparison uses the retained historical SFU control and is labelled as
such. Final qualification still needs fresh compiled defaults, ordinary controls
and all mirrored/continuous-delay/platform/encryption checks.

First actual SDK5 full-covariance LiveKit diagnostic passes: clean raw23.745/
corrected24.602ms, recovery raw34.668/corrected35.577ms, speech passes against
the explicitly historical control. The missing-key stage receives126 audio/169
video packets while audio peak stays0 and decoded/video markers stay0; after key
installation checksummed video/audio speech decode and remain live at the end.
This is actual AES-GCM content evidence, not merely an enabled setting. Second
SFU diagnostic runs. Native compiler candidate SDK6/source1a22906 is isolated;
new actual C++/platform proofs and complete fresh media qualification still required.

Second SDK5 full-covariance SFU diagnostic FAILS: clean raw176.361ms/corrected
177.331ms; recovery raw40.619/corrected43.463ms passes. Clean speech STOI0.977676
versus historical control0.988594 differs by−0.010919 (>0.005). Missing-key and
positive actual AES-GCM controls still pass. SFU3/delay repeats stop without
being counted. This configuration is unqualified despite all three P2P passes.

Clean markers4..10 show audio source-to-callback282.535→167.846ms while video
is90.903–143.097ms and render schedules remain100.466–152.027ms. Audio then
returns95.342ms by marker11. Stats show4 concealment events/7183 concealed
samples/2400 silent concealed samples, packet-loss counter0; first SFU diagnostic
has no concealment. These observations identify an initial audio-delay excursion,
not proof of its cause or of a covariance regression. The speech control is
historical: fresh ordinary encrypted voice controls are still necessary.

A fixed90ms video cap cannot follow a transient~280ms audio playout delay. The
current SFU fixture also reports separate media streams, disabling the native
pair synchronizer. Investigate both real stream grouping and adaptive video
headroom rather than increasing fixed delay or capping/flushing natural audio.
SDK6 compiler test remains useful for clock-skew regression, but dependent binary
builds are scheduled for cancellation after that proof; no accepted media policy
exists. App62 remains. All absolute80ms and speech gates remain unchanged.

SDK6 actual C++ gate SUCCESS at run41964629040/source1a22906: all63 tests with
zero failures/skips, all11 original-behavior regressions fail before correction.
Exact source/toolchain receipt verifies. New clock recovery regression measures
22ms current/28ms future-estimate errors before, within1ms after; explicit
offset-only opt-out and all15 existing extrapolator tests pass. This proves a
clock recovery component, not a complete A/V solution. Dependent Mac/Android
build cancellation is requested after test completion because SFU policy failed.

New optional Mac fixture runs a simultaneous ordinary E2EE voice call in a
separate loopback room/PeerConnection pair, matching source clock/audio codec and
missing-key gate. Both encrypted publications are asserted; neither ordinary
endpoint publishes/receives video. It records separate PCM/stats and exact stats
times. Test room/join helpers only admit the two disposable names;4 helper tests
and unsupported-context guards pass. No production client behavior is changed.

First paired SFU capture reaches export but exceeds the old64MB loopback JSON
limit for two PCM streams, causing413/broken pipe. No timing or speech acceptance
is claimed for that attempt. Paired-fixture limit alone becomes128MB; single
stream contexts remain64MB. Original logs/failure receipt retained and repeat2
is running with the same media gates. Historical-control SFU2 failure remains.

First valid fresh ordinary-SFU comparison (label...diagnostic2, after export
repair) passes: clean raw77.739/corrected76.513ms, recovery raw54.852/corrected
53.958ms, voice excess<=22.770ms and matched speech pass. Separate audio-only
room/PeerConnections use actual E2EE; missing keys block both rooms' PCM while
RTP arrives, then decoded checksums/speech pass after key installation. Codec
parity and absence of ordinary video are asserted. Source clock interval is
1.994940–2.005305s/id, within the original invariant; source A/V offset<=5.762ms.
The historical-control absolute177ms failure is retained and keeps policy
unqualified. A second fresh ordinary comparison is running, rather than
promoting one good call or changing80ms/speech gates.

Fresh repeat3 aborts at the unchanged negative key gate: primary PCM peak
0.002990723 exceeds0.001 before key installation, video remains zero. No PCM/
decoder snapshot was retained, so neither decrypted speech nor a cause is
proved. Repeat4 passes clean corrected29.027/recovery43.936ms, voice/speech/AES
controls, but does not erase the failed attempt. A pre-key mute-cycle probe
passes silence gating then violates source-clock cadence at2.282458s/id; it is
not A/V acceptance. Its negative snapshot was not exported. Future mute-cycle
checks are explicitly negative-only and cannot count as positive media proof.

Additional native full-adaptive min0/max10000 plus full covariance P2P fails
recovery raw82.967/corrected83.779ms; speech and voice<=45.523ms pass. Its planned
adaptive SFU is not run after this failure. No accepted global policy exists.

A source audit finds a material fixture mismatch: call_probe, stream_controller
and screen_controller already set discardFrameWhenCryptorNotReady:true; the
marker fixture's four providers omitted it, selecting SDK default false. Earlier
SFU marker runs are diagnostics with this mismatch, not product acceptance.
The fixture now explicitly matches true and asserts each provider's actual
options. The0.001 peak limit and every media/speech bound remain unchanged; no
production crypto configuration, key, cipher or decoder is modified. New strict
negative-only mute control runs with retained synthetic PCM/decoder counters
on failure and native logs of known SFU injected frames. Hypotheses about blank
frames/comfort noise remain unproved; do not label this as a product data leak.
Both SDK6 platform jobs are confirmed cancelled, C++63/11 proof remains valid.

## 05.11: строгий повтор и отказ от фиксированной/совместной задержки

С точными продуктовыми настройками `discardFrameWhenCryptorNotReady=true`
первый свежий LiveKit/ordinary-voice прогон прошёл, второй отклонён:
clean raw86,248 / corrected87,175мс, recovery raw79,224 / corrected80,122мс.
Аудиозадержка около225мс одновременно возникла у видеозвонка и независимого
обычного аудиозвонка; видео около138мс. Добавленная голосовая задержка
не более22,448мс, речь и фактическая AES-GCM расшифровка проходят.
Это доказывает недостаточность фиксированной видеозадержки для этого
сценария, но не устанавливает причину исторического звонка на Xiaomi.

Диагностика min90/max10000 со штатной общей синхронизацией также отклонена:
clean corrected52,580мс, recovery raw363,384/corrected364,241мс,
добавленная задержка речи228,305мс и регрессия речи. Источник ≤5,726мс,
RTP живой, положительная и отрицательная проверки E2EE проходят.
Такую политику выпускать нельзя. Повторная сборка SDK6 run41970078061
отменена после этого результата; повторное использование C++63/63+11
подтверждено, новых платформенных библиотек нет.

Отдельный отрицательный mute-cycle с точными настройками прошёл:
до ключа PCM peak0, video0 при живом RTP обеих комнат. Декодер может
считать разрешённые SFU blank/SIF Opus-пакеты, выдавая нулевой PCM;
один счётчик декодирования не доказывает расшифровку речи. Это только
отрицательная проверка, а не квалификация полноценного звонка.

Следующий кандидат должен подстраивать видео под фактическую задержку
обычного аудио, не добавляя задержку речи и не сохраняя старый видеобуфер
после восстановления. Нативное объединение потоков нужно изолировать
от браузеров и незатронутых комнат; глобальный `sync_streams` не принят.
SDK7 пока не собран и не квалифицирован. Production full104 и клиенты62
не менялись; UA-08.C06 открыт.

## 05.11: SDK7 и локальная группировка — проверки продолжаются

Новый изолированный кандидат `codex/native-sdk-av-vc7`, source12249e2,
patch ed8e430c9ddc8e906545d559a5c34bbe892dd52d8987663434eb227e6ec114b1:
контроллер меняет только видеобуфер, используя оставшееся время до рендера,
эффективную видеозадержку, фактическую задержку аудио и относительную
сетевую задержку из RTCP. Он не добавляет аудиобуфер; устаревшие цели
сбрасываются при остановке/отключении потоков. Явные video min/max и режим
низкой задержки сохраняются. Неиспользуемое изменение интегрального
аудиоконтроллера удалено. Предусмотрено65 C++ тестов и13 отрицательных
регрессий; [CI41974316479](https://github.com/kerbermeister/voicechat/actions/runs/41974316479)
ещё выполняется. Первый запуск отменён до получения C++ результата:
исправлен только ошибочный ожидаемый счётчик64→65. Платформенные сборки
для этого этапа явно отключены, новых библиотек нет. Девять macOS
проверок конфигурации проходят на исходнике; это не проверка бинарника.

В клиентском кандидате добавлено только для нативных call rooms локальное
объединение subscriber msid по участнику, без глобального SFU sync_streams.
Идентификаторы дорожек, ICE, DTLS, кодеки и шифрование сохраняются;
браузер, publisher SDP, трансляции и отдельные screen rooms не подключают
эту политику. Связь MediaStream/track через msid описана в
[RFC8830](https://www.rfc-editor.org/rfc/rfc8830.html). Неизвестные и
конфликтующие форматы не переписываются. Четырнадцать Flutter тестов
и анализ семи затронутых Dart файлов проходят, включая два offer через
настоящий SDK обработчик и тестовый WebSocket. Добавлен Android sink
одновременного независимого ordinary-voice E2EE контроля; его нативная
компиляция и медиапроверка ещё не выполнены. Квалификаторы обеих платформ
подготовлены к свежему одновременному контролю и остановке после первого
отказа. Историческая речь для новой SFU приёмки больше не подходит.

Диагностика локальной группировки на прежней SDK5 подтверждает реальные
общие stream IDs/сохранение track IDs, но **отрицательный PCM gate не
прошёл** после mute/unmute до установки ключа: peak0,045319, 4 из332
10мс блоков выше0,001. Контрольная audio-only комната имеет peak0; video0,
RTP обеих комнат живой. В main audio145050 concealed samples; декодер
не нашёл ни одной контрольной DTMF метки. Это не доказывает ни расшифровку
речи, ни её отсутствие: причина ненулевого PCM ещё не установлена.
Порог не меняется, вариант не принят. SDK7 обязан заново пройти этот
отрицательный контроль перед любыми выводами о качестве/безопасности.

## 05.11, актуализация: знаковое смещение и строгая готовность SIF

CI41975448176/source3cd9dac выполнил65 C++ тестов:64 PASS, один отказ
без skips. `CorrectsExtrapolatorOffsetWithoutIntegralDrift` ожидал325мс,
получил300мс на первом обновлении. Нулевая обрезка отрицательного остатка
до рендера теряла часть коррекции. Расчёт упрощён: из фактического
аудиобуфера, знакового смещения packet-arrival относительно fitted RTP
clock и относительной RTCP задержки получается полный video target.
Ожидание325мс не менялось. Неготовая модель часов возвращает nullopt.

Прежний SDK5 без общей группировки также не прошёл строгий keyless
повтор: main peak0, ordinary voice0,002991; в332 main блоках реально
channels=1/stride=1. Поэтому проблема отрицательного PCM не объясняется
ни только группировкой, ни только чтением стерео. У Mac-стенда всё же
исправлена реальная ошибка: теперь чтение AVAudioPCMBuffer учитывает
stride. Точный helper проходит6 случаев настоящих AVFoundation буферов:
mono/stereo, interleaved/deinterleaved, Int16/Float32, неподдерживаемый
Float64. Предыдущие цифровые метки не подменяют физических измерений.

Два отдельных причинных опыта на SDK5 отключали только распознавание
служебного SIF trailer у получателей до ключа. Оба дают PCM peak0
в обеих комнатах и decoded0 при живом RTP. Ключи не установлены, AES
не отключался; это **только отрицательная диагностика с отличающейся
политикой SIF**, а не продуктовая/положительная медиаприёмка. Простой
изолированный libopus1.6.1 decoder даёт нули на3/80-byte blank packet;
он не является точным нативным декодером продукта и не доказывает причину
ненулевого PCM в NetEq. Вектор SIF/декодер подтверждён как требующий
проверки; расшифровка речи без ключа не установлена.

Кандидат теперь учитывает discardFrameWhenCryptorNotReady и для уже
разрешённых whitelist пустых SIF: до наличия ключа именно этого участника
пакет не передаётся декодеру. Старое поведение при false, whitelist, AES,
KDF и формат ключей сохранены. Покрыты отсутствие shared key, чужой
participant key и положительные случаи обоих режимов с index7. Удалён
неиспользуемый возврат вектора в старом асинхронном SIF тестовом helper,
чтобы не читать его параллельно записи transform task.

CI41978051269/source67c2b9e скомпилировал стенд, но не выполнил тесты:
при линковке не хватало RTPVideoHeader constructor/destructor. В harness
добавлен реальный target modules/rtp_rtcp:rtp_video_header. Новый точный
кандидат source27f134c, patch403132d8063e4b6dfcb7e9424282ca4f269f25282702b7f7d619d9f9a7e8e431,
19 проверяемых SDK inputs (16 изменённых файлов и3 неизменённых входа),
85 тестов/15 отрицательных регрессий;
[CI41979996000](https://github.com/kerbermeister/voicechat/actions/runs/41979996000)
выполняется. Платформенные библиотеки пока не собираются.

Flutter:15 тестов PASS и анализ8 файлов без замечаний. Нативная
группировка ограничена Android/macOS с новым SDK; iOS/Linux/Windows
и web её не включают. Kotlin sink свежего ordinary-voice контроля
проверяется отдельной compile-only задачей на старой SDK3, без устройства
и без сборки/квалификации APK. Дальше требуется новая библиотека,
отрицательные keyless и положительные actual AES/обычная речь/A/V
прогоны, затем подписанные обновления. Установленные клиенты62 и full104
в этой итерации не обновлялись.

Kotlin compile-only завершён успешно: Gradle/JDK21, source SHA-256
51ef7728d7c69addbd79f94e0e59339194962e737c01a863c3509cac460621ba,
266 задач (4 выполнены,262 актуальны). Первый offline запуск не разрешил
уже существующий integration_test runner1.2+ metadata; обычный запуск
разрешил зависимость без изменения исходников/lock. Это старый SDK3 cache,
без APK, эмулятора или физического устройства; не приёмка SDK7.

## 05.11, последний кандидат: устранено неопределённое значение strict-ready

CI41979996000/source27f134c запустил85 тестов:84 PASS, один отказ,
zero skips. Все65 timing/sync тестов и четыре новых SIF guard случая
проходят; legacy `ForwardsServerBlankFrameWithoutKeyAndStripsTrailer`
неожиданно блокировал кадр. Расследование выявило конкретную ошибку
SDK: ручной `KeyProviderOptions(KeyProviderOptions& copy)` не копировал
`discard_frame_when_cryptor_not_ready`. Поле оставалось неопределённым
при передаче options по значению в DefaultKeyProviderImpl и копировании
в options_. Это также означает, что Dart-level true сам по себе
не доказывал точное значение флага внутри нативного provider.

Вместо ручного перечисления полей используется стандартный defaulted
copy constructor с const-reference; move semantics отдельно не вводятся.
Новый тест проверяет false/true через прямое копирование и настоящий
DefaultKeyProviderImpl. Legacy ожидание не ослаблено. Теперь в suite86
тестов и прежние15 original-behavior negative regressions. Исходник
b29604eaa809dd0d55d1acd4ba321cfc3dfe2636,
patch14ba413327dfee7ad9e1b765b8097185319a22e9fd99d4cfaca6b23aea796530;
[CI41983111458](https://github.com/kerbermeister/voicechat/actions/runs/41983111458)
выполняется. Ни один неполный C++ прогон не объявлен квалификацией.
После полного PASS с точным receipt автоматически разрешена сборка
обеих SDK библиотек для последующих реальных медиаэкспериментов;
публикация приложения остаётся запрещена до прохождения медиагейтов.

## Пауза перед перезагрузкой компьютера, 05.11.2026

По явному запросу пользователя работа приостановлена. Монитор с автоматическим
запуском обеих SDK сборок остановлен; добавлен локальный pause guard.
Test-only CI41983111458 может завершиться в GitHub самостоятельно, но
новые SDK/platform jobs, публикации, деплой и установки автоматически
не запускаются. Клиенты62 и full104 остаются последними выпусками.
После команды «Продолжай»: прочитать сохранённый handoff, получить результат
этого точного86/15 прогона, проверить receipt/логи, затем продолжить
сборки и медиагейты. Неполный или неуспешный прогон не разрешает выпуск.

## 05.11, работа возобновлена: полный C++ прогон подтверждён

После команды пользователя «Продолжай» получен законченный
[CI41983111458](https://github.com/kerbermeister/voicechat/actions/runs/41983111458):
86/86 PASS, zero skips,15 отрицательных регрессий на исходном поведении.
Локальный verifier подтвердил точный manifest/source/toolchain receipt
для b29604eaa809dd0d55d1acd4ba321cfc3dfe2636. Исправление копирования
strict-ready bool проходит вместе с legacy SIF/AES и timing тестами.
Запущены обе SDK библиотеки в
[CI42006621067](https://github.com/kerbermeister/voicechat/actions/runs/42006621067).
Это компонентная проверка: реальный keyless/положительный E2EE,
сравнение речи с обычным звонком и A/V≤80мс на новых бинарниках ещё впереди.
Клиенты62 и production full104 не менялись.

Статическая подготовка межплатформенного отрицательного контроля выявила
ошибку стенда: Android receiver проверял source_audio, который создаётся
в отдельном Mac sender. Теперь прежняя проверка ≥50 меток/каденса1,8..2,2с
выполняется на источнике до его экспорта. Для keyless mute/unmute добавлена
nonce-scoped синхронизация sender/receiver; контроль не устанавливает ключи
и заканчивается до положительного звонка. Single-Mac путь сохранён.
Анализ Dart fixture проходит; межплатформенный runtime ещё ожидает SDK7.
Проверка повторного использования C++ evidence:6/6 Python тестов PASS,
включая отказ для других исходников, skips, дубликатов и отсутствующего
отрицательного доказательства. Четыре проверки безопасного восстановления
внедряемого стенда (Mac/Android, failure/concurrent edits) проходят.

SDK7 Mac arm64 собран в CI42006621067 и получен локально. Совпали19
source inputs, точный receipt и архив SHA-256
e2c357cec1e600a9688b8b01b81cc1125216b1abb7e7211e4b28f3af2591af3e.
Девять policy случаев PASS; проверены strict codesign, ссылки внутри пакета,
arm64, notices и UUID64c574a9-029a-3928-816e-90b2bb12dafe. Android ещё
собирается, SDK7 к клиентам не подключён; медиаприёмки нового бинарника нет.
Read-only production preflight подтвердил core/edge source da0dd92,
отсутствие pending операций и наличие rollback pointers. Core services healthy,
restart counts0; публичные каналы и установленный Mac остаются62.

Проверка настоящего call/call.cc (закреплённый WebRTC source) показала, что
Call::ConfigureSync связывает только первую A/V пару одной sync group.
Локальная SDP политика теперь сохраняет исходные связи участника, если
у него больше одной уникальной audio или video track; повторные SSRC/RTX
одной track не считаются вторым источником. Другие участники по-прежнему
группируются независимо. Это защита от влияния camera+screen/двух audio
на уже существующий сценарий, не заявление о синхронизации нескольких
пар. Новый тест проверяет обе разновидности, WMS, дубликаты SSRC и
идемпотентность. Изменений C++ SDK не требуется; его receipt остаётся b29604e.

Guard также исключает старые inactive/recvonly/rejected m-секции из новой
группы: после повторного включения камеры они не блокируют действующую
A/V пару и не занимают её sync group. Всего17 Flutter тестов PASS; анализ
изменённых двух Dart файлов без замечаний. Физическая и нативная
медиапроверка нескольких источников этим не подменяется.

SDK7 Android CI42006621067 завершился успешно: armeabi-v7a/arm64-v8a/
x86_64, затем9 реальных AAR initialization-policy случаев. При получении
проверены19-input source receipt, AAR SHA-256
c2a6de5e0f471e9426736418358c5174b9e9693e0280a5892be553e911f1bbb6,
classes.jar hash, notices и все три JNI ELF/hash. Теперь проверена полная
пара SDK7. Начата публикация immutable dependency prerelease для разрешения
зависимостей тестовых приложений; это не app release и не медиаприёмка.
Реальные keyless/положительный AES, речь/обычный voice и A/V≤80мс ещё впереди.

SDK7/default Mac: два свежих keyless mute/unmute контроля PASS. В обеих
комнатах PCM peak0, audio decoded0/video decoded0 при живом зашифрованном
RTP. Фактически встроенный UUID64c574a9-029a-3928-816e-90b2bb12dafe
подтверждён. Нет field-trial/SIF overrides; ключи получателям не установлены.
Это отрицательный контроль, не положительная медиаприёмка. Начат первый
полный encrypted SFU звонок со свежим одновременным ordinary-voice контролем.

Первый SDK7/default реальный encrypted LiveKit SFU звонок на Mac PASS:
clean18,468мс/raw и22,000мс/source-corrected; recovery64,979/66,095мс,
27 recovery checksum pairs, source max4,201мс. Свежий одновременный
ordinary-voice контроль: добавленная речь≤22,895мс, matched speech PASS.
Отрицательный gate до ключей и декодированные метки/речь после установки
ключей проходят на фактическом SDK7 UUID. Это1/3 SFU повторов; остальные
Mac/P2P и Android серии и app updates не завершены. Порог80мс не менялся.

Полная серия SDK7/default Mac SFU:3/3 PASS, каждый отдельный порог
сохранён. Recovery raw/source-corrected по прогонам:64,979/66,095;
76,758/77,694;63,305/61,443мс. Clean maxima≤62,513мс. Во всех трёх
matched speech PASS, added voice≤22,895мс и source timing≤5,448мс.
Первый/второй keyless отрицательный контроль также PASS, без диагностических
политик. Android keyless+SFU, обе P2P/остальные сетевые серии и подписанные
обновления остаются; physical/acoustic/display результат не утверждается.

Первый SDK7/default Android keyless cross-peer дошёл до PCM0/decoded0
при живом RTP в обеих комнатах, но **весь прогон не принят**: finally
вызывал Room.disconnect у не подключённого voiceAlice на receiver и
voiceBob на sender. Оба ожидали отсутствующее событие disconnect и
завершились TimeoutException. Сохранены raw media и failure-summary;
actual APK JNI SHA84d9855a259d9ce8e08da9efbb5b855ebd3a1e30ac175dbe2b86513472eed73e,
compiled Java initialization policy и sender SDK7 UUID проверены.
Очистка теперь ограничена подключаемой ролью, как у основной A/V пары;
затем dispose по-прежнему выполняется для всех объектов. Пороги/crypto
assertions не ослаблены. Анализ Dart PASS; запущены новые labels Android2/3
вместо перезаписи failed1, затем положительная SFU серия.

SDK7/default Android labels2/3 полностью PASS, включая sender/receiver
cleanup. В обеих комнатах PCM0/decoded0 при живом RTP. В обоих прогонах
получены настоящие native logs `dropping server injected frame before key`,
при неизменённых default flags (SIF/field-trial overrides отсутствуют).
APK JNI/Java initialization hashes и SDK7 Mac sender UUID совпали.
Среда: только собственный API35 arm64-v8a emulator/qemu1, не Xiaomi;
physical acoustic/display latency не измерялась. Failed1 не включён
в успешную серию. Начата положительная Android encrypted SFU серия.

Первый положительный Android SFU прогон завершился без экспорта; результат
по A/V/речи не принят. Отдельный повтор с crash log воспроизвёл настоящую
причину: java.lang.OutOfMemoryError в StandardMessageCodec.writeBytes →
NativeAVMarker result.success, запрос65044496 bytes при Java heap limit
201326592 bytes. Это сериализация двух полных тестовых PCM записей.
Новый snapshot/export читает Android PCM порциями≤128 блоков; Float32 байты,
все сэмплы, timestamps,120 stats, длительность и пороги сохранены. Mac legacy
API возвращает прежние данные. Общий reader переиспользуется SFU и P2P
receiver. Три Flutter tests PASS: byte-for-byte legacy,129+1 samples across
main/control page boundaries, отказ на invalid count/incomplete page.
Анализ3 Dart файлов PASS. Запущена новая Android SFU серия paged1..3;
оба прежних failed attempts сохранены, не входят в приёмку.

Android paged-export закончил реальный звонок/полную выгрузку без OOM,
но **не прошёл A/V gate**: clean raw200,267/source-corrected198,719мс;
recovery61,990/60,524мс, source≤2,257мс. Речь PASS, added voice≤0мс
относительно одновременно работающего ordinary control. Clean STOI обоих
потоков0,982289; данные совпадают. Ухудшение приходится на14–18с до
netem: audio/control jitter-buffer delta одновременно выросли с≈70 до
≈310–380мс, video decode time с≈3 до≈23мс и выросли dropped frames.
Причина timing spike пока не установлена, этот прогон не принят.
Для устранения собственной нагрузки рекордера54МБ PCM вынесены из ART
heap в direct buffers, сохранив сэмплы/время и bounded IPC pages. Следующая
отдельная серия direct собирает app GC/crash logs. Это диагностическое
исправление стенда, не утверждение причины A/V и не ослабление80мс.


### 05.11: Android direct и следующий кандидат синхронизации

Перенос PCM в direct buffers сам по себе не решил рассинхрон: следующий
полный Android SFU прогон дал clean raw198,010/source196,938мс,
recovery91,695/90,699мс. Добавленная задержка речи≤35,056мс, однако
clean STOI control0,990509/candidate0,980828 нарушил прежний допуск0,005.
Этот отказ сохранён целиком; серия остановлена на первом результате.
Порционная выгрузка теперь проверена4 unit-тестами; анализ3 Dart файлов PASS.

В точном исходнике JavaADM выходная задержка оценивается константой
150/2=75мс. AudioTrackSink стенда записывает PCM до аппаратной очереди;
следовательно, его время нельзя считать временем слышимого воспроизведения.
Это объясняет возможное постоянное смещение, но не доказывает причину пика.
75мс автоматически не вычитаются, исходные метки и допуски сохранены.
Диагностика `--native-output-clock` дополнительно записывает настоящие
AudioTrack presentation timestamps и позиции записанных фреймов через уже
существующий callback. Она не перенастраивает аудиовывод и не меняет PCM.

SDK8/source4375e11 отдельно проверяет решение по фактическому audio playout
RTP и его RTCP→NTP преобразованию. Видео получает deadline той же временной
шкалы с периодом200мс; свежесть потоков сохраняет отдельный срок2с.
Сглаженная оценка используется как fallback при отсутствии валидной свежей
позиции. Буфер речи, кодеки и E2EE не изменены относительно SDK7.
Добавлено7 C++ случаев, включая падение/рост очереди, устаревшую/будущую
позицию и RTP wrap. Ожидаются93 теста и21 отрицательная регрессия в
[42031354123](https://github.com/kerbermeister/voicechat/actions/runs/42031354123).
Это непроверенный кандидат; библиотеки и приложения SDK8 ещё не выпущены.


Пассивный AudioTrack-прогон `current14ba-output-clock-diagnostic1` закончен:
PCM raw clean111,003/recovery100,927мс (FAIL); индивидуальные presentation
timestamps дают max abs109,692/115,340мс (тоже FAIL). Восемь/24 пары;
измеренная очередь в этих парах≈95–131мс, медиана≈113–114мс. Речь относительно
одновременного control PASS. У эмулятора реальный output8000Hz, sink PCM48000Hz;
это не аппаратный тест слышимого качества. PCM не сдвигался, новый результат
не подменяет исходный. Подробный [контракт AudioTimestamp](https://developer.android.com/reference/android/media/AudioTrack#getTimestamp(android.media.AudioTimestamp))
отличает committed presentation от callback и не обещает физической точности.

При аудите источника найден ещё один дефект стенда: coherent-режим добавлял
маркерный кадр каждые2с к независимым20fps при ограничении encoder20fps.
Первый созданный кадр мог быть отброшен, а прежний журнал не различал,
какой кадр одного маркера пришёл. Теперь coherent-видео создаётся только по
аудиосчётчику ровно20fps. Четыре дополнительных бита номера кадра защищены
тем же checksum; оба получателя и scorer сверяют источник именно пришедшего
кадра. Пустая/неизвестная/неоднозначная связь отклоняется; regression guard
проверяет, что отброшенный onset не скрывает120мс source lag. Старые результаты
сохранены, новые серии обязаны содержать frame identity. Это исправление
измерения, а не доказанная причина пользовательского рассинхрона.


Исправленный источник прошёл реальный Mac→SFU→Android прогон: все53
доставленные видеометки имеют точный ID первого созданного кадра;
source≤2,203мс. Для SDK7 clean raw83,473/source82,620мс — всё ещё FAIL;
recovery44,085/43,026мс. Речь PASS во всех четырёх фазах, прежние STOI/level
допуски сохранены.18 Flutter-тестов и анализ4 Dart файлов PASS; Node4 и
restoration4 PASS. Новый Android journal также сохраняет callback/render
clock по аналогии с Mac; это тестовый код и не меняет релизное приложение.


Mac P2P pilot с новым источником: H264/Opus, source8,073мс, clean raw26,152/
corrected23,827мс, recovery31,779/34,435мс — timing PASS. DTLS-SRTP positive
и wrong-fingerprint negative PASS. Добавленная речь≤23,248мс, однако
recovery STOI candidate0,985515/control0,994460 нарушает0,005; весь pilot
FAIL. Первичная обработка control остановилась из-за перенесённых video-frame
IDs в audio-only metadata; исправлена только эта метаинформация, PCM/stats
и основной trace не менялись. Полный пересчёт исходных сэмплов дал указанный
speech FAIL, пороги сохранены. Оба отправителя имеют targetBitrate32000 и
одинаковые Opus fmtp/bytesSent; audio packetsLost0, но NetEq concealment/ускорение
есть в обоих потоках. Причина отличия речи ещё не доказана.

Перед выводом о регрессии от video-only контроллера заранее назначены два
контрольных прогона двух обычных audio-only вызовов с тем же источником и
обратным порядком запуска во втором. Это проверка вариативности измерения,
она не отменяет speech FAIL и не ослабляет допуск0,005/0,15дБ.


Оба заранее назначенных audio-only контрольных прогона завершены: речь
PASS во всех фазах с теми же допусками,63/62 checksum аудиометки у каждого
получателя, подтверждены две DTLS-SRTP сессии и wrong-fingerprint негативные
контроли. Это не позволяет списать предыдущую P2P speech regression на
доказанную вариативность контрольной пары. В проблемном видеопрогоне на
49–52с оба NetEq добавили≈0,4–0,5с concealment при packetLoss0, затем оба
ускоряли речь. В следующий диагностический прогон добавлена только запись
моментов10ms source audio callbacks в предварительно выделенный буфер:
она различит задержку создания/отправки синтетики и приёмного тракта.

SDK8/source4375e11 прошёл93/93 C++ теста, zero skips и21 original-behavior
negative regression. Точный manifest/toolchain receipt проверен из
42031354123. Обе библиотеки собираются в
[42034416556](https://github.com/kerbermeister/voicechat/actions/runs/42034416556).
До положительных медиапроверок это не обновление приложений.


### 05.11: переключение окон и тихие измерения

Владелец сообщил о расхождении при работе/переключении окон; платформу
этого отдельного эпизода не уточнял. Найден независимый дефект настольного
CallController: inactive/hidden выключали камеру, resumed запускал её снова.
Один переход между окнами фактически пересоздавал захват. Новая регрессия
на исходном коде упала на трёх desktop variants с операциями
camera:false,false,true,false вместо отсутствия переключений. Исправление
оставляет настольный захват активным. Mobile-политика ухода в фон и защиты
от отложенного camera(true) сохранены;11 controller tests и анализ2 файлов
PASS. Это ещё не реальный пользовательский звонок со сменой окон и не
доказательство единственной причины исторического lip-sync.

По просьбе владельца слышимый тестовый процесс немедленно остановлен;
прерванный pulse2 не принят. Все дальнейшие прогоны используют тихий вывод:
на Mac данные обнуляются в renderPreProcessing после индивидуальных PCM
sinks и перед выводом ADM; обработчик остаётся активным и при teardown.
На Android используется speaker mute тестового ADM. Системная громкость и
продуктовый звук не меняются, сами PCM/Opus/E2EE измеряются до этого места.
Mac quiet1 с реально исполняемым обработчиком закончен: silenced=true,
положительный PCM/64 checksum IDs, DTLS-SRTP и negative fingerprints PASS.
Весь quiet1: A/V raw clean33,183/recovery73,124мс, corrected30,865/74,261мс;
речь PASS, добавленная задержка речи≤45,171мс. Предыдущий speech FAIL сохранён;
один успешный диагностический прогон не заменяет всю квалификацию SDK8.

Записано12707 source callbacks, максимум между соседними12,143мс;
ни у источника, ни у приёмного PCM нет пауз>40мс в этом прогоне. Ранее
предполагаемый общий источник0,5с разрыва в нём не воспроизведён. Генератор
имеет source skew≤4,173мс. После намеренной потери video при восстановлении
одна метка пришла со следующим кадром (+51,491мс, recovery+1,79с, ещё до
5s guard). Новая проверка frame identity ошибочно считала этот сетевой
пропуск нарушением генератора20мс; исправлено разделение исходного onset и
точного доставленного кадра. Raw80мс продолжает учитывать полную стоимость
пропущенного onset. Порог не изменён, исходный trace не переписан; unit guards
принимают известный52мс пропуск при raw≤80 и по-прежнему отвергают raw150мс.


Полный текущий клиент/source1548f1e: flutter analyze PASS, flutter test
--concurrency=1:794 PASS/4 skip, без failures. Это Dart/widget/API-проверки,
они не означают исполнения ещё собирающихся нативных библиотек SDK8.
Python timing/artifact verifier11 и fixture restoration4 PASS.
Сверка с production/full104 da0dd92: этот commit — предок текущего источника,
серверные runtime/config пути не откатываются и не менялись; защищённые
SDK build/verification/test/vendor пути требуют штатного **full** выпуска.
Публикация ещё не выполнялась.
