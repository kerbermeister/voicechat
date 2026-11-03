# Локальный сетевой стенд звонков

OPT-02/14, только тестовые файлы. Обычный клиент, production-конфигурация,
профиль владельца и сеть Mac не меняются. Нужны локальный Docker с Unix socket,
toolchain проекта и внутренний браузер. Стенд сам браузер не запускает.

Для содержимого зашифрованного A/V есть opt-in `?e2ee=1&rtp=1` у
`call_av_marker_fixture.html`. Перед запуском скопировать стандартные marker assets
и точный product `media_audio.js` в отдельный web-root; затем из корня репозитория:

```sh
mkdir -p /tmp/voicechat-av-web/worker-av
cp apps/client/integration_test/call_av_marker*.js apps/client/integration_test/call_av_marker_fixture.html apps/client/integration_test/call_transport_diagnostics.js apps/client/web/media_audio.js /tmp/voicechat-av-web/
dart compile js --packages=apps/client/.dart_tool/package_config.json -DDART_WEBRTC_WEB_WORKER_PREFIX=worker-av/ apps/client/integration_test/call_av_marker_e2ee.dart -o /tmp/voicechat-av-web/call_av_marker_e2ee.dart.js -m
dart compile js --packages=apps/client/.dart_tool/package_config.json vendor/livekit_client/web/e2ee.worker.dart -o /tmp/voicechat-av-web/e2ee.worker.dart.js -m
cp apps/client/integration_test/cryptor_av_worker.js /tmp/voicechat-av-web/worker-av/e2ee.worker.dart.js
cp apps/client/integration_test/cryptor_order_worker.js /tmp/voicechat-av-web/cryptor_order_worker.js
python3 apps/client/tool/call_network_lab.py --web-root /tmp/voicechat-av-web --output /tmp/voicechat-av-result.json --marker-seconds 120
```

Использовать закреплённый Dart проекта. Bridge подключает настоящую SDK factory,
4 cryptors, случайные32-byte individual keys и discard-unready; до SDP ждёт ACK.
Receiver msid различается только внутри loopback fixture. Отчёт A/V на сервере
сохраняет прежнюю строгую schema2; отдельный `E2EE_MARKER_PROOF` в UI содержит
только cryptor/crypto/order counters. Сохранить оба отчёта и SHA всех ассетов.
При A/B main/bridge/bootstrap/контент обязаны совпасть; меняется только compiled
SDK worker. Нельзя сравнивать только enabled-флаги без decoded tone/video markers.
`TRANSPORT_SETUP_PROOF` до закрытия peers сохраняет только allowlisted connection/
ICE states, candidate types и counters. getStats ограничен2с на peer; raw IDs,
адреса, credentials/SDP и тела media не сериализуются. Три privacy/failure tests:
`node --test apps/client/tool/test_call_transport_diagnostics.mjs`.

Дополнительный `&audio_fault=encrypt` или `decrypt` задерживает ровно один
настоящий WebCrypto audio result на500мс в начале delay-фазы, сохраняя bytes.
`audio_fault.delayed=true` и matchedCalls>0 обязательны для валидной пробы.
Новый arm не сбрасывает ordinals уже летящих кадров; повторный/неизвестный arm
отклоняется. Каждый прогон — свежая страница/worker. Синтетический sink остаётся
беззвучным; это не физический iPhone/Xiaomi lip-sync и не Matrix membership.

`--clean-only` разрешён только для A/V markers: все сетевые этапы используют
netem delay0 без потерь/обрыва, marker phase labels остаются `clean`. Длительности
и gain-переходы прежние; audio fault по-прежнему применяется в начале второго
временного этапа. Это позволяет отделить crypto stall от случайной потери пакетов.
Фактические profiles и qdisc counters сохраняются; такой прогон не доказывает
восстановление после настоящего сетевого обрыва.

Из корня репозитория:

```sh
docker build -t voicechat-network-probe:fixture -f apps/client/tool/call_network.Dockerfile .
cd apps/client
flutter pub get --enforce-lockfile
flutter build web --release --no-web-resources-cdn --target integration_test/call_renderer_fixture.dart --output ../../.prototype/call-network-web
cd ../..
python3 apps/client/tool/call_network_lab.py --web-root .prototype/call-network-web --output .prototype/call-network-udp.json --transport udp
```

Открыть выведенный localhost URL и нажать `Run renderer checks`. Нужен именно
жест на кнопке для Web Audio. Весь контент синтетический: canvas и беззвучный
осциллятор, без mic/camera/account/внешнего сигналинга. Используются настоящие
RTCPeerConnection, production renderer и allowlisted MediaStatistics.

Перед сетевыми этапами проверяются единый A/V stream, единственный audio path,
2с pause/resume,320→640 и ICE restart. Затем принудительный relay проходит:
clean6с → delay40мс6с → loss2%6с → loss100%3с → clean30с. Записываются51
interval samples. Netem действует на lo и eth0 только собственного TURN namespace;
40мс здесь не означает итоговый RTT40мс: пакет может пройти qdisc несколько раз.
`tc -s` перед сменой профиля сохраняет фактические очереди/дропы. `PASS` означает
восстановление RTP обоих видов по выбранному relay, а не доказанный lip-sync или
возврат задержки буфера к исходной. Эти величины нужно оценивать по отчёту.

Ctrl+C останавливает стенд и удаляет только его Compose-проект в `finally`.
Повторить с `--transport tcp --output .prototype/call-network-tcp.json` для
сравнения. После15мин стенд сам завершается; TURN credentials имеют тот же срок.
При аварийном kill машины/процесса удалить только напечатанный project командой
`docker compose -f <compose> -p <project> down --volumes --remove-orphans`
с напечатанными путём и именем, если временный compose-файл сохранился;
не применять глобальные prune/down к другим контейнерам.

POST ограничен loopback Host, Origin и случайным nonce; файловый сервер не выходит
за web-root, в том числе через symlink/encoded traversal. Секрет не попадает в отчёт.
Проверка границы ассетов:

```sh
python3 -m unittest discover -s apps/client/tool -p test_call_network_lab.py
```

При работающем стенде тот же набор проверяет Host/Origin/nonce и ошибочные POST,
не меняя текущий профиль:

```sh
CALL_NETWORK_LAB_ORIGIN=http://127.0.0.1:7390 python3 -m unittest discover -s apps/client/tool -p test_call_network_lab.py
```

Ограничения базового сценария: один TURN namespace, симметричные помехи, короткий synthetic stream,
случайные потери без фиксированного seed. Это ещё не полный A/B48→50, не настоящие
Matrix DirectCall/LiveKit/E2EE membership, не физический акустический маркер и
не приёмка iPhone/Xiaomi. Для длительного испытания и групповой
нагрузки нужны следующие этапы OPT-02; асимметричный UDP probe описан ниже; текущий отчёт их не закрывает.

## Предварительная проверка групповых эпох

Общий `integration_test/key_epoch_probe.dart` проверяет GCM sender keys с default
ratchet и16 разными slots, подготовку ключа без переключения sender, приём старого
slot после продвижения receiver index, блокировку неизвестного ключа и доставку
после задержки. Без пересоздания cryptor/receiver, SDP/ICE restart, Matrix/SFU,
аккаунта и сохранения кадров. Рост `framesDecoded` обязателен; одного флага E2EE
недостаточно. Нативная обёртка использует локальную камеру:

```sh
cd apps/client
flutter test integration_test/native_key_epoch_test.dart -d macos --dart-define=HARDWARE_CALL_TEST=true
```

Android запускается той же командой с `-d emulator-5554` только на отдельном
профиле с эмулируемой камерой и без аккаунтов. Перед `flutter test` собрать этот
debug target, установить его с `adb install -r -t` и разрешить только CAMERA для
`dev.voicechat.voicechat_probe`: тестовый runner удаляет пакет после прогона,
поэтому разрешение предыдущего теста может не сохраниться. Это не физический Xiaomi.

Браузерная обёртка `key_epoch_browser_fixture.dart` использует движущийся canvas.
Для неё достаточно заново скомпилировать LiveKit worker из закреплённого SDK
(Matrix/WASM/QR этот target не использует):

```sh
cd apps/client
flutter pub get --enforce-lockfile
python3 - <<'PY'
import json, subprocess
from pathlib import Path
from urllib.parse import unquote, urlparse
config = Path('.dart_tool/package_config.json').resolve()
packages = json.loads(config.read_text())['packages']
sdk = next(p for p in packages if p['name'] == 'livekit_client')
source = (config.parent / unquote(urlparse(sdk['rootUri']).path)).resolve() / 'web/e2ee.worker.dart'
subprocess.run(['dart', 'compile', 'js', '--packages=.dart_tool/package_config.json',
                str(source), '-o', 'web/e2ee.worker.dart.js', '-m'], check=True)
PY
flutter build web --release --no-web-resources-cdn --target integration_test/key_epoch_browser_fixture.dart --output ../../.prototype/key-epoch-web
cd ../..
.prototype/python/bin/python apps/client/tool/serve_key_epoch_fixture.py --web-root .prototype/key-epoch-web
```

Открыть `http://127.0.0.1:7394/index.html` во внутреннем браузере и нажать
`Run encrypted probe`; ожидается `PASS KEY_EPOCH_PROOF`. Повторить после полной
навигации с `?initial_slot=5`: новый cryptor начинает сразу с ненулевого slot,
активируются11 slots5–15. Сервер привязан к loopback, проверяет Host/границу
каталога и выдаёт COOP/COEP; остановить Ctrl+C. Его HTTP-проверка:
`python3 -m unittest discover -s apps/client/tool -p test_key_epoch_fixture.py`.

В loopback SDP только этого стенда receiver получает другой msid track ID:
web worker SDK индексирует cryptors по track ID, а два конца в одном процессе
иначе разделяют запись. Продуктовая сигнализация не меняется. Этот выбор не
объявляется дефектом реального межустройственного звонка.

Это не реализация membership protocol. Новая публикация во время prepare, reuse
slots, authenticated ACK/reordering, исключение участника, interop между разными
платформами и физическая приёмка проверяются отдельно. Обычный production web
собирается полным `prototype/build_web_assets.py` и target `lib/main.dart`.

## Реальное Web Audio усиление без слышимого тестового тона

После сборки browser fixture скопировать HTML в тот же каталог и запустить
loopback-сервер, описанный выше:

```sh
cp apps/client/integration_test/call_audio_gain_fixture.html .prototype/key-epoch-web/call_audio_gain_fixture.html
```

Открыть `http://127.0.0.1:7394/call_audio_gain_fixture.html` во внутреннем браузере
и нажать `Run gain probe`. Используется точный `media_audio.js` из web-сборки;
при проверке02.11 его SHA256 совпал с исходным production-файлом. Настоящий браузер
обрабатывает synthetic oscillator через MediaStreamSource/GainNode; инструментирован
только конечный выход: analyser и нулевой gain перед destination заглушают тон.
Проверяются PCM RMS при0→100→200→50→0%, один активный gain graph, muted исходного
проигрывателя и сохранение50% при замене DOM. Ожидается `PASS AUDIO_GAIN_PROOF`.
После прогона контексты/источник закрыты; для повтора перезагрузить страницу.
Это не RTP, не акустическая громкость/route iPhone и не A/V-marker/lip-sync.

Негативный probe закреплённого OSS SFU использует имеющийся Python runtime с
aiohttp. Он создаёт только свою localhost-комнату/контейнер и одноразовые ключи:

```sh
.prototype/python/bin/python apps/client/tool/check_sfu_revocation.py --output .prototype/sfu-token-revocation-proof.json
```

Его успешный результат означает, что прежний JWT **принят после RemoveParticipant**.
Это ограничение, препятствующее простому отказу от общей ротации комнаты;
проверка не объявляет такой отзыв безопасным. Media decrypt этим probe не измеряется.

## Раздельные направления Auto video

Тот же скомпилированный fixture поддерживает два UDP-сценария. Направление считается
относительно peer A (`sender` в коде), который отправляет и принимает A/V:

```sh
python3 apps/client/tool/call_network_lab.py --web-root .prototype/call-network-web --output .prototype/call-incoming.json --direction incoming
python3 apps/client/tool/call_network_lab.py --web-root .prototype/call-network-web --output .prototype/call-outgoing.json --direction outgoing
```

Запускать по очереди, завершив предыдущий стенд Ctrl+C. Два TURN listeners3478/3480
делят namespace, но имеют отдельные relay ranges. `u32` направляет в netem только
UDP-ответы одного listener на eth0, не loopback/hairpin и не трафик Mac в целом.
Сценарий: clean9с → loss15%18с → clean15с;42 samples обоих peers. TCP для этих
сценариев пока отклоняется, обычный симметричный TCP-тест сохранён.

Проверяются production `CallStatistics`, `outgoingVideoQuality`,
`StableCallQuality`, `applyVideoEncoding`; Auto обновляется раз в3 samples.
При incoming loss исходящий Auto/640 сохраняется; при outgoing loss видны
remote-inbound feedback, low/320 и затем возврат Auto/640. В обоих направлениях
проверяется восстановление audio/video RTP по relay. Не менее половины18 samples
должны действительно показать poor на испорченном пути; это защищает от ложного
PASS, когда netem не действует. Фактические samples и qdisc drops остаются в JSON.

Потери пока случайные, длительности номинальные: запрос профиля/getStats и ожидание
планировщика увеличивают реальное время. Synthetic canvas сжимается гораздо проще
камеры. Результат не доказывает экономию канала, физический lip-sync, отсутствие
долгого дрейфа, работу Matrix DirectCall или E2EE-группы на iPhone/Xiaomi.

## A/V-маркеры после product Web Audio gain

Только тестовые файлы, без Flutter-сборки. Перед сравнением сверить SHA256
копируемого `media_audio.js` с исследуемым опубликованным клиентом.

```sh
mkdir -p .prototype/call-av-marker-web
cp apps/client/integration_test/call_av_marker*.js apps/client/integration_test/call_av_marker_fixture.html apps/client/integration_test/call_transport_diagnostics.js apps/client/web/media_audio.js .prototype/call-av-marker-web/
python3 apps/client/tool/call_network_lab.py --web-root .prototype/call-av-marker-web --output .prototype/av-marker-short.json --marker-seconds 60
```

Открыть напечатанный URL во внутреннем браузере, нажать `Run A/V marker probe`.
60с: clean15с → delay10с → loss10с → offline3с → clean22с. Для120с начальный
clean20с, помехи по15с; при≥600с первый clean занимает1/6 всего времени.
`--marker-seconds 1800` —30мин, максимум3600. Credentials/аварийное завершение
namespace ограничены длительностью+120с; обычный renderer сохраняет предел15мин.

Каждые2с передаётся уникальный DTMF marker с checksum; изображение содержит
32-битный clock stamp с header/CRC8. Приёмник читает декодированные PCM после
текущего product gain и пиксели представленного кадра. Worklet инструментирует
только destination и выдаёт нули; raw element muted, второй audio path запрещён.
В памяти —1024 PCM samples и до600 временных видеометок; медиа не записываются.

`getOutputTimestamp()` переводит PCM sample time в performance clock;
`requestVideoFrameCallback().expectedDisplayTime` оценивает представление кадра.
Положительный offset означает более поздний звук. Это браузерная оценка, а не
внешний замер динамика/экрана. Ограничения:
[Web Audio](https://www.w3.org/TR/webaudio/#dom-audiocontext-getoutputtimestamp),
[video-rvfc](https://wicg.github.io/video-rvfc/#dom-videoframecallbackmetadata-expecteddisplaytime).

Предварительный порог80мс из исследования не подстраивается под результат:
`pass` требует достаточного числа markers и отсутствия превышения в initial
clean и после5с последнего clean. P95 сохраняется отдельно; максимумы доступны
из marker rows. Отрицательный результат тоже записывается. Колонки `markers`:
id, профиль, offset_ms, audio_output_ms, video_display_ms, source_ms, gain;
`phase_changes` содержит завершённые смены профиля. Нет подходящего video stamp —
marker учитывается unmatched.

Калибровка в отдельных свежих сеансах: `?control=audio200` и `?control=video200`
задерживают соответствующее содержимое на200мс. Измерение должно измениться
примерно на+200/−200мс относительно initial clean. Это явно помеченные отрицательные
контроли, не улучшение продукта. Потери пока без фиксированного seed.

Проверки: `node --test apps/client/tool/test_av_marker.mjs`, затем существующий
Python boundary suite выше, в том числе с `CALL_NETWORK_LAB_ORIGIN` до нажатия
Run. После правки JS скопировать assets и перезагрузить страницу; hot reload нет.
Ctrl+C удаляет только свой namespace. Стенд не заменяет Matrix/group E2EE,
физические iPhone/Xiaomi, seeded burst/reorder/rate и внешний lip-sync.

### Корреляция A/V с RTP-счётчиками

Для отдельного короткого прогона (не более300с) добавить к URL `?rtp=1`.
После сопоставленного маркера читаются настоящие sender/receiver getStats;
одновременно допускается один запрос, всего не более150 снимков. Никакого
изменения jitter target, caps, Opus, gain или кадров для этого не выполняется.
Параллельные тяжёлые задачи на Mac не запускать. Это корреляция с браузерной
оценкой, а не самостоятельное доказательство причины или физического lip-sync.

Новые отчёты имеют schema2; сервер сохраняет поддержку schema1. Дополнительные
поля: `rtp_diagnostics_requested`, `rtp_diagnostics_errors`, `rtp_diagnostics`.
Каждая строка последнего массива содержит:

1. ID маркера, начало getStats в performance clock (мс), длительность запроса (мс).
2. Массив14 входящих audio counters, затем такой же video-массив: packetsReceived,
   packetsLost, jitter, jitterBufferDelay, jitterBufferEmittedCount,
   jitterBufferTargetDelay, concealedSamples, totalSamplesReceived,
   insertedSamplesForDeceleration, removedSamplesForAcceleration, framesDecoded,
   framesDropped, totalDecodeTime, totalProcessingDelay. Недоступное — null.
3. Массив исходящего video: framesEncoded, framesSent, totalEncodeTime,
   frameWidth, frameHeight, framesPerSecond.
4. Массив selected pair: currentRoundTripTime, availableOutgoingBitrate;
   затем фиксированная категория qualityLimitationReason или null.

Строка имеет8 элементов: первые3 числа,4 массива и категория. Новые снимки
добавляют девятым числом source-time distance ближайшего video stamp от маркера
в мс (abs≤80); прежние8-элементные строки читаются с distance=null. IDs RTP/SSRC,
IP, SDP, URL, ключи и содержимое медиа не сохраняются. Общая граница POST500000байт
не повышена; типы, число/длина строк, уникальность marker ID, конечность чисел
и категории проверяются сервером. Counter delta вычисляется только при наличии
обоих значений и неотрицательном росте; при reset интервал пропускается. Средняя
задержка jitter buffer за интервал —1000 × delta(delay)/delta(emittedCount),
не lifetime average и не физическая задержка. Определения:
[W3C RTCStats](https://www.w3.org/TR/webrtc-stats/#dom-rtcinboundrtpstreamstats-jitterbufferdelay).

Контроль `?rtp=1&playout=element` направляет audio общего video element через
MediaElementAudioSourceNode/Gain в тот же беззвучный worklet sink. Источник
перехватывается до play(), прямого аппаратного тона нет. Это отдельный baseline,
не product gain: `playout_path=element_source_baseline`, описание и summary явно
помечены CONTROL. Обычный режим записывает `playout_path=product_gain`; старые
schema2 без этого необязательного поля относятся к прежнему product probe.
Если браузер выдаёт тишину для srcObject/MediaElementSource, результат сохраняется
как insufficient_markers; такой контроль нельзя считать измеренным lip-sync.
Нет автоматической смены пути реального приложения. Снимок RTP приходит после
распознавания всех4 символов: по clock явно сохраняется его фактическое время,
он не совпадает с первым аудиосимволом (в первом пробном прогоне на450–490мс позже).

Читаемая сводка и проверки её расчётов:

```sh
python3 apps/client/tool/summarize_av_markers.py .prototype/av-marker-short.json > .prototype/av-marker-summary.json
python3 -m unittest discover -s apps/client/tool -p test_av_marker_summary.py
```

Сводка также считает decode/encode time за интервал. Counter reset, missing и
нулевой denominator дают null. Не сравнивать эти интервальные средние с точным
моментом первого символа: завершение распознавания и getStats происходят позже.
