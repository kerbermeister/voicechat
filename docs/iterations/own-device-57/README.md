# Приём на нескольких своих устройствах — кандидат57

1.19.9(57) опубликован03.11.2026, source`bcf92e2`. Web97, Mac56→57 и Android57
owner-preview опубликованы; проверены в описанных ниже пределах. Единственная очередь пользовательской приёмки остаётся
[UA-04.C22/C23 и C14](../../user-acceptance.md#ua-04).

Два controller red-теста на неизменном runtime56: после `acceptDirect` приглашение
уже удалено из списка. Доверенный own-device `m.call.hangup` или encrypted
presence `answered` искали только список и не завершали уже ожидающее принятие.
[Red](red-own-signals.txt). При дальнейшем уточнении локального57 найдены ещё3
предсуществовавшие ветки, до исправления каждой выполнен отдельный red:

- Настоящий `CallSession.terminate` выставляет ended, но ждёт `cleanUp` до вызова
  delegate. Удержанный cleanup оставлял public acceptance pending.
  [SDK cleanup](red-sdk-cleanup.txt).
- Push claim с `answered_elsewhere` вызывал обычный `DirectCall.close`, отправляя
  один room hangup от проигравшего устройства. Когда победитель ещё готовит
  answer, caller ещё не закрепил remote party и такой отбой может прекратить
  общий вызов. Counter hangups1 вместо0 подтверждён; живой проигрыш двух устройств
  ещё не воспроизведён. [API claim](red-push-claim.txt).
- Групповой `answered_elsewhere` завершал start, но оставлял приглашение для
  повторного ringing. [Group claim](red-group-claim.txt).

При уточнении обработки ошибок57 отдельный red также подтвердил: поздний сбой
cleanup старой попытки мог показываться во время подготовки следующей. Отчёт
теперь проверяет поколение попытки; текущая ошибка по-прежнему видна.
[Владелец ошибки](red-error-owner.txt).

Исправление обрабатывает отдельно ещё ожидающий incoming active: только своё
доверенное устройство, соответствующие room/session, без прерывания принятого
или connected разговора. Локальное завершение отмечает ended до await native
cleanup, чтобы поздний capture/SDP не возобновил попытку. SDK cleanup остаётся;
комнатный hangup не отправляется, reason answeredElsewhere не создаёт missed call.
На время принятия локальная подписка освобождает его Future уже при terminal
state, не дожидаясь SDK disposal; в finally она отменяется. Существующие проверки
поколения/владельца и свежая авторизация до микрофона сохраняются.

Ответ push теперь имеет3 внутренних исхода: accepted, unavailable и
answeredElsewhere. Последний закрывает только проигравшую direct-попытку или
убирает групповое приглашение. Обычная ошибка сохраняет прежнюю отмену caller
для direct и возможность повторить group; legacy call_not_found/fcm_unavailable
по-прежнему переходят к защищённой Matrix-сигнализации. API/схемы/ключи не менялись.

В первых100 адресных проверках PASS:54 voice комбинации (3 сигнала ×2 фазы
push/media ×9 вариантов trust/scope/ownership), API/direct/group и SDK cleanup,
плюс существующие callback/group регрессии. В финальный прогон добавлены12 video
комбинаций valid/connected и2 проверки владельца поздней ошибки. Метаданные encrypted событий и HTTP/RTC в тестах
синтетические; они не доказывают криптографическую или аппаратную межустройственную
приёмку. Финальный полный прогон746 PASS/4skip (4м31с), analyzer без замечаний,
8 version/package PASS. Прогон параллельно web build был остановлен при
давлении на память/диск без результата; после удаления только восстанавливаемых
intermediates финальный прогон выполнен отдельно с concurrency2.
Живой трёхклиентный повтор и выпуск описаны ниже. Физические iPhone/Xiaomi
ещё не проверены.


## Живой повтор:56 →57

03.11, обычный `main.dart`, Chromium во внутреннем браузере, настоящий локальный
Synapse и TURN. Caller и второе устройство Bob —56, первое Bob сначала56,
затем57. Новый Bob подключён штатным recovery и взаимной SAS-сверкой шести
совпавших эмодзи; независимое подтверждение показано на обоих устройствах.
Микрофон заменён только в output QA-сборки синтетической нулевой дорожкой.

На56 оба Bob получили звонок. Первый начал принятие с удержанным getUserMedia,
второй отклонил. Caller завершился, первый оставался «Ожидаем ответ» при повторном
наблюдении через7456мс. После ручной отмены поздний source остановился.
На57 тот же decline завершил первое принятие до возврата capture; первое
наблюдение terminal через2933мс включает время UI automation и доставки sync,
не является чистой задержкой обработки контроллера.

Первый Bob смог перезвонить **до возврата старого getUserMedia**. Оба UI перешли
в разговор. Вернувшийся старый source остановился, новый разговор сохранился
на обоих клиентах до0:48. После отбоя все2/2 Bob и3/3 Alice sources закрыты.
[Числовое свидетельство](live-ui.json), [red56](red56-waiting.png),
[green57](green57-callback.png). Это не акустическая оценка тишины, не аппаратный
iPhone/Xiaomi и не потеря сети/WAN. FCM в fixture недоступен; race push claim
answered_elsewhere отдельно проверен controller-тестом, живой claim не доказан.


## Выпуск и установка

- [Прогресс/CI](release-progress.json): CI227/228/229 SUCCESS на точном source.
  [Web97](https://github.com/kerbermeister/voicechat/actions/runs/41579464915)
  SUCCESS, release job16м27с. Protected backend fingerprint прежний, режим web.
- [Production](production-verified.json): immutable digests/source, HTTPS,
  no-cache/COOP/COEP, health, rollback pointer и401/404 границы PASS. Feed и APK
  совпали с кандидатами. Default screen policy не менялась; существующее
  администраторское включение на production сохранено.
- [Mac package](macos-package.json): точный личный подписанный ZIP=DMG285 entries,
  постоянный Sparkle key/feed/bundle ID, strict codesign.
  [Публикация](macos-publication.json) штатным publish_macos.py и HTTPS hashes PASS.
  [Backup56/profile](backup-before.json) до замены сверены, Keychain не менялся.
  [Настоящий56→57](macos-installation.json): агент нажал кнопку в установленной56,
  автоматический перезапуск57 наблюдён до любого ручного запуска. Installed285
  entries равны пакету, account/device по отдельности прежние, приватный hash
  совпал с pre52. Прежняя plaintext history видна; новое обновление не предлагается.
  Старое аудио после установки57 отдельно не проигрывалось. macOS15.3.1.
- [Android56→57](android-install.json): прежний сертификат, API35 emulator без
  wipe, установленный APK byte-exact. [Публикация preview](android-publication.json)
  для удалённого Xiaomi; physical_acceptance=false. Аккаунт/медиа на этом APK не
  проверялись. Нативный RTC54 не повторён57; loopback browser57 описан выше.

### Расхождение длинной baseline: ежедневный backup

Первая локальная серверная baseline была снята00:40 UTC, workflow97 начался
после04:40 UTC. Между ними systemd voicechat-core-backup.service успешно прошёл
03:30:03→03:30:33 UTC: он остановил и поднял control/Synapse; их IDs/images/
RestartCount прежние, StartedAt изменились. Исходная локальная baseline не
переписывалась. Fencing/verifying proofs самого web97 в защищённом rollout journal
совпали по всем трём core-процессам и совпадают с текущими; restart предшествовал
fencing. Поэтому подтверждено отсутствие рестарта **во время web-выпуска**, а не
за все четыре часа между локальными наблюдениями.

Этот плановый30с перерыв — отдельный риск устойчивости (OPT-16): backup останавливает
авторизующий control и Matrix; startup CallStore.recover ротирует комнаты.
Активного пользовательского звонка в этот момент не наблюдалось, влияние на
конкретный сообщённый случай не доказано. Нельзя просто отключить backup или
ротацию/recovery: дальнейшее решение должно сохранять согласованную копию и отзыв.
