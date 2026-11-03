# Подтверждение установки ключа — работа после57

Web1.19.10(58) опубликован штатным FULL98, source78a748b. Установленный Mac и
нативные каналы остаются1.19.9(57), sourcebcf92e2; подписанные58 проверены, но
не опубликованы. Работа приостановлена пользователем перед перезагрузкой.
Единственная пользовательская очередь —
[UA-05.C40](../../user-acceptance.md#ua-05), прежнее покрытие52 сохраняется.

В BaseKeyProvider точного локального SDK2.13.2 `setRawKey`/`setKey` записывали
latest sender index до await платформы и игнорировали false от rtc.KeyProvider.
Shared setter также заменял cached key до native успеха. Пять [red-кейсов](red-sdk-cache.txt)
подтвердили преждевременный slot, проигнорированный false, загрязнение cache при
исключении, pending shared key и сохранение ошибочного shared value после отказа.
Один контроль raw bytes/identity/slot уже проходил. Ошибка не доказывает, что
plaintext отправлялся; rejected install может оставлять недоступное encrypted media.

Локальный patch проверяет bool result и обновляет SDK cache только после успеха.
Прежние алгоритм, ratchet/slots, generation, trust, camera/microphone gates и
room rotation сохранены. API-сигнатуры и настройки не менялись; общий метод
покрывает group/screen/stream callers. Шесть unit PASS, полный752 PASS/4skip,
app/native-fixture/изменённый SDK analyzer PASS. Это проверка runtime57 с локальным patch; метаданные кандидата58 подняты
после неё. Финальный прогон с новым adapter override и метаданными58:759 PASS/4skip
(3м25с), app analyzer чист,8 version/package PASS. Итоги и hashes проверок —
[checks.json](checks.json). Media regressions Mac/Android/browser PASS ниже.

[Настоящий Mac15.3.1](native-macos.json) и [Android API35 emulator](native-android.json)
прошли по3 случая: false, exception, pending native reply. После отказа остаётся
confirmed slot0; retry/ответ переводит в1, native export равен синтетическому ключу.
Платформенные key providers настоящие, выбранный ответ MethodChannel injected;
аккаунт, микрофон, камера, сеть и SFU не открывались. Не выдаётся за RTP/акустическую
проверку. В Mac log есть предупреждение foreground, сами3 assertions PASS.
Android использовал отдельный account-free VoiceChat_KeyEpoch35, затем выключен.

Живой [browser red](worker-red.json): настоящий worker после удаления provider
возвращает error; hosted dart_webrtc1.8.2 принимает его как успех. Individual и
shared setters портят cache. [Green](worker-green.json) на том же fixture/worker
после проверки matched ACK: оба отказа переданы вызывающему, cache прежний,
fresh provider работает. Нет аккаунта, захвата/SFU/медиа.

Использована локальная копия той же уже подключённой1.8.2 с checksum старого lock;
[архив pub.dev сверён](dart-webrtc-source.json),34 скопированных файла неизменны.
Изменены9 key-provider await sites и извлечён pure-Dart WorkerResponse для7
проверок malformed/error/success; исходный import re-export сохранён для data
cryptor. Дедлайны5с и filters прежние.13 адресных PASS. Используются существующие
project lints; отдельный анализ adapter даёт9 info на неизменённых upstream
строках, ошибок/предупреждений нет. Адаптерные enable/index fire-and-forget этим
patch не менялись; новый protocol epochs не включён. На момент SDK-проб production57 не менялся; последующий FULL58 описан ниже.
FULL98 и проверка web58 завершены. Нативные пакеты готовы; остаются их
публикация и штатное Mac-обновление после возобновления.


## Native media: конфигурация приложения

[Mac SDK/SFU](media-macos.json) PASS, оба случая (Base и test-only pinned sender).
Поздняя доставка ключа:9/10 кадров после установки; прежний sender продолжал17,
новая publication использовала ожидаемый slot1/0, commit вернул7/19; full reconnect
пересоздал transport и дал9 кадров в каждом случае. Задержка sender constructor1с
с конкурирующим negotiate:50/51 наблюдений,0 decoded до native encryptor.
После startup decoded-counter наблюдателя2/0 сам по себе не доказывает содержание
кадра; прочие отрицательные/положительные проверки сохранены. Камера локальная,
media не сохранялись, A/V sync и физический телефон этим не проверены.

Сначала я запустил дополнительный test-only `requireFrameEncryption=true`, которого
нет в конфигурации приложения. Он дал0 frames и с patch, и с точным прежним
BaseKeyProvider57. [Диагностика](extra-native-flag-diagnostic.json): ключи на двух
сторонах совпали, у получателя0 framesReceived при приходящем RTP. Это несовместимость
дополнительного режима стенда, не установленная регрессия продукта. Авторитетные
native52 receipts также имели false. При повторе с текущей конфигурацией все
исходные assertions/deadlines и контроль до-крипторных кадров оставлены.
Продуктовые настройки шифрования не изменялись ради прохождения.

## Browser media

[Настоящий browser SDK/worker/SFU](media-browser.json) PASS: до ключа decoding
заблокирован, после ключа6 кадров; прежний sender продолжает13 при подготовке
нового slot1, новая publication снова заблокирована до ключа и даёт6 после него.
Sender transport при подготовке прежний; полный reconnect пересоздаёт его и
даёт6 кадров. У наблюдателя без decryptor оба counters0. Источник — синтетический
canvas, без аккаунта/камеры/микрофона и сохранения медиа; физический Safari/PWA
и акустический lip-sync этим не проверены.

## Android media

[SDK/SFU на Android API35](media-android.json) PASS, Base и test-only pinned case.
До native sender cryptor38/45 samples и0 decoded. После доставки ключа6/6 кадров,
старый sender при подготовке нового слота продолжает13/12; commit даёт7/31,
full reconnect пересоздаёт transport и даёт6/6. Алгоритмы/ratchet/gates прежние.
Первые попытки стенда не завершились из-за отсутствующего capture permission;
перед итоговым прогоном test APK установлен и CAMERA/RECORD_AUDIO выданы только
account-free VoiceChat_KeyEpoch35. Исходный двухминутный timeout и assertions
сохранены. После проверки guest выключен, собственный SFU удалён. Host emulator не завершился
за40с, поэтому wrapper exit1, сами SDK assertions/test exit0. При последующей
проверке host уже завершился самостоятельно, сигнал не отправлен.
Эмуляция
камеры не является проверкой физического Xiaomi, звука или lip-sync.


## Пауза перед перезагрузкой, 03.11.2026

Пользователь явно попросил паузу. Новую работу не запускать до «продолжай».
Это техническая точка продолжения, не отдельный реестр приёмки.

Сохранённый runtime source: `78a748bf8a8df0868711fb9d1ed97c5c14ee122d`,
main/ветка `codex/call-room-reconciliation`, tag `app-v1.19.10+58`.
Документальный checkpoint после него не требует пересборки runtime.

- [FULL98](https://github.com/kerbermeister/voicechat/actions/runs/41587072853)
  SUCCESS, job125754973660,18м1с. Режим full нужен из-за vendor fingerprint.
  Backend fingerprint `5b430922c9c23fca14a0b5d9b4d5052992b7708f817d53dc475105aec51209ae`.
- CI [230](https://github.com/kerbermeister/voicechat/actions/runs/41587032180),
  [231](https://github.com/kerbermeister/voicechat/actions/runs/41587032357),
  [232](https://github.com/kerbermeister/voicechat/actions/runs/41587087498) SUCCESS.
- [Production web](production-web-verified.json): core/edge source и image digests
  совпали; data identity сохранена, previous указывает на прежний release;
  здоровье, no-cache/COOP/COEP, worker/wasm,401/404 и присутствие обоих исправлений
  в опубликованном main.dart.js проверены. FULL может перезапускать core;
  неизменность процессов, как для web-only, не заявляется.
- [Mac58 кандидат](macos-candidate.json): personal/Sparkle с прежним ключом,
  source clean, ZIP/DMG285 entries одинаковы, codesign strict PASS. Кандидат
  действительно открыл сохранённый вход: account/device совпали с установленной57,
  старая читаемая история видна, About58 проверен. Старое аудио не проигрывалось.
  Кандидат закрыт; `/Applications/VoiceChat.app` всё ещё57. Перед паузой там был About57.
- [Android57→58](android-installation.json): exact signed APK поверх57 в
  VoiceChat_Push_GMS35/API35, без очистки. Исходный сертификат, source clean;
  account identity и реальный media call на release APK не проверялись.
  Эмулятор выключен; физического Xiaomi нет рядом.

Пакеты не пересобирать без новых runtime изменений. Всё ниже находится в
игнорируемом `.prototype` корня проекта и сохраняется при перезагрузке:

- Mac: `macos58-signed-candidate/{VoiceChat.zip,VoiceChat.dmg,appcast.xml,release.json}`,
  `macos58-unpacked/VoiceChat.app`; ZIP SHA256
  `01b1a195f74cf58c38d29a4955cc0d4a53dfb44dfebd442526eae8e6868943a1`, DMG
  `a680fcbdd8bce1f8b38dea1f095c36a06f51cdf06d7cd927b0de0e5be527a36c`.
- Android: `android58-candidate/{voicechat.apk,latest.json,release.json}`;
  APK SHA256 `fff478420d5b727a55d1fdeec4ed5c7c1164045bed820076dc74b18180ef9764`.
- `macos58-package-proof.json`, `macos58-identity.private.json` и
  `macos58-identities.private.json` (0600, значения не выводить) сохраняют
  сверку профиля для продолжения. Профиль/Keychain не очищать.
- Backup приложения57 и профиля: `VoiceChatRelease/backups/2026-11-03-before58`
  в Library/Application Support;285/333 entries сверены до работы58.
- Оба native worktree `heartbeat51-source` и `heartbeat51-android-source`
  остаются на чистом runtime78a748b. Локальные драйверы сборки/упаковки58 сохранены;
  готовые архивы и APK сохранены, удалялись только завершённые compiler outputs.

После команды «продолжай» сначала прочитать этот раздел и актуальный git status.
Сторонняя рабочая правка строки UA-18 сохранена и не включена в наши коммиты.
Затем:

1. Повторить read-only проверку текущего сервера драйвером
   `.prototype/verify-key-install58-production.py`; baseline/pointers не изменять.
2. Проверить сохранённые hashes/codesign и публикационные guards. Опубликовать
   точные пакеты штатными `.prototype/publish-macos58.py` и
   `.prototype/publish-android58.py` последовательно. Драйверы используют штатные
   publish_macos/android_release, постоянные ключи, HTTPS и проверку прежнего57.
   Если канал уже изменился, выяснить причину; не обходить guard.
3. Открыть установленный Mac57 через CUA, About → Check → Download/install.
   Проверить предложение58, установку кнопкой,285 exact entries, account/device,
   прежнюю историю и отсутствие следующего совместимого обновления.
   Системный Keychain, если запросит, подтверждает пользователь в системном окне.
   Из-за нескольких одинаковых bundle ID перед кликами помогало
   `performSecondaryAction(0,'Raise')`; UI-дескрипторы после reboot получить заново.
4. Локальный `.prototype/verify-installed58.py` готов, но запускать только после
   реального UI-обновления и записи `macos58-ui-proof.json`/приватной сверки after.
   Далее `verify-key-install58-production.py --with-native`, актуализировать
   эту запись, changelog и существующий UA-05.C40. Не закрывать физические проверки.

После выпуска продолжить прежний research backlog по приоритетам. Новый protocol
OPT-07 ещё не внедрён; доказанный плановый backup interruption — UA-05.C41/OPT-16,
не считать доказанной причиной старых телефонных просадок. Длительный A/V sync,
сетевые сбои и реальные iPhone/Safari/PWA/Xiaomi остаются открытыми в едином реестре.
