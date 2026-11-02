# Локальный сетевой стенд звонков

OPT-02/14, только тестовые файлы. Обычный клиент, production-конфигурация,
профиль владельца и сеть Mac не меняются. Нужны локальный Docker с Unix socket,
toolchain проекта и внутренний браузер. Стенд сам браузер не запускает.

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
packages = json.loads(Path('.dart_tool/package_config.json').read_text())['packages']
sdk = next(p for p in packages if p['name'] == 'livekit_client')
source = Path(unquote(urlparse(sdk['rootUri']).path)) / 'web/e2ee.worker.dart'
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
