# Подтверждение создания и состояния крипторов

03.11.2026, опубликован1.19.12(60), после опубликованного59. Единственная очередь
пользовательской приёмки — [UA-05.C40](../../user-acceptance.md#ua-05).
Новый membership/key-epoch протокол не включён; это его обязательная предпосылка,
а не установленная причина исторических сбоев на iPhone/Xiaomi.

## Воспроизведение и исправление

Public E2EEManager setKeyIndex/setEnabled игнорировали false от native криптора,
enabled cache менялся до ответа. [Четыре native unit RED](native-unit-red.txt)
и прежний successful control воспроизведены на SDK59 с контролируемым RPC.
Patch проверяет bool, подтверждает cache после живых bindings и сериализует
параллельные toggle. Publication, появившаяся во время RPC, тоже обновляется.
[Семь unit GREEN](native-unit-green.txt) включают rejected/pending native reply,
новую publication и две конкурирующие toggle. Это тесты настоящего SDK с mock
платформенными ответами, без устройств, захвата или сети.

Batch не объявляется атомарным: при ошибке часть уже выполненных RPC могла
примениться; вызывающий получает отказ и не должен считать общее состояние
подтверждённым. Кеш остаётся последним подтверждённым. Штатный продукт не
выключает E2EE для восстановления связи.

[Реальный browser RED](browser-red.txt): GCM-проба сначала прошла16 слотов,
затем wrapper после dispose возвращал true и менял index/enabled cache.
Adapter теперь запрещает команды после начала dispose, ждёт matched ACK и
проверяет type/целевое значение до изменения cache. Dispose coalesced/awaited;
позднее завершение старого wrapper не удаляет запись нового с тем же track ID.

Создание криптора тоже await: иначе ScriptTransform event и обычный worker
message могли бы прийти в разном порядке. Worker подтверждает setup обеих
ветвей, возвращает sanitized error при отсутствии криптора/провайдера и не
проглатывает synchronous pipe setup failure. Проверяется locked stream до
подключения. Это ACK установки pipeline, а не доказательство первого кадра;
расшифровка проверена отдельно ниже. Runtime worker — именно
`vendor/livekit_client/web/e2ee.worker.dart`, штатный источник генератора.

## Настоящие браузерные проверки

[ScriptTransform](browser-script-transform.json): slots0–15,122 наблюдаемых
frames в первом green; финальный расширенный прогон124. Неизвестный ключ
блокирует decoding при продолжающемся encoding, поздний ключ восстанавливает
без нового receiver/SDP/ICE. После dispose все4 проверки отказа/кеша PASS.
Дополнительно8 PASS: неизвестный track для index/enable/codec/dispose, сохранение
index/enabled cache, sender и receiver constructor с удалённым provider.

[Encoded streams](browser-encoded-streams.json): старт со slot5,11 slots5–15,
90 наблюдаемых frames, те же controls/8 отказов PASS. API выбран удалением
ScriptTransform только внутри одноразовой loopback fixture tab; production
feature detection не менялась. Canvas synthetic, без mic/camera/account/SFU.
[Входы медиатестов](media-inputs.json) закрепляют SDK/fixture/worker hashes.
Worker ACK имеет прежний bounded5с deadline; новых бесконечных ожиданий нет.

[Browser SDK/worker/SFU](media-browser.json): missing key блокирует, после
установки9 кадров; старый sender продолжает15 при prepared slot, новая
publication ждёт свой ключ и даёт6; наблюдатель без decryptor оба counters0.
Full reconnect пересоздаёт transport и даёт7 новых frames. Только синтетический
canvas, локальный изолированный SFU; пользовательский аккаунт не открывался.

## Native и состояние выпуска

[Mac SDK/SFU](media-macos.json) — оба случая Base и test-only pinned sender
PASS, включая pre-native cryptor gate, prepared publication и full reconnect.
Native counters после запуска сами по себе не доказывают содержимое; ограничения
исходного стенда сохранены. Это настоящий Mac15.3.1/камера, без Matrix/account
или сохранения медиа. [Основной установленный59 восстановлен](owner-restored-after-media.json):
прежние account/device и выбранная старая QA-история, профиль/Keychain не очищались.

App analyzer и SDK worker/manager analyzer чисты; adapter сохраняет9 прежних
upstream info без ошибок/предупреждений.7 Python version/package unit и
check-version CLI PASS. Повтор полного Flutter:770 PASS/4skip; Android SDK тоже PASS. Выпуск завершён ниже.
Production web и нативные каналы60 опубликованы, установленный Mac обновлён59→60.

AES-GCM, ключи, ratchet/discard, доверие, отзыв, room rotation, codec и quality
сохранены. Физические iPhone Safari/PWA/Xiaomi, acoustic lip-sync и membership
protocol этим не приняты. Внешний backup interruption остаётся отдельной работой.

Основание порядка async ScriptTransform —
[W3C Encoded Transform, constructor](https://www.w3.org/TR/webrtc-encoded-transform/#rtcrtpscripttransform).


[Android API35 SDK/SFU](media-android.json): Base и pinned оба PASS;20/39
наблюдений до native sender cryptor с0 decoded, после ключа7/6 кадров, full
reconnect6/6. Capture только эмулируемой камеры на отдельном account-free
VoiceChat_KeyEpoch35; исходные assertions/deadlines и настройки сохранены.
Это не физический Xiaomi. Runner exit0; owned QEMU/ADB/SFU завершены после
пробы, системный профиль владельца не использовался.

## Первый полный прогон

769 PASS/4skip,1 FAIL: неизменённый route_coordinator wall-clock test измерил
4.116092с при требовании <3.5с. Порог и runtime маршрутизации не менялись.
[Запись отказа](initial-suite-failure.json) сохранена; изолированно тот же файл
прошёл12/12. Повтор полного набора без изменения runtime/test прошёл770/4skip за5м49с. Причина единственного
превышения по текущим данным не установлена, автоматически «flake» не объявлена.


## Выпуск и независимая проверка

Runtime source `a6fd29d2c064da9772544f4ca28f8e2747050733`, tag
`app-v1.19.12+60`. Защищённый vendor потребовал штатный full; baseline fingerprint
`0cdb16638d0f78350d31ab135b7eaf7e66a766fbbe0eccb324361235943bc933`.
[FULL100](https://github.com/kerbermeister/voicechat/actions/runs/41619538044)
SUCCESS19м24с; [CI236/tag](https://github.com/kerbermeister/voicechat/actions/runs/41619467186),
[CI237/branch](https://github.com/kerbermeister/voicechat/actions/runs/41619467627),
[CI238/main](https://github.com/kerbermeister/voicechat/actions/runs/41619467692) SUCCESS.

[Production](production-verified.json): core/edge commit и digests совпали,
rollback pointer точно прежний59, data identity сохранена, все службы healthy
с0 restart count. Актуальный main и worker проверены по HTTPS и реальным
контейнерам, новые ACK/ошибки присутствуют. no-cache/COOP/COEP, worker/wasm200,
приватные пути404, неавторизованные call API401. Оба нативных manifest/feed
совпали с проверенными пакетами. Это full: перезапуск core допустим и не
выдаётся за неизменность процессов WEB99. Перед подготовкой было0 активных leases.

Mac [пакеты](macos-package.json): строгая подпись, одинаковые285 файлов/ссылок
ZIP/DMG, bundle ID/feed/постоянный Sparkle key сохранены. Точный кандидат60
прошёл About и account/device/старую QA-историю без запроса Keychain. До него
[backup59](macos-backup.json):285 app entries/332 profile entries сверены,
Keychain не менялся. [Публикация](macos-publication.json) штатным publish_macos:
HTTPS feed и полные ZIP/DMG hashes совпали; процессы не изменились во время
публикации. [Установка59→60](macos-installation.json) штатной кнопкой:
[автоматический relaunch](macos-auto-relaunch.json) увиден по новому PID/plist60
до getApp. После —285 exact entries/codesign, прежние account/device/history,
длина прежнего draft и About60/latest-check PASS. Открытие старого аудио после
обновления отдельно не проверялось. Native UI в фоне иногда требовал Tab,
чтобы отобразить результат AX-действия; системные подтверждения не обходились.
Первое120с окно наблюдения закончилось на59% download; установка завершилась
автоматически за315с от pre-click записи. Это не ошибка/повтор установки.

Android [upgrade59→60](android-upgrade.json): исходный сертификат,
точный APK установлен без wipe на отдельном VoiceChat_Push_GMS35, аккаунт там
не сравнивался. [Preview опубликован](android-publication.json) по прежнему
разрешению владельца для удалённого Xiaomi. HTTPS manifest/полный APK hash
совпали, процессы и managed pointer при публикации сохранены. Physical acceptance
остаётся false; APK release media call на физическом телефоне не проводился.

APK SHA256: `3af1101b31af97ed232d24c34521e4120e0a213fa3bc0276bc4a9714fa078669`.
ZIP SHA256: `830caac38cce79ab4d36deb04a52f56ebf6351e7c12ccf3afec5f8db6f91693b`.
DMG SHA256: `84c9ab613572be686de26e9ba213b0b72c2d1e7f4475b479e8312aa4185411fd`.

Физические iPhone/Xiaomi, конечная A/V-синхронизация, membership epochs и
непрерывность daily backup не закрыты этим выпуском. Технические свидетельства
не образуют новую пользовательскую очередь; актуальные условия — в UA-реестре.
