# VoiceChat prototype

Flutter-клиент для Android и web. Запуск и ограничения: [лаборатория E2EE](../../prototype/README.md).

`lib/main.dart` — ручной прототип с темами Lavender Soft, Ocean Calm и Midnight.
`lib/lab_main.dart` — отдельный автоматический сквозной сценарий на одноразовых аккаунтах.

## Демонстрация экрана (экспериментальная)

Клиент использует отдельный ScreenShareController текущего VoiceCall и существующие
Matrix/LiveKit подключения. ScreenCapture подготавливается из пользовательского
нажатия до claim; ключи идут только encrypted Matrix to-device. В UI есть отдельный
screen view, takeover/stop/fullscreen и Auto/Low. Server capability по умолчанию off.
[Инструкция](../../docs/screen-sharing.md), [матрица приёмки](../../docs/screen-sharing-acceptance.md).
Android service подготовлен, аппаратная проверка отложена; mobile web в закреплённом
SDK имеет только просмотр. Не включать функцию в релиз по одному успешному build.
