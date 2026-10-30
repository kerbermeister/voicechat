# Односерверная приёмка и внешний контроль

30.10.2026. Разрешение владельца: закрыть доступные проверки клиентов,
диагностику и уведомления на существующем A+edge-a. Перенос A и новые VPS
отложены; VM этого этапа не запускаются. Непринятые пользовательские сценарии
ведутся только в [едином реестре](../user-acceptance.md).

## Мониторинг

Новый `infra/service_monitor.py` использует стандартную библиотеку и существующие
entry_probe, host_connection и node_diagnostics. Существующий deploy key остаётся
в production GitHub environment; SSH host identity берётся из inventory. Новый
workflow читает diagnostics и публичные endpoints, не выполняя deploy или reboot.
`environment.deployment:false` исключает фиктивные deployment-записи.

Первый live прогон с Mac: все13 DNS/route/TLS/core checks healthy.
[Безопасный отчёт](three-vps-evidence/2026-10-30-single-vps-monitor-initial.json).
Проверены account settings GitHub: существующий Actions email channel, failed
workflows only; адрес не сохраняется. Repo Public, стандартный Ubuntu runner.
Workflow опубликован и enabled; normal/test/normal выполнен (ниже).
Фактический schedule run пока не наблюдался. Email delivery не проверяется
по явному ограничению владельца, почтовые приложения не использовать. Границы schedule,
maintenance и redaction — [операторская инструкция](../../infra/MONITORING.md).

3 адресных monitor tests PASS; полный Python suite752 PASS/3 skipped,89.515s.
Новых клиентских изменений нет; macOS25 не требует пересборки ради мониторинга.
Protected workflow/infra включены в штатный FULL62/sourcea35b61b,
независимый postcheck PASS. Никакие fingerprints не менялись вручную.

## Клиентская проверка

Production web во внутреннем браузере, отдельный nonadmin test account со штатной
первичной crypto/recovery настройкой. Секреты fixtures только локально0600;
ключи рабочего пользователя не извлекались. Нативный клиент — установленный
подписанный macOS1.13.0(25), ранее принятый штатным обновлением24→25.

В отдельном тестовом разговоре web→Mac виден точный новый тестовый текст;
Mac→web виден nonce нового тестового текста. Владелец отдельно подтвердил, что
ответил в этом разговоре вручную, затем освободил приложение для агента.
Ciphertext audit и реальные image/file/reload результаты описаны ниже.
Звонки, экран и восстановление медиа ещё не приняты. Физических ADB устройств
и эмуляторов нет; не выдавать этот Mac/внутренний браузер за телефон.

Особенность CUA: значения Flutter AX полей могут опережать/не отражать реальный
canvas; перед отправкой сверять визуальную отрисовку и счётчик, а получение —
на втором клиенте. При копировании в нативный клиент нужен реальный OS clipboard
(standard Edit→Paste), одних AX values недостаточно. Не объявлять дефект приложения
по неотработавшему действию automation. Исходный Unicode ввод CUA не принимался
за подтверждённый Enter сценарий; фактическая отправка подтверждена отдельно.

## Реальные результаты UI и GitHub

Normal1 [41054775252](https://github.com/kerbermeister/voicechat/actions/runs/41054775252)
healthy13 checks; TEST2 [41054884183](https://github.com/kerbermeister/voicechat/actions/runs/41054884183)
ошибка только в явно помеченном test step после healthy13; Normal3
[41054981020](https://github.com/kerbermeister/voicechat/actions/runs/41054981020)
SUCCESS19s. Это не доказательство доставки email. Владелец запретил использовать
почту; её больше не открывать и не запрашивать ради этого этапа.

Новый ciphertext audit: Megolm,3 encrypted timeline events,2 senders; контрольные
открытые тексты отсутствуют в server event content. Временная собственная test
session отозвана finally, owner credentials/crypto keys не экспортировались.
Фото 128×128 визуально открылось в native25. Файл97 bytes получен web → native,
сохранён штатным Save в /private/tmp, SHA256
ce70679b1480f912bf4ca49deb98921d680a2d04ee68ce3e8c48e8eec1d23f11 совпал.
Web reload/reopen сохранил сессию, тексты и вложения без очистки хранилища.

Медиа НЕ PASS: native → web invitation дошло; после принятия web оставался
0:00/ожидание с disabled controls. Обратный web вызов остался на «Вызываем…».
Причина клиент/IAB capture не установлена, console warn/error пусты; скрытые API,
fake tracks и браузер Chrome не использовались. Native вызов завершён штатно,
web вкладка закрыта для освобождения pending capture; основной профиль сохранён.
См. существующий UA-04; screen/group/phone этим не закрываются.

FULL62 main/a35b61b запущен штатно:
https://github.com/kerbermeister/voicechat/actions/runs/41056084087
Before baseline healthy, точная data identity и feed25 сохранены.
Релиз SUCCESS16m27s; независимый after probe PASS (ниже).

Дополнительный реальный протокольный TURN check с Mac PASS: обычный login
собственного disposable account → свежие Matrix TURN credentials → trusted
public TURN/TLS → authenticated UDP allocation → Refresh lifetime0/release.
Temporary Matrix session отозвана, секреты в evidence не записаны. Это
allocation/control-plane proof, НЕ двусторонний decrypted audio/video.
[Безопасное свидетельство](three-vps-evidence/2026-10-30-single-vps-client-checks.json).

## FULL62 и post-release PASS

Штатный managed/full main/a35b61b завершился SUCCESS16m27s. Exact source bundle
57e5b9e7a09d98f74ea59699cd5b78f0530a5e9877cfb4536f24338a069746aa.
Независимый pinned-SSH postcheck проверил целостность delivery/source receipt,
backend/core fingerprints, role manifests против фактически работающих images,
завершённый journal и released role fences, previous pointer из before snapshot,
прежние PostgreSQL/signing identity, network desired/applied bytes, backup/TLS timers.
Все шесть соседних process ID/StartedAt/RestartCount неизменны; все прежние
посторонние container IDs, включая VPN, по-прежнему running. HTTPS VoiceChat,
route health, updater feed и соседний сайт PASS; feed25 bytes прежние,
web Cache-Control:no-cache. Runtime/data/catalog вручную не переписывались.

Внешний monitor4 после release
[41058284730](https://github.com/kerbermeister/voicechat/actions/runs/41058284730)
SUCCESS13s, healthy13 checks. Обновлённый web восстановил прежнюю test session
и расшифрованную историю; новый уникальный post-release текст появился в
установленном native25 и получил read receipt. Новый macOS build не нужен:
клиентский код в этом выпуске не менялся относительно опубликованного25.
[Безопасный production proof](three-vps-evidence/2026-10-30-single-vps-full62.json).

Остаток пользовательской приёмки — только общий реестр UA-04/UA-80 и его
условные hardware-пункты. Автоматический schedule ещё не наблюдался; enabled
и cron проверены, ручной внешний путь выполнен. Email не проверять. Видимый IAB
также не установил media; осмотр Codex для поиска permission автоматически
отклонён из-за возможных посторонних приватных чатов, обход не выполнялся.
Новые VPS и перенос A не выполнялись. Automation остаётся paused.

После FULL62 отдельно повторены fresh TURN/TLS allocation/release и ciphertext
audit нового post-release сообщения: PASS,10 encrypted events/2 senders,
контрольного plaintext в server event content нет. Обе temporary Matrix sessions
отозваны; существующие account credentials/keys не экспортировались.

Ограничение среды: scoped попытка открыть System Settings для чтения microphone
permissions также недоступна (Computer Use not approved). Поэтому нельзя
определить capture permissions этим инструментом; не обходить через shell
или чужие окна. Это не доказательство причины медиасбоя. Почта исключена.
После публикации docs9b06e40 actual scheduled run по-прежнему не наблюдается;
workflow enabled и manual13 checks после FULL62 подтверждены. Не выдавать
успешный dispatch за проверку cron. Следующий шаг по UA-80 — дождаться
события schedule в GitHub и проверить его healthy, не выключая production.


## Итог после звонкового исправления и выпуска29

Дальнейшая приёмка и исправления выполнены в [журнале24](24-call-and-connection-diagnostics.md).
WEB70 и personal macOS1.14.2(29) опубликованы; настоящий Sparkle28→29, прежние
account/device/history и exactpayload проверены. Direct Mac28↔web28 со слышимым
звуком подтверждён владельцем; group28 remote E2EE kOk на обоих клиентах и
multi-device decline проверены агентом. Реальный29 regression после нового
короткого разговора больше не возвращает старые title/timer при decline.
Нормальныйmonitor8 и настоящий scheduled9 SUCCESS, healthy13. TEST6 ранее
дал явную тестовую ошибку после healthychecks; email исключён владельцем.
UA-80 закрыт в этом объёме. Телефоны, camera/screen/recovery и внешние edge
этими доказательствами не подменяются; точный остаток — единый реестр.
