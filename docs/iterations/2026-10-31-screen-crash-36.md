# Исправление краша демонстрации экрана — 36

## Наблюдение и причина

31.10.2026 пользователь проверил опубликованный Mac1.15.3(35): выбор всего
экрана завершил приложение, у собеседника звонок остался открытым.
Санитизированный разбор локального crash report: EXC_BAD_ACCESS/SIGSEGV,
PC=0, LR в flutter_webrtc+0x19e84, FlutterWebRTCPlugin.m:953, вызов
CapturerStopHandler при trackDispose. Дизассемблирование подтверждает вызов
нулевого указателя block invoke. Swift closure в NSMutableDictionary была
стёрта до Any; исправление явно задаёт Objective-C block ABI и escaping completion.
Сырые отчёт, пути профиля, содержимое чатов и идентификаторы аккаунта не включены.

## Изменения

- Проверка реальных SDK trackDispose и streamDispose в XCTest, без выбора
  пользовательского экрана и без захвата/отправки его содержимого.
- Обработка SCFrameStatus.started и complete с валидным pixel buffer;
  idle/blank/suspended/stopped не подтверждают начало показа.
- Удалено второе ожидание кадра только после успешного native picker start:
  он уже ждёт настоящий пиксельный кадр. Legacy macOS12/13 сохраняет проверку.
- Общий Matrix-клиент отслеживает также состояние DTLS/peer connection:
  closed/failed завершают звонок, disconnected даёт15 секунд на восстановление.
  Поздний connected не воскрешает завершённый вызов.

## Проверки и выпуск

Нативный XCTest на Mac15.3.1: 2 проверки PASS — реальные SDK trackDispose/streamDispose и статусы пиксельного кадра. Flutter protocol/screen:24 PASS до последней правки обработки первого кадра; полный повтор выполняется. Полный показ Mac→другое устройство не подтверждён.
Источник работы — отдельная release-ветка, исходный грязный workspace сохранён.
Production baseline web/core/Android33 (5b3f08c), Mac35 (870246a).
Diff относительно33 включает backend, vendor SDK, Android lifecycle и Flutter;
нужны workflow Build and deploy mode=full и отдельный подписанный Android APK.
FCM отложен по указанию пользователя.

Доступ к GitHub через внутренний браузер ранее отклонён контролем origin/network;
запрещён обход через CLI/API или другой браузер. Системный picker ControlCenter
также недоступен автоматизации. Эти ограничения не выданы за успешную проверку.
Текущие дефекты и неподтверждённые сценарии ведутся в [едином реестре](../user-acceptance.md).
