# Подтверждение установки ключа — работа после57

Web/macOS/Android1.19.10(58) опубликованы, source78a748b; установленный Mac
обновлён57→58 штатной кнопкой с сохранением профиля. Пауза перед reboot закрыта
командой пользователя «продолжай»03.11.
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
FULL98, публикация нативных пакетов и штатный Mac57→58 завершены ниже.


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


## Выпуск и установка после перезагрузки, 03.11.2026

Runtime source `78a748bf8a8df0868711fb9d1ed97c5c14ee122d`, tag
`app-v1.19.10+58`. Документальные checkpoint-коммиты не меняют runtime.
Пользовательская пауза закрыта явной командой «продолжай»; готовые пакеты не
пересобирались. Сторонняя рабочая правка UA-18 сохранена вне наших коммитов.

[FULL98](https://github.com/kerbermeister/voicechat/actions/runs/41587072853)
SUCCESS,18м1с; CI [230](https://github.com/kerbermeister/voicechat/actions/runs/41587032180),
[231](https://github.com/kerbermeister/voicechat/actions/runs/41587032357),
[232](https://github.com/kerbermeister/voicechat/actions/runs/41587087498) SUCCESS.
Защищённый vendor потребовал full, fingerprint
`5b430922c9c23fca14a0b5d9b4d5052992b7708f817d53dc475105aec51209ae`.

[Независимая production-проверка](production-verified.json) после reboot и
публикации подтвердила core/edge source и image digests, data identity, указатель
отката, здоровье, no-cache/COOP/COEP, worker/wasm,401/404 и оба исправления в
опубликованном main.dart.js. Native feed/manifest сверены по HTTPS.
FULL может перезапускать core; неизменность процессов относится к отдельной
публикации нативных каналов, а не к full-переходу.

[Mac-публикация](macos-publication.json) выполнена штатным publish_macos с прежним
постоянным Sparkle-ключом. ZIP/DMG/feed доступны по HTTPS, SHA256 совпали,
серверные процессы не изменились. Личный режим, строгая подпись,285 одинаковых
ZIP/DMG entries и [UI кандидата](macos-candidate.json) проверены до паузы.

[Установка57→58](macos-installation.json): старая установленная57 получила
предложение1.19.10(58),36.0МБ; агент нажал «Скачать и установить».
[Автоматический новый процесс](macos-auto-relaunch.json) наблюдался до ручного
обращения к приложению. Все285 установленных файлов/ссылок равны проверенным
ZIP/DMG, codesign strict PASS. Свежие account/device до/после совпали между собой
и прежним контрольным профилем; старая читаемая история доступна. About58 и
«Совместимых обновлений нет» проверены. Старое аудио после установки отдельно
не проигрывалось; профиль/Keychain не очищались.

[Android-публикация](android-publication.json) сохранила исходный сертификат и
проверенный APK. HTTPS manifest/APK exact; процессы и managed pointer прежние.
Это ранее разрешённый owner preview для удалённого Xiaomi, без фиктивной
физической приёмки. [Эмулятор57→58](android-installation.json) проверен до паузы:
exact APK, без очистки; account identity и release media call на телефоне не проверены.

Артефакты сохранены в `.prototype/macos58-signed-candidate`,
`.prototype/macos58-unpacked` и `.prototype/android58-candidate`.
ZIP SHA256 `01b1a195f74cf58c38d29a4955cc0d4a53dfb44dfebd442526eae8e6868943a1`;
DMG `a680fcbdd8bce1f8b38dea1f095c36a06f51cdf06d7cd927b0de0e5be527a36c`;
APK `fff478420d5b727a55d1fdeec4ed5c7c1164045bed820076dc74b18180ef9764`.
Backup приложения57/профиля до58 находится в Library/Application Support/
VoiceChatRelease/backups/2026-11-03-before58:285/333 entries сверены.
Приватные сверки0600 в `.prototype` не публикуются. UI после холодного запуска
начал отдавать Flutter semantics после Tab; при elementHasNoFrame помог клик по
видимому пункту на актуальном screenshot. Это ограничение UI-инструмента,
не воспроизведённая ошибка кнопки приложения.

Далее продолжается прежний research backlog. OPT-07 пока не внедрён; плановый
backup interruption — UA-05.C41/OPT-16 — не объявляется причиной старых телефонных
просадок. Длительный A/V sync, сетевые сбои и физические iPhone/Safari/PWA/Xiaomi
остаются открытыми в едином реестре.
