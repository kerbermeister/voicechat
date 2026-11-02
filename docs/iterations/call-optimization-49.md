# Оптимизация звонков: первый выпуск 1.19.1+49

02.11.2026, исходники `f7aa48217fdad030ccfa448454598e6f064d8621`.
Задачи и причины — в [исследовании OPT-01–16](../research/call-optimization-2026-11-02.md).
Пользовательская приёмка — только в [едином реестре](../user-acceptance.md).

## Изменения

- OPT-01, часть: direct sampler не зависит от HTTP-authorize. Накопительные
  allowlisted counters буфера, concealment, encode/decode, кадров и байтов
  включены в60 последних direct samples; для группы доступен снимок потоков.
  IDs/SDP/IP/ключи не экспортируются, отсутствующее поле не заменяется нулём.
  Полная общая история screen/group и устойчивые анонимные SSRC epochs ещё впереди.
- OPT-03: исходящее auto-video использует связанный remote-inbound RTCP feedback
  и CPU limitation, входящие потери остаются для индикатора. Собственный CC WebRTC
  сохранён. При отсутствии feedback не выдумывается плохое исходящее соединение;
  после истечения оценки приложение возвращает обычный auto ceiling. Физический
  асимметричный A/B ещё не выполнен.
- OPT-04: после отказа TURN lookup повтор через1/2с, максимум3 попытки в прежние15с.
  Connected/hangup отменяют повтор, поздний ответ проверяет connection epoch;
  новое восстановленное соединение получает новый budget для последующего обрыва.
- OPT-05, часть: совместимые manual→manual group caps применяются к действующему
  единственному encoding, если разрешения capture хватает. Нет stop/unpublish.
  Другие переходы сохраняют необходимый restart с rollback прежнего preset при ошибке.
- OPT-06, часть: coalescing CreateRoom для одного поколения2с; cache только после
  успешного RPC. При каждом запросе сохраняются identity/roster/lease проверки,
  смена поколения отзывает старую комнату. Готовность SFU бессрочно не кешируется.

## Проверки и границы

- Python:841 total,838 PASS,3skip. Flutter полный прогон после камеры:567 PASS,
  4skip. После последних двух recovery-сценариев отдельно22 protocol PASS;
  камера/direct capture/bitrate —10 PASS. Analyzer чист.
- Реальный native Mac:1 integration PASS,3 цикла, микрофон/полученные RTP/DTLS/отбой.
  Сигналинг в памяти, это не проверка внешнего TURN и не измерение слышимого lip-sync.
- Сравнение реального CallStore48 и49 на временной SQLite/fake-clock/media RPC:
  10 участников ×20 синхронных раундов по3с:200→20 CreateRoom, −90%. Это экономия
  конкретного RPC в данном сценарии, не экономия90% всего трафика/CPU звонка.
- Mac: постоянный Sparkle-ключ, HTTPS hashes,285 entries ZIP=DMG=установленная app;
  переход48→49 через «Проверить обновления → Скачать и установить». Аккаунт и
  device ID прежние, старая зашифрованная QA-запись проиграна0:00→0:09. Backup48
  app/profile сверены; Keychain не очищался. Повторная проверка49: обновлений нет.
- Android: прежний сертификат, публичный APK и manifest сверены. Точный APK49
  установлен в API35 эмулятор, versionName/code и SHA256 установленного base.apk
  совпали. Публикация owner-preview сохраняет physical_acceptance=false;
  эмуляторная установка подтверждается отдельной квитанцией.

В [full87](https://github.com/kerbermeister/voicechat/actions/runs/41435600604)
CI завершён успешно. Независимый production postcheck фиксируется в
[production-verified.json](release-49/production-verified.json).
[Проверки](release-49/checks.json), [RPC-сравнение](release-49/provision-comparison.json),
[Mac install](release-49/macos-installation.json),
[Android install](release-49/android-emulator-installation.json).

В этой итерации не добавлена отдельная автоматика переключения аудиопресетов
после N секунд: владелец просил только объяснить существующий механизм. Остальная
реализация исследования продолжается. Нет аппаратной приёмки Xiaomi/iPhone,
полного A/B impairment, длительного acoustic A/V и групповых key epochs.
