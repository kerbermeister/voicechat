# Screen share на VPS — тестовый preview 24 октября 2026

По явному запросу владельца функция включена на https://univc.duckdns.org для
самостоятельного web-тестирования. **Личный и групповой сценарии PASS; полная
межплатформенная приёмка остаётся BLOCKED.**

## Развёрнутая версия

Другой агент уже опубликовал объединённый `39abf2d`, включающий screen share до
`978a184`, автоматические профили и SAS. Его [отчёт](integrated-release.md).
Сверены ancestry, четыре screen module SHA256, web/control digests, HTTPS,
COOP/COEP, health и закрытый внешний admin API: [preflight](screen-vps-evidence/preflight.json).
Runtime screen flag отсутствовал, функция была выключена.

Реальный VPS-прогон обнаружил отказ group invite: homeserver опережал Mac на
28.796 s (погрешность ±0.679 s), клиент отвергал любой будущий timestamp.
Исправление `30e96d299b786006f3408b2f5615b6a5dd8527e1` допускает опережение до
1 минуты, сохраняя отбрасывание старых/слишком будущих событий и остальные guards.
[Регрессионный тест и границы](screen-vps-clock-fix.md).

Штатный [Build and deploy №9](https://github.com/kerbermeister/voicechat/actions/runs/40127768357)
**SUCCESS**, режим `web`, deploy=true: server/client tests, analyze и web build;
Android не собирался. Обновлён только web image. Backend digest/fingerprints,
container IDs/StartedAt/restart counters control, Synapse, TURN и Postgres сохранены:
[web update](screen-vps-evidence/web-update.json).
Публичный `main.dart.js` совпадает с новым image:
`6c3e65baf91c5e39955a36afe6520fae166e8bc904676b1f0aa6cd8d27594caa`.

## Проверенный сценарий

Обычный опубликованный web, Chrome 156.0.8078.47, два изолированных контекста на
одном Mac. Захват настоящей тестовой вкладки с автоматическим выбором; микрофон
и камера синтетические. Все Matrix/API/SFU/RTC запросы после bootstrap идут через
публичные HTTPS/WSS и реальный VPS. SAS двух устройств сравнен и подтверждён.

Для **личного и группового звонка** assertions подтвердили:

- У получателя отрисованы контрольные пиксели реального источника.
- Второй участник перехватил показ; первый увидел другой цвет нового источника.
- Старый capture завершён; после stop оба capture освобождены и экран исчез.
- Voice peer connections сохранены, audio packets и camera frames растут.
- Для группы отдельно подтверждены успешные `/api/token` admission обоих клиентов
  с точным group room ID; тест не подменяет группу повторным личным звонком.

[Машинный результат](screen-vps-evidence/verification.json),
[личный звонок](screen-vps-evidence/direct-screen.png),
[групповой звонок](screen-vps-evidence/group-screen.png),
[успешный workflow](screen-vps-evidence/workflow-success.png).
В ходе штатной очистки/смены поколения встречены обработанные `unbind 404` и
`token 409 screen_revision_conflict`; положительные media assertions после них прошли.

Bootstrap использует **реальные сессии, выданные Synapse при shared-secret регистрации**:
только ответ POST login в двух тестовых браузерах подставляется из приватного fixture.
Это не повторная проверка пароля по публичному маршруту в окончательном media-прогоне.
Публичный password login уже прошёл в предварительных попытках/объединённой приёмке;
повторы упирались в per-IP rate limit. Лимиты и production auth не менялись.
Нет подмены SAS, screen authorization, ключей, SFU или медиа.

[Prepare](screen-vps-evidence/prepare.py) переиспользует seeder проекта и оставляет
registration secret внутри Synapse. [Wrapper](screen-vps-evidence/check.cjs)
переиспользует `prototype/check_screen_calls.cjs`. Для повторения нужны операторский
SSH, закреплённый Playwright/Chrome и явно разрешённое тестовое окно:
`python3 docs/iterations/screen-vps-evidence/prepare.py`, затем
`NODE_PATH=<runtime node_modules> node docs/iterations/screen-vps-evidence/check.cjs`.
Revision/JS hash закреплены на этот релиз; при новом deploy сначала сверить их.
Прогон включает глобальный flag; media FAIL автоматически выключает его.

Предварительные ошибки wrapper и их очищенные fixtures сведены в
[attempts](screen-vps-evidence/attempts.json); это не PASS функционала.
[Cleanup](screen-vps-evidence/cleanup.py) деактивировал все три финальных fixture
аккаунта и временного локального оператора. Независимый PostgreSQL read подтвердил
отсутствие активных тестовых аккаунтов/операторов. Приватные fixture удалены.
Пользовательские аккаунты и устройства не использовались.

## Состояние после проверки и отключение

[Postflight](screen-vps-evidence/postflight.json): runtime flag=1, UID/GID10001,
0600, `screen_enabled()`=true; active/pending/retired=0, health=200, без токена
capabilities=401, внешний admin=404. Default off сохранён в коде.
На VPS `/srv/voicechat/runtime/screen-preview.json` содержит несекретную запись
об этом preview и незавершённой полной приёмке. Флаг глобальный для этой VPS.

Оба участника должны обновить страницу и начать **новый звонок**; затем
«Показать экран» / «Перехватить экран». Устройства другого участника предварительно
подтвердить существующей SAS-проверкой. Для первого ручного теста использовать Chrome desktop.

Отключение на VPS под `/srv/voicechat/deploy.lock`:

```sh
docker exec -i -u 10001:10001 voicechat-control-1 python3 - <<'PYTHON'
from pathlib import Path
import os
os.umask(0o077)
p = Path('/work/.prototype/screen-enabled')
t = p.with_name('screen-disabled.pending')
t.write_text('0\n')
t.chmod(0o600)
t.replace(p)
PYTHON
docker exec voicechat-control-1 python3 prototype/screen_status.py
```

Worker отзывает поколения; дождаться отсутствия active/pending/retired и проверить
обычный звонок. Не откатывать общие БД/тома ради отключения экрана. Перед изменениями
проверен encrypted Restic snapshot `fced0ece`; previous после web-only обновления —
`39abf2d`. Новый остановочный backup не выполнялся: схема/тома/backend не менялись.

Android, физические мобильные браузеры, другие физические компьютеры, Firefox/Safari
media на VPS, relay-only, UDP-blocked/TCP443-only, смена сетей, системный picker/Stop,
VoiceOver и нагрузка этим прогоном не принимаются. Полная приёмка —
[SS-12–SS-17](../tasks/08-screen-sharing.md); расхождение часов между физическими
клиентами проверяется отдельно без ослабления TTL/replay защиты screen keys.
