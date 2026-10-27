# P2P Share — проверка реализации

27 октября 2026. Работа продолжается; этот документ не означает production-приёмку.
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
— PASS. Анализатор после объединения main 17 чистый. Публикация ещё выполняется.
Safari/iPhone, разные сети, переключение
сети/фоновый режим и конкуренция со звонком требуют отдельной аппаратной приёмки.

## Совместимость выпуска

Full release обязателен: новые серверные поля и vendor/crypto меняют backend
fingerprint. Configure добавляет поля и сохраняет операторские значения. При
неудачном full release deploy.py восстанавливает прежний client-policy.json перед
запуском старого control: прежний строгий парсер не принимает новые поля.
Для ручного возврата на старую ревизию также восстановить policy из согласованного
backup; не менять backend.sha256/digests вручную. 12 deployment tests — PASS.
