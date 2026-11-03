# Подтверждение установки ключа — работа после57

Кандидат1.19.10(58), ещё не выпущен. Production/установленный Mac —
1.19.9(57), sourcebcf92e2. Единственная пользовательская очередь —
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
patch не менялись; новый protocol epochs не включён. Production57 не менялся.
Перед выпуском нужны полный release
(vendor защищён fingerprint), нативные пакеты и штатное Mac-обновление.


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
