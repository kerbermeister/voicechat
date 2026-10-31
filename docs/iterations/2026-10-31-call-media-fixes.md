# Исправления звонков — 1.15.1(33)

Изолированный выпуск на актуальном main da718fc, без незавершённых изменений
старой рабочей папки. Production до выпуска: managed baseline
7fd90669c30faa5084136e7a9fed1d450e2382f7a3c5e5729de9b61f10d36044,
сервер/web c33894a, установленный macOS31, опубликованный Android32.
Diff от production включает control server_time и инфраструктуру уже выпущенного
Android-канала; нужен managed/full с backup/healthcheck/rollback.

- Групповая камера переиспользует captureCamera личных звонков; web rear требует
  exact facingMode. Старая камера освобождается до новой, при ошибке возвращается,
  микрофон не перепубликуется; параллельный switch подавляется.
- Call/screen key envelopes используют дополнительный server_expires_at,
  привязанный к серверному времени и монотонным часам. Legacy expires_at сохранён.
  Неверный server_expires_at не допускает fallback; identity, roster, generation,
  revision, device trust и E2EE не ослаблены. Для нового пути обновить обе стороны.
- Web-плитки не воспроизводят повторно микрофон, уже играющий через LiveKit.
  Персональная громкость из актуального main сохранена; играющий элемент
  не перезапускается на каждую DOM mutation.
- Android уведомляет из работающего Matrix sync через общий нативный контракт:
  системное разрешение, отдельные каналы, session-bound клик, нейтральный текст,
  очистка при выходе. FCM отложен: закрытый процесс не получает новую доставку.
- Выпущенная в31 поддержка захвата экрана macOS сохранена. iPhone webapp может
  передавать экран только при наличии getDisplayMedia; просмотр разрешён.

Приёмка не заменена mock-тестами: физические звонки Mac/iPhone/Android,
расшифрованные пиксели/звук и фоновая доставка остаются открыты в
[едином реестре](../user-acceptance.md), UA-02/05/07/18/37.

Проверки чистого checkout: flutter analyze — без замечаний; flutter test —
444 PASS, 4 platform-specific skip; Chrome — 2 PASS; Node mobile web — 9 PASS;
Python token/call/screen admission — 31 PASS; git diff --check — PASS.
