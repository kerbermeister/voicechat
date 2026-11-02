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

Ограничения: один TURN namespace, симметричные помехи, короткий synthetic stream,
случайные потери без фиксированного seed. Это ещё не полный A/B48→50, не настоящие
Matrix DirectCall/LiveKit/E2EE membership, не физический акустический маркер и
не приёмка iPhone/Xiaomi. Для длительного/асимметричного испытания и групповой
нагрузки нужны следующие этапы OPT-02; текущий отчёт их не закрывает.

## Предварительная проверка групповых эпох

Нативный Mac проверяет GCM sender keys с default ratchet и16 разными slots,
рост decoded frames, блокировку прежним ключом и доставку нового после задержки,
без пересоздания cryptor/receiver. Материалы камеры остаются в памяти локальной
WebRTC-пары, без Matrix/SFU/аккаунта и сохранения кадров:

```sh
cd apps/client
flutter test integration_test/native_key_epoch_test.dart -d macos --dart-define=HARDWARE_CALL_TEST=true
```

Это не реализация membership protocol. Reuse slots, ACK/reordering, исключение
участника и совместимость платформ проверяются отдельно.

Негативный probe закреплённого OSS SFU использует имеющийся Python runtime с
aiohttp. Он создаёт только свою localhost-комнату/контейнер и одноразовые ключи:

```sh
.prototype/python/bin/python apps/client/tool/check_sfu_revocation.py --output .prototype/sfu-token-revocation-proof.json
```

Его успешный результат означает, что прежний JWT **принят после RemoveParticipant**.
Это ограничение, препятствующее простому отказу от общей ротации комнаты;
проверка не объявляет такой отзыв безопасным. Media decrypt этим probe не измеряется.
