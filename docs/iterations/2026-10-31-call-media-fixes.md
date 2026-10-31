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

## Выпуск и установленный Mac

Исходная ревизия `5b3f08ceff117cb400e5e9cba2c8c239a689109c` перенесена
fast-forward в main по явному разрешению владельца.
[Build and deploy #72](https://github.com/kerbermeister/voicechat/actions/runs/41213935874)
завершился SUCCESS: `mode=full`, `rollout=managed`, `deploy=true`.
[Независимая проверка](call-media-fixes-33/production33-verified.json) подтвердила
exact commit/digests, здоровые службы, нулевые restart counts, прежнюю Matrix/data
identity и previous pointer на исходный baseline. [Публичные endpoints](call-media-fixes-33/production33-public-health.json)
отвечают200, клиент33, HTML/version.json — no-cache.

Подписанный постоянным Sparkle-ключом пакет33 опубликован штатным издателем в
canonical edge-a канале. Полные [HTTPS hashes ZIP/DMG/feed](call-media-fixes-33/macos33-published-https-proof.json)
проверены. После разрешения владельца приложение31 закрыто, app/профиль сохранены
в проверенной резервной копии. Кандидат33 открыл прежний профиль после ручного
подтверждения Keychain владельцем. Установленная31 предложила и скачала33 через
Sparkle; затем наблюдался перезапуск установленной33 без ручной замены app.
Все285 файлов/ссылок совпали с точным ZIP, codesign PASS, прежние account/device
и4 старых расшифрованных фрагмента сохранены; About33 подтверждён.
[Проверка установленного приложения](call-media-fixes-33/macos33-installed-ui-proof.json).
Это проверка обновления и профиля; она не доказывает исправление медиапотока
в реальном звонке с телефоном. FCM не настроен и не включён.

## Android

[Android release #4](https://github.com/kerbermeister/voicechat/actions/runs/41214159123)
завершился SUCCESS. Загруженный через встроенный браузер ZIP совпал с GitHub
digest; точный APK1.15.1(33) повторно проверен локальным apksigner/package:
прежний сертификат, versionCode, ABIs, manifest/hash и идентичная Mac/production
конфигурация. [Подтверждение](call-media-fixes-33/android33-verified.json).
SHA-256 APK: `882500aa3586d4c2aaaa0ecf70447e4560b25c234cd45fafb590e1b31a967004`.
По отдельному явному разрешению владельца опубликован точный APK33 в общем
канале для проверки на телефоне до физической приёмки. Acceptance build/hash
не выставлялись, штатный workflow gate не изменён. Публикация выполнена прежним
низкоуровневым atomic publisher под managed/channel lock: полный SHA-256 через
HTTPS проверен до переключения latest, предыдущий manifest32 сохранён.
Службы (ID/StartedAt/RestartCount) и managed release pointer не менялись.
[Подтверждение публикации](call-media-fixes-33/android33-publication-proof.json).
[Внешняя проверка HTTPS](call-media-fixes-33/android33-public-https-proof.json).

В приложении: «О приложении → Проверить обновления». [Прямой APK33](https://univc.duckdns.org/updates/android/33/voicechat.apk).
Исходная ревизия пакета закреплена тегом `app-v1.15.1+33`.
Физический переход31/32→33, профиль, звонки и фон остаются открытыми в UA-37/18;
FCM по указанию владельца не трогали.
