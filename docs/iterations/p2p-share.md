# P2P Share — проверка реализации

27 октября 2026. Web и подписанный macOS-пакет 1.10.1(19) опубликованы.
Аппаратный охват ограничен явно указанными платформами.
Требования: [функциональные](../p2p-share-requirements.md), [ТЗ](../p2p-share-spec.md),
[последовательный план](../tasks/18-p2p-share.md).

## Подтверждённые проверки

- Flutter unit/widget: 349 PASS на базе production 16; адресные проверки после merge main 17 — 15 PASS, 3 platform skips. Browser protocol: 7 PASS.
- macOS на настоящем Mac: DataChannel через TURN, SQLCipher-блоки, итоговый хеш,
  range через границу 4 МиБ и очистка аварийно оставленного сеанса — PASS.
- Настоящий локальный Matrix/Synapse: encrypted offer, отказ, отсутствие байтов до
  accept, два устройства получателя/первый accept, SHA-256 принятого файла,
  отзыв доступа выходом из комнаты — PASS. Учётные записи одноразовые.
- Chrome release: четыре прямых соединения, четыре relay, медленный адресат,
  отмена одного, повреждение одного и независимость остальных, пустой файл — PASS.
- 5 000 000 000 байт через TURN с зашифрованной записью и повторным чтением хеша —
  PASS (20 мин 31 с, включая два полных прохода хеширования и повторное чтение).
  Обнаруженное переполнение crypto/dart2js исправлено в vendor/crypto.
- Реальный браузерный экспорт 0 и 5 000 000 000 байт — PASS; 1193 чтения не больше
  4 МиБ; проверены байты после 4 ГиБ. Целый файл в RAM не собирается.
- Бинарное AES-GCM хранилище web: 4 МиБ ciphertext с тегом 16 байт, проверка чтения,
  отказ после подмены/перемещения блока, prefix cleanup сохраняет chat/другую
  передачу — PASS. Повтор полного сетевого теста 5 ГБ этого формата — PASS за 540 с.

## Воспроизведение

Из корня: `python3 prototype/setup.py`, запустить локальные postgres/synapse/turn/
livekit и control API по инструкции прототипа. Для Matrix: `prototype/prepare_p2p.py`
создаёт изолированные тестовые аккаунты/конфигурацию; после теста выполнить cleanup.
Использовать Flutter из infra/crypto-tools.json. Из apps/client:

```
flutter test --concurrency=1
flutter test --platform chrome test/p2p_browser_test.dart test/p2p_protocol_test.dart
flutter test integration_test/p2p_transfer_test.dart -d macos --dart-define-from-file=../../.prototype/p2p-native-test.json
flutter test integration_test/p2p_service_test.dart -d macos --dart-define-from-file=../../.prototype/p2p-matrix-test.json
flutter build web --release --no-web-resources-cdn --target lib/lab_p2p_main.dart --output ../../.prototype/p2p-lab-web
```

Node с Playwright: `prototype/test_p2p_transport.cjs` и `--large`,
`prototype/test_p2p_storage.cjs`, `prototype/test_p2p_cross.cjs`.
Это отдельные test entry points; production собирает только lib/main.dart.
Тесты используют собственные браузерные профили, временные файлы и локальный TURN;
не включать секреты/профили в свидетельства. Временные TURN credentials генерируются
из приватной конфигурации локального стенда.

## Непроверенное

Физических Android/iPhone нет (подтверждено владельцем). Сборка Android не является
аппаратной приёмкой. Windows-native ещё не существует; адаптеры понадобятся отдельно.
Mac↔Chrome: десять файлов в обе стороны через TURN — PASS. Настоящий Safari desktop
в приватном окне: 8 МиБ + пустой файл, TURN warning, зашифрованная запись и SHA-256
— PASS. Анализатор и CI итоговой интегрированной ревизии чистые.
Safari/iPhone, разные сети, переключение
сети/фоновый режим и конкуренция со звонком требуют отдельной аппаратной приёмки.

## Совместимость выпуска

Full release обязателен: новые серверные поля и vendor/crypto меняют backend
fingerprint. Configure добавляет поля и сохраняет операторские значения. При
неудачном full release deploy.py восстанавливает прежний client-policy.json перед
запуском старого control: прежний строгий парсер не принимает новые поля.
Для ручного возврата на старую ревизию также восстановить policy из согласованного
backup; не менять backend.sha256/digests вручную. 12 deployment tests — PASS.

## Выпуск и финальные регрессии

Полный release `36ca3749694fc9493bc2696ed37760ef67637198` опубликован workflow
[40544644275](https://github.com/kerbermeister/voicechat/actions/runs/40544644275).
Control/web/Synapse/Postgres healthy; previous указывает на `8e99cee`.
[Prototype checks](https://github.com/kerbermeister/voicechat/actions/runs/40544396442)
завершились успешно, включая обычную Android-сборку.

Дополнительно проверены 9 UI/storage-policy сценариев: полный путь черновика,
выбор друга, явная отправка без передачи байтов до согласия, отмена с освобождением
источника; временный P2P-пакет не запускает вытеснение истории.
Финальный клиентский патч 1.10.1(19), commit `03ab4d6`, опубликован:
[web-only workflow](https://github.com/kerbermeister/voicechat/actions/runs/40547842633),
[push CI](https://github.com/kerbermeister/voicechat/actions/runs/40547607101),
[PR CI](https://github.com/kerbermeister/voicechat/actions/runs/40547616033) — success.
Control digest `599629e7cae958ebbf470ca433ac4b403c949a93ac742ba11781967bb6613603`;
web `094543f36e129857085cc278c68724d080bfe951696188758db20ae73769c03d`.
ID/StartedAt/RestartCount control, Synapse, Postgres и TURN не изменились;
службы healthy, previous указывает на полный P2P release `36ca374`.
[PR #4](https://github.com/kerbermeister/voicechat/pull/4) объединён в main (`940d3f2`),
включая изменения другого агента до `c3a8f13`.

На Mac прошёл настоящий SQLCipher/Keychain-тест: временный блок удалён,
физическое место освобождено, прежний blob сохранён, потеря/подмена ключа не
пересоздаёт БД. Точный подписанный кандидат 19 принят на старом профиле:
аккаунт/device и три старых текста совпали; ZIP/DMG совпали по 285 файлам/ссылкам,
HTTPS-хеши и подпись ключом прежнего приложения проверены. В UI проверены
P2P-панель, серверные лимиты, системный выбор файла, локальный черновик,
удаление черновика и список друзей; сообщений реальным контактам не отправляли.
Штатная кнопка в 17 предложила подписанное обновление 19. Несколько загрузок
оборвались с NSURLErrorDomain -1005; отдельный HTTPS Range-запрос с Mac также
не завершился за 30 с. Серверные HTTPS-хеши полного архива проверены отдельно.
После отмены последней повторной загрузки установлен **тот же опубликованный
пакет локально**: свежий закрытый профиль и прежняя .app сохранены, Keychain не
менялся. В /Applications совпали все 285 файлов/ссылок и подпись; в запущенной
19 подтверждены прежние аккаунт/device и три старых расшифрованных текста.
Это не PASS штатной установки кнопкой. Следующий переход через кнопку остаётся
условной проверкой UA-48 при устойчивом соединении.

### Совместная нагрузка

`P2P_TURN_PORT=3479 node apps/client/tool/p2p_concurrent_test.cjs` использует
одноразовый Chromium и отдельный локальный TURN/TCP. Четыре получателя по 32 МиБ
с зашифрованной записью и SHA-256 одновременно с настоящими синтетическими RTP
аудио/видео — PASS за 10,3 с; получено 35 607 байт аудио и декодировано 260 кадров.
[Машинный результат](p2p-evidence/concurrent-media.json). Это частичная проверка
AT-13, не звонок VoiceChat на разных физических устройствах и не доказательство
расшифровки E2EE-медиа.

Большой контрольный direct-only UDP-прогон в текущем окружении показал низкую
скорость/переподключения и таймаут с медиа; без медиа также шёл медленно и был
остановлен. В этих лабораторных direct-only сценариях TURN намеренно отсутствовал.
Не объявлять их успешными или переносить результат TURN/TCP на все UDP-сети.
Небольшой прежний direct-прогон прошёл; межсетевой охват остаётся в UA-69.
[Ограничение сетевого прогона](p2p-evidence/network-limit.json).
