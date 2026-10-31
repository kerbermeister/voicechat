# Пользовательские исправления30.10.2026

Исходная интегрированная ветка: main48ac62c. Работа в чистом main worktree
`calls-release`; чужие dirty worktree и `three-vps-rollout` не изменяются.
[Требования](../tasks/22-chat-followups.md), [приёмка](../user-acceptance.md).

## Проверено до доработок очереди, P2P и фото

-429 unit/widget PASS,4 opt-in skip; flutter analyze без замечаний.
- Настоящий Synapse в изолированном Docker `--network none`: peer с уровнем0
  закрепляет/открепляет общее сообщение. Меняется только отсутствующее правило
  `m.room.pinned_events:0`, остальные power levels неизменны. Чужой пользователь,
  группа и явно настроенное ограничение отклоняются. Read-after/restart не сломаны.
  Использован прежний pinned digest97665cd4539dcf107c69fb6afdb720e1d1c9c09fb2b5701fb13d6c33b22cd8f0.
-7 Python policy tests PASS.
- Реальная камера macOS15.3.1:3 сценария PASS — выключение при ошибке сигналинга,
  завершение после очистки SDK feed и завершение во время подключения sender.
  Разрешение/поздний sender дополнительно моделируются6 unit-тестами.
  Тест вызывает настоящий native getUserMedia/trackDispose, проверяет исходный
  контейнер и порядок освобождения. Аккаунт, профиль, микрофон и сеть не используются.
  Это не проверка удалённого звонка и не визуальное наблюдение общего системного LED.
- Причина камеры: остановка выполнялась после сетевых операций; исходный поток
  камеры удалялся после переноса трека. Darwin находит capturer через native streams:
  после очистки SDK feed такой трек мог остаться без владельца. Теперь source живёт
  до stop, поздние завершения guarded, hardware освобождается до сигналинга.
- Реальный захват экрана macOS15.3.1: кадры с ненулевыми размерами, без аудио;
  публикация не уничтожает root capture, остановка освобождает native stream — PASS.
  Ошибка UI вызвана whitelist только Android для native. Desktop теперь использует
  существующий SDK; viewer не зависит от capability захвата своего устройства.
  Нативный iOS broadcast не реализуется; web определяет getDisplayMedia по API.
-18 screen regression tests PASS; реальные iPhone/Android/Windows/Linux не проверены.
  Изменения не являются доказательством E2EE расшифровки экрана на iPhone.
- Визуальный fixture390/1000px: рамка с отступами и направление звонка PASS.
  [Снимок](chat-followups-2026-10-30/frame-and-call-phone.png), данные вымышленные.

## Продолжение

Владелец добавил ограничение автоматической очереди отправки, сохранение/историю
P2P, HEIC/размер фото iPhone и команду сохранения всех файлов.
Разрешена последующая полная интеграция, локальное обновление, production и
необходимые клиентские выпуски; прежняя отсрочка публикации отменена.
Результаты последующих проверок и выпуска дополняются после выполнения.

## Вторая часть: очередь, P2P и фото iPhone

Версия1.15.0(30), исходный main48ac62c + checkpoint3e8f417.
Все13 follow-up изменений реализованы. Публикация ещё не выполнена.

- Outbox: deadline хранится в encrypted local store и отсчитывается Timer во время
  сеанса; legacy created используется после reopen. Просроченное остаётся на месте
  сLOCAL_SEND_TIMEOUT, автоматические попытки не возобновляются на следующий день.
  Явный повтор сохраняет Matrix txid; поздний ack снимает pending. Новые сообщения
  обходят приостановленные старые. Уже принятый сервером запрос отозвать таймаутом
  невозможно; это явно написано в детализации. Подготовка/загрузка не означает
  разрешение публиковать ключи после остановки.
- P2P: даты стабильны при изменении статуса, ExpansionTile скрывает детали.
  ZIP64 со stored entries, CRC32 из уже подключённого archive4.5.2; файлы не
  собираются целиком в RAM и не пишутся в plaintext temp. Локальный checksum-pass
  обеспечивает seekable диапазоны, затем экспорт читает encrypted source блоками.
  Регистрация streaming worker остаётся до100ГБ; лимит не повышался.
- iPhone save: до64МиБ native Web Share с понятным ready-dialog и свежим gesture,
  результатshared не выдаётся за доказанную запись на диск. Отмена/ошибка возвращают
  управление. Крупные файлы идут attachment/octet-stream через прежний worker.
  Recovery-key export по-прежнему не проходит через worker.
- HEIC/JPEG web: Blob→native browser decoder→canvas JPEG; metadata не копируется,
  source64МиБ/64Мп и финальная политика соблюдаются. Нет серверного конвертера.
  [WebKit оHEIC вSafari17](https://webkit.org/blog/14445/webkit-features-in-safari-17-0/).

Проверки второй части:
- `prototype/check_chat_followup_web.cjs`: настоящий Chrome, отдельный context,
  native-share API заменён stub; ready/cancel/возврат, безопасное имя и настоящий
 65МиБ download с4МиБ reads, cleanup PASS. Это не физический iPhone.
- ZIP64 тест: декодирование с CRC, Unicode/повторы/пустой файл, диапазоны по7байт,
  central directory, отмена/обрезанный source PASS.
- Native Safari18.3/macOS15.3.1: собственный synthetic HEIC и48MP JPEG успешно
  стали64×48 и4000×3000 JPEG, corrupted input rejected; media upload отсутствует.
  Результат сохранён рядом с этим журналом, без аккаунтов/пользовательских фото.
- Общий клиентский прогон, анализатор и итоговые сборки фиксируются ниже после
  завершения. Аппаратные ограничения и пользовательский остаток — только
  [единый реестр](../user-acceptance.md).

GitHub release пока ждёт входа: CLI HTTPS credential отсутствует, доступный Safari
не авторизован, инструмент не получил доступ к Chrome. SSH production read-only
доступен. Штатный FULL workflow не заменялся ручным compose.

Дополнительно закрыта граница SDK: `sendFileEvent` принимает необязательный
`beforeSend` после upload и перед публикацией. Outbox повторно проверяет deadline,
отмену и получателей; до этой границы upload можно отменить. Два теста проходят
через настоящий код SDK (slow upload→guard denied/allowed); отдельный outbox-тест
проверяет callback и отмену. Старые SDK-вызовы без guard совместимы.

Закрытый Mac29 и профиль сохранены и сверены до подготовки30; Keychain не менялся.
Существующие локальные PostgreSQL/Synapse volumes также сохранены в закрытой
резервной копии; runtime настроек/SQLite скопирован без повторного seed.
Публичный routing key взят из опубликованного main.dart.js и подтверждён настоящей
Ed25519-подписью текущего HTTPS route catalog; новый ключ не создавался.

Production `/api/config` проверен read-only:10файлов по5ГБ,4получателя. Весь
разрешённый набор (до50ГБ) помещается в один ZIP с существующим100ГБ пределом
worker. Поэтому повышение ресурcного лимита для запрошенного save-all не нужно.

## Итоговая проверка исходников30

- Полный Flutter-прогон: **439PASS,4opt-in skips**, concurrency1.
- `flutter analyze`: **No issues found**; `pub get --enforce-lockfile` PASS.
- Backend policy:7PASS. macOS packaging/publication tests:9PASS.
- Повтор итогового браузерного save-прогона65МиБ: PASS.
- `android_release.py check-version`: PASS; текущий HTTPS macOS feed содержит29,
  следующий подготовленный номер30. Это ещё не публикация/установка30.
- Нет физического iPhone/Android; native Mac camera и screen проверены отдельно
  выше. Остаток и условия — в едином реестре приёмки.

## Финальный кандидат31 (31 октября)

Непубличный30 не устанавливался в `/Applications` и не публиковался. При финальном
просмотре найден забытый `unawaited(retryPending)` в меню очереди: отказ активной
попытки/диска уходил мимо `perform` и мог стать unhandled Future. Этот вызов теперь
ожидает только локальное сохранение; сетевой flush по-прежнему запускается в фоне,
поэтому ввод не блокируется. Существующий voice/receipt widget-тест расширен
реальным нажатием меню при отказе, проверкой report и доступности композера.
Новая сборка получает31, номер подписанного кандидата30 не переиспользуется.

На30 проверены normal-client real minute→reload→manual E2EE retry (один encrypted
event), отдельный UI shared DM pin участником0 и native Safari HEIC/48MP через
настоящий picker→encrypted album→два резких изображения→next/Esc→composer focus.
Это покрытие сохранено для неизменённых частей31; обработка popup retry проверяется
повторно отдельно и общим клиентским прогоном.

30 ZIP/DMG подписаны, все payload entries совпали, About30 и штатный Sparkle check
PASS. Primary29 не заменён. Восстановление профиля остановилось на
`SecItemCopyMatching`; SecurityAgent недоступен инструменту по системным правилам.
Дешифрование сохранённой истории и установка29→31 **не подтверждены**. Все прежние
зашифрованные `.secure.db` побайтно совпали с закрытой резервной копией; Keychain
не удалялся/не менялся. Перед31 требуется новая закрытая копия текущего профиля.

### Сохранённые результаты normal-client и CI

- [Полный реальный minute/reload/retry и shared DM pin](chat-followups-2026-10-30/chat30-ui-proof.json).
- [CI исходников0b0, включая Android preview](chat-followups-2026-10-30/ci30-proof.json).
- [Native Safari: picker→HEIC/48MP→encrypted album→viewer](chat-followups-2026-10-30/safari-photo30-ui-proof.json).
- [Native Safari: настоящий65МиБ download](chat-followups-2026-10-30/native-safari-save30.json).

Повторяемый локальный прогон: `NODE_PATH=<existing Playwright modules> node
prototype/check_chat_followup_ui.cjs`; normal web на localhost7358, Synapse8008,
control8090, свежие disposable пользователи, сетевой gate только своих сообщений.
`PIN_ONLY=1` ограничивает прогон shared pin. Доступ к production запрещён в самом
fixture проверкой localhost origin. Доказательства относятся к реальной версии30;
в31 изменены только ожидание локального retry и номер сборки, эти сценарии
повторно проверяются адресно.

### Итог31, до внешних системных разрешений

- [439PASS/4opt-in skip, analyze, хеши журналов](chat-followups-2026-10-30/validation31.json).
- [Повтор normal web31: реальный minute/reload/manual E2EE retry и shared pin](chat-followups-2026-10-30/chat31-ui-proof.json).
- [Локальный стенд31, прежний supervisor/runtime/volumes](chat-followups-2026-10-30/local31-server-proof.json).
- [Точный подписанный ZIP/DMG31, UI About и Sparkle](chat-followups-2026-10-30/macos31-package-proof.json).
- [Публичный пакет31 в VPS staging; не publication](chat-followups-2026-10-30/macos31-staged.json).

Артефакт31 заморожен на чистом780ae8f; дальнейшие изменения этого журнала —
документальные и не меняют клиентский payload. Flutter/crypto toolchain закреплён;
обычный lib/main.dart, локальный web31 собран с отдельной localhost-конфигурацией,
Mac31 — с production routing catalog/key, подтверждённым Ed25519.

Во время независимой проверки DMG был временно подключён системой, поэтому
hdiutil verify вернул Resource temporarily unavailable. Отключён только наш
собственный образ, затем checksum/readonly mount/payload/codesign повторены PASS.
Повреждение пакета не обнаружено; не ослаблялись проверки и не менялись байты.

Сохранённая29 и профиль перед31 скопированы закрытыми и побайтно сверены.
Точный ZIP31 запущен: About1.15.0(31), штатный Sparkle check «Совместимых обновлений
нет» (публичный feed29). Профиль ожидает Keychain: стек собственного процесса
содержит SecItemCopyMatching/SecKeychainItemCopyContent. Keychain не читался и не
очищался, история не объявляется расшифрованной. Запрос владельцу уже отправлен.

GitHub Safari остаётся на странице входа, git SSH push разрешён и завершён, но
HTTPS workflow dispatch credential отсутствует. Auto-review запретил Password
AutoFill; SecurityAgent также запрещён инструменту. Не обходить через cookies,
извлечение ключей, ручной production compose или подставленную physical acceptance.
Точный managed FULL input сохранён локально; разрешение владельца на релиз уже
дано, повторное согласование scope не нужно. Нужны только вход GitHub и системное
подтверждение Keychain; после них выполнить штатный FULL, release health/identity/
rollback проверки, публикацию exact31 и настоящий Sparkle29→31 с прежней историей.
Физические iPhone/Android остаются условными по единому реестру.

Старый staging30 явно помечен superseded, его appcast переименован, чтобы случайно
не опубликовать заменённую сборку. Production-канал не менялся. Временный сервер
синтетических фото закрыт; локальный стенд7358/8090 оставлен работающим.

### Подтверждения владельца31 октября

Владелец подтвердил Keychain. Точный31 открыл прежний профиль;4 контрольных
фрагмента расшифрованы. Затем31 закрыт, `/Applications/VoiceChat.app`29 открыт
штатно: в UI совпали account/device и те же4 фрагмента. Keychain не менялся и
не очищался. [Реальная приёмка кандидата](chat-followups-2026-10-30/macos31-accepted-ui-proof.json).
[CI исходников31 завершился success](chat-followups-2026-10-30/ci31-proof.json).

После ответа владельца «done» Safari был загружен заново по точному workflow URL,
но показывает Sign in, без Run workflow. Уточнён именно вход в Safari, параллельно
завершена аппаратная приёмка31. Нельзя считать авторизацию выполненной только
по ответу, если фактическая UI-сессия всё ещё не авторизована.
