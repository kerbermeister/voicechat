# Порядок браузерного frame crypto после60

03.11.2026; задача OPT-02/08, единая очередь [UA-05.C42](../../user-acceptance.md#ua-05).
Baseline — exact published60 SDK/adapter `a6fd29d2c064da9772544f4ca28f8e2747050733`.
Выпущен1.19.13(61), только web, source2ce2666. FULL101/CI239–241 и независимый
production/HTTPS/UI PASS. Нативные каналы Mac/Android60 прежние. Ниже сохранены
промежуточные пробы, включая отклонённый последовательный прототип; текущий
worker — Green2. Общий A/V guard80мс и physical acceptance остаются открытыми.

Настоящие GCM peers, synthetic canvas,16 slots/late key/default ratchet. Только
первый результат настоящей WebCrypto операции задержан500мс, bytes не изменены.
Bootstrap наблюдает входной ordinal и enqueue того же JS frame/controller,
возвращает исходный результат callback без await/конверсии. Ключи, media body,
SSRC, track/account IDs и абсолютные timestamps не сохраняются. Delay501 отклоняется.

[Независимый decrypt RED](red-decrypt.json): оба callbacks возвращают non-Promise,
207/208 reads, первый delayed decrypt завершён после11 более поздних input ordinal.
Оба controller валидны; media probe прошёл16 slots, неизвестный ключ блокирует и
поздний восстанавливает. Fresh-page запуск фиксирован, повтор кнопкой запрещён.

Предварительная timestamp-only проба не доказывает receiver reorder: входные
RTP timestamps сами не обязательно монотонны. Смешанный ordinal trial подтвердил
encrypt reorder на8 позиций, но decrypt имел поздние кадры прошлого запуска и
3 controller, поэтому его instrumentation_valid=false и вывод по нему исключён.
Итоговые clean/encrypt/decrypt запускаются раздельно в свежих workers.

Локальный patch: вернуть crypto Future как JS Promise и дождаться обработки
одного frame перед следующим. Алгоритм, настройки и ключи прежние. Все6 Green controls пройдены:
clean/encrypt/decrypt отдельно на RTCRtpScriptTransform и encoded streams;
все callback возвращают Promise,0 backward input ordinal на обоих controllers,
16 slots/late key/disposed-command guards проходят. [Green inputs](green-inputs.json)
фиксируют побайтно одинаковые fixture main/bootstrap; пересобран только SDK worker.

Настоящий encrypted A/V-marker regression через SDK factory и exact worker
проверяется отдельно: Opus+VP8,4 cryptors, индивидуальные ключи, discard-unready,
local TURN/netem, продуктовый gain. Его результаты и выпуск ещё не завершены. С историческим личным звонком/physical
lip-sync этот дефект не отождествляется; physical iPhone/Xiaomi не проверены.

## Настоящий encrypted A/V baseline,120с

Одинаковые assets/bridge/bootstrap, только SDK worker различается
([red](av-red-inputs.json), [green](av-green-inputs.json)).4 cryptors, GCM
8668/8442 и8692/8466 encrypt/decrypt calls, decoded tone+video markers, не один
enabled-флаг. Netem40мс/2% loss/3с offline; gain100/50/200/100, synthetic sink silent.

| Worker | Markers/RTP | Initial/recovery p95 abs | Результат |
| --- | --- | --- | --- |
| [Исходный60](av-red120.json) |57/57|69.1/51.1мс|pass|
| [Локальный Promise](av-green120.json) |57/57|79.7/90.7мс|budget_exceeded|

Green сохраняет порядок на всех4 controllers и возвращает Promise на каждом
вызове. Однако A/V budget80мс превышен; его не меняли. Один A/B без fixed loss
seed не доказывает ни регрессию, ни отсутствие влияния. До сравнения повторов и
отдельного audio crypto stall выпуск удерживается. Предыдущие unencrypted
marker trials уже имели recovery65–159.4мс; это контекст разброса, не оправдание
нового результата. Browser estimates имеют ограничение калибровки±50мс и не
подменяют физический lip-sync. Новая fault-обёртка отдельно от order observer
проверяет один500мс audio encrypt/decrypt result без сброса ordinals mid-flight.

## Audio encrypt fault: исходный worker

[120с red audio](av-audio-red120.json):57 markers/RTP, p95 initial83/recovery89.7мс,
budget_exceeded. [Реальная GCM instrumentation](av-audio-red120-e2ee.json):
4 controllers, один audio encrypt result задержан500мс, matchedCalls5145;
старый audio frame enqueued после24 более поздних. Неверный и повторный arm
отклонены, ordinals не сбрасывались. Это независимый audio RED; исходный код
тоже превысил80мс, но влияние crypto stall и netem здесь ещё не разделено.
[Green-пара](av-audio-green120.json) завершена:56 markers/RTP, p95 initial206.9/
recovery115.7мс; budget_exceeded. [GCM counters](av-audio-green120-e2ee.json)
подтверждают один500мс audio encrypt result, matchedCalls5143,4 controllers без
backward ordinal и с Promise на каждом чтении; negative/repeated arm отвергнуты.
В initial участке до fault уже был206.9мс выброс; считать весь результат
последствием инъекции нельзя. Следующий reverse-order A/B использует clean-only
сеть и тот же audio fault; это отдельный диагностический контроль.

Равный loss seed пока недоступен в закреплённом image: Dockerfile использует
iproute2=6.1.0-3, [его upstream parser](https://github.com/iproute2/iproute2/blob/v6.1.0/tc/q_netem.c)
не содержит seed option. [Текущая upstream документация](https://github.com/iproute2/iproute2/blob/main/man/man8/tc-netem.8)
описывает seed для воспроизведения loss/corruption. Toolchain/kernel поддержку
нужно проверить отдельно; seed не объявлялся включённым и image не обновлялся.
Одинаковый seed сам по себе также не фиксирует scheduling/packet cadence Mac.

Завершённый red4532228e93 lab начал cleanup по собственному lifetime timer;
последующий Ctrl+C прервал down. Оставшиеся только его2 контейнера и network
удалены после проверки точного Compose project label; чужие контейнеры не тронуты.

Таймер green9d980352b6 завершил штатный cleanup: оба контейнера/network удалены,
process exit0. Clean-only режим server принят15 unit (1skip без live nonce),
Node module syntax PASS. В нём netem profiles все delay0, без потерь/обрыва,
marker labels clean; это не новая проверка сетевого восстановления.

## Пересмотр первого прототипа

Clean-only serial audio [Green](av-clean-green120.json):59 markers, initial138.4/
recovery100.6мс, отдельные fault offsets502→398.4→243.3→100.3→17мс. Поэтому
первый Promise-прототип не публикуется: корректный порядок не оправдывает
накопление audio playout delay. Обратный [red](av-clean-red120-incomplete.json)
завершился на guard selected TURN pair, до markers (0); не A/B sync результат.
Причина раннего отсутствия пары не доказана. Стенд теперь ограниченно ждёт
появления selected pair до15с, затем по-прежнему требует фактический relay.

Следующий локальный вариант Green2: video ждёт crypto Promise, independent
audio packets обрабатываются параллельно (до32 незавершённых работ), late
completion после более нового emitted ordinal отбрасывается. Flush ждёт
незавершённые работы, ошибка освобождает slot. Ключи/шифр/ratchet/битрейт прежние.
[4 unit assertions и анализ](audio-queue-unit-checks.json) PASS, реальный worker
скомпилирован. [Inputs](green2-inputs.json); exact прежний video fixture main.
[AV red2](av-red2-inputs.json)/[green2](av-green2-inputs.json) имеют одинаковые
assets/bridge/bootstrap; различается только actual SDK worker. Browser regression
и качество Green2 ещё не приняты, новой версии/публикации нет.

### Green2 audio encrypt / clean-only,120с

[Реальный отчёт](av-green2-clean120.json), [SDK/GCM proof](av-green2-clean120-e2ee.json):
59 markers/RTP,4 ordered controllers, Promise на каждом callback; ровно один
late audio frame не передан writable (6267 reads/6266 writes), остальные3
controllers без drop. Fault500мс действительно применён, matchedCalls5191;
unknown/repeated arm отвергнуты. Actual netem profiles0ms, qdisc drops0.
Возле fault offsets43.6→152→56.2→18→11.6мс; накопления502→398→243мс первого
прототипа нет. Одна пара ещё не доказывает равенство качества на всех устройствах.
Initial/recovery p95 abs89.5/88.6мс, budget80 не пройден и не изменён.
Red2 сравнение и приёмный audio fault ещё ожидаются; публикации нет.

### Завершённая same-assets reverse-order pair

[Red2 clean-only](av-red2-clean120.json):60 markers/RTP, initial69.7/recovery82.9мс,
budget_exceeded. [Crypto proof](av-red2-clean120-e2ee.json): один audio reorder
на25 input ordinal, Promise0. Green2 выше:59 markers,0 reorder, ровно один late
frame dropped,89.5/88.6мс. В обоих actual qdisc drops0; все assets/bridge/observer
одинаковы, меняется только SDK worker. Общий80мс критерий не закрыт; head-of-line
хвост500мс первого прототипа в Green2 не повторился. Вывод не переносится на
physical Safari/PWA/Xiaomi или исторический личный звонок.

Green2 video regression завершена:6 fresh-page cases clean/encrypt/decrypt ×
ScriptTransform/encoded streams. Все instrumentation_valid/media_probe_completed,
16 slots/late-key/unknown-key/disposed guards PASS,0 backward ordinal, Promise
на каждом callback. [Modern decrypt](green2-decrypt.json),
[legacy decrypt](green2-legacy-decrypt.json). Наблюдались разные receiver read
counts при ключевых переходах (например legacy encrypt1994 reads против227
sender reads); encrypted-loopback input/retransmission/ratchet counters требуют
отдельной классификации и не объявляются причиной старого разговора.

### Green2 audio decrypt / clean-only120с

Первый [запуск](av-green2-decrypt120-incomplete.json) имел deadline video playout,
0 crypto calls/0 markers. Это setup_failed, исключён из оценки качества. Его
transport states и начальный TTL не были сняты; причина не объявляется известной.
Свой project1af98b767d штатно удалён таймером, process exit0.

Для повтора добавлены allowlisted transport diagnostics (3 Node tests PASS)
и проверен запас TURN TTL182с перед120с пробой, без записи credentials.
[Повтор](av-green2-decrypt-diagnostic120.json):60 markers/RTP,4 ordered Promise
controllers, ровно один late decrypted audio frame dropped. Fault500мс применён,
matchedCalls5152; оба peers connected и фактические relay→relay. Возле fault
offsets33.3→38.6→44.8→27.9→42мс,500мс хвоста нет.
P95 initial77.3/recovery75мс, но [строгий guard](av-green2-decrypt-diagnostic120-guard.json)
требует abs≤80 у **каждого** baseline/recovery marker: один recovery97.8мс,
поэтому outcome budget_exceeded сохранён. Не сводить этот guard только к p95.

Версия61 подготовлена как web-only: [scope vs native60](release-scope61.json).
Общие проверки/штатный FULL и HTTPS ещё не завершены. Mac/Android60 получают
прежние подписанные пакеты; новый native выпуск для web worker не требуется.

## Candidate61 общие проверки

[774 Flutter PASS/4skip](candidate61-checks.json),6м10с wall time; общий analyzer
No issues found,8 version/package +check-version CLI PASS.15 lab unit(1skip
без live env),3 transport privacy/failure Node и3 marker decoder Node PASS.
Полный Flutter raw log остаётся в .prototype, SHA сохранён; это не physical
acceptance. После измерений в Dart fixture добавлены только braces для lint;
compiled A/B fixture main остаётся точной исходной парой. Worker/core checks
относятся к текущему production patch; никаких зависимостей не обновлено.

## Выпуск61 завершён03.11.2026

[FULL101](https://github.com/kerbermeister/voicechat/actions/runs/41639694125)
SUCCESS19м03с, CI239/240/241 SUCCESS (tag/branch/main, одинsource2ce2666).
[Независимый production receipt](production61-verified.json): commit/digests/
backend fingerprint42b5a057…/health0 restarts/data identity/previous60, actual
main+worker bytes/patch markers, HTTPS200/401/404/headers PASS. Screen default
off прежний, существующий admin flag1 сохранён. FULL может перезапускать core;
до подготовки было0 активных leases, непрерывность активного звонка не заявляется.

[Обычный web UI](web61-ui-verified.json), не lab target: About1.19.13(61),
сохранённая сессия открыта без нового входа, прежняя QA история видима. Account/
device IDs отдельно не сравнивались и не сохранялись; screenshot содержит только
About, без переписки. Нативные feed/manifest60 совпали с прежними подписанными
кандидатами, новой установки native не требуется. Старые native60 проверки не
выдаются за физическую приёмку iPhone/Xiaomi или свежую нативную установку61.

H01 source-identity control выполнен независимо во время remote build: оба
варианта не прошли80мс, изменение не принято в runtime. [Результаты](../call-av-markers-2026-11-03/stream-source/).
