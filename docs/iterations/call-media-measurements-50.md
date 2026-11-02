# Интервальные измерения звонков: 1.19.2+50

02.11.2026, source `51ab9775d2a5ac3228283a62873ef2a64765d487`.
План — [исследование OPT-01–16](../research/call-optimization-2026-11-02.md),
единственная пользовательская очередь — [реестр приёмки](../user-acceptance.md).

## Изменение

OPT-01: direct/group/screen сохраняют до60 последних измерений. Общая логика
вычисляет bitrate, jitter-buffer delay, concealment, encode/decode time и FPS,
send-queue delay по дельтам, а не среднему за весь разговор. Новый peer,
исчезнувший RTP stream и сброс счётчика начинают новый интервал. Нет деления
на ноль, неизвестные значения не подменяются нулями.

Групповой и экранный sampler читает каждый SDK transport один раз за3с;
число публикаций не умножает getStats. Имена transport изолированы, одинаковые
SDK report IDs не смешиваются. RTT относится к выбранной ICE-паре связанного
RTP transport. История ограничена, поздние результаты после shutdown/замены
peer отбрасываются. IP/SDP/ключи/account/device/track IDs не экспортируются.
Авторизация, криптография и пределы качества не менялись.

## Проверки

- Flutter582 PASS/4skip, финальные12 interval/room tests PASS, analyzer PASS.
- Реальный native Mac:1 integration PASS,3 цикла, два принятых аудиозвонка;
  RTP bitrate восстановился после2с отключения encoding. Сигналинг в памяти,
  внешний TURN и слышимый lip-sync не проверялись.
- Внутренний Chromium156: production renderer, единый A/V stream/один audio path,
  2с pause/resume,320→640,ICE restart; после восстановления bitrate/FPS положительны.
  Источники синтетические; это не физический A/V и не сетевой impairment A/B.
- Mac49→50 установлен через «Проверить обновления → Скачать и установить».
  285 файлов/ссылок совпали ZIP=DMG=installed, codesign strict PASS; прежний
  account/device и текущая история сохранены. Backup app/profile обновлён после
  ручных изменений владельца и проверен. Keychain не менялся. Старое QA-аудио
  владелец удалил до завершения повторного playback50; успешный playback49
  остаётся прежним свидетельством, новый playback50 не заявляется.
- APK50 подписан прежним сертификатом, опубликован в preview; точный base.apk
  установлен в API35 эмуляторе, version/SHA256 совпали. Физическая приёмка=false.

[Web88](https://github.com/kerbermeister/voicechat/actions/runs/41441892164)
завершён успешно. Независимый postcheck подтвердил source/digests/health,
rollback pointer и HTTPS; backend ID/StartedAt/RestartCount не изменились.
Постоянный Sparkle-ключ и HTTPS-проверки архивов сохранены.

[Проверки](release-50/checks.json),
[production](release-50/production-verified.json),
[Mac install](release-50/macos-installation.json),
[Android install](release-50/android-emulator-installation.json).

OPT-02 остаётся частичным; нет полного loss/jitter/bandwidth/offline A/B,
длительного акустического A/V, физических Xiaomi/iPhone Safari/PWA и новых
групповых key epochs. Оптимизация по исследованию продолжается.
