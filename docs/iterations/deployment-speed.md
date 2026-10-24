# Ускорение деплоя — проверка 24 октября 2026

База: опубликованный `83cda49`. Изолированный checkout; файлы и коммиты другого агента не включались.

## Реализовано

- Раздельные exact-key кеши только для закреплённых crypto tools и генерируемых worker/JS/WASM. Плавающий nightly заменён проверенной датированной версией; cold miss сохраняет полный путь сборки.
- Режим workflow `full`/`web`, reuse immutable control digest, проверка исходников на runner и backend/config/origin/schema/control под deploy-lock на VPS.
- `web` обновляет только web с `--no-deps --wait`; при неуспешном healthcheck возвращает предыдущий web, не продвигая current/previous.
- Полный режим сохраняет согласованный Restic backup и обычное восстановление служб. Файлы старых релизов сохраняются для живых bind mounts.
- Статика Caddy использует `Cache-Control: no-cache` без очистки локального хранилища пользователя.

## Проверки

- Модульные проверки запрещают web-only при новых backend-исходниках, runtime-конфигурации, несовпадающем control/web image и отсутствующей baseline; проверяют полный путь после web-only, rollback и валидацию SSH target.
- Настоящий изолированный Docker Compose: успешное web-обновление; неисправный healthcheck; настоящий откат на предыдущий web; backend ID и StartedAt неизменны, current/previous не продвигаются при сбое. Тестовый проект удалён после проверки; production не использовался для намеренной ошибки.
- Серверные тесты после штатного `prototype/setup.py` прошли. Opt-in Docker тест отдельно запускался с `VOICECHAT_DOCKER_DEPLOY_TEST=1`.

## Замеры Actions и production

До ускорения: [релиз 83cda49](https://github.com/kerbermeister/voicechat/actions/runs/40073846639), total 16m19s. Tools 8m10s, web 3m07s, tests 2m24s, VPS deploy 36s.

Первый запуск [3d162dc](https://github.com/kerbermeister/voicechat/actions/runs/40116610059) отменён после 9m07s: страница оставалась на Starting job, шаги были недоступны. Скачанный позже архив подтвердил работающий runner: 81 серверный тест и проверки клиента прошли, оба кеша дали miss, отмена прервала установку третьего инструмента. Это ошибка оценки по интерфейсу журнала, а не доказанный сбой runner. В замер производительности не включается. Runner дополнительно закреплён на Ubuntu 24.04 и включён в совместимость кеша.

Повторный холодный [b868eb0](https://github.com/kerbermeister/voicechat/actions/runs/40117340480) — PASS: total 13m56s, job 13m52s. На VPS запущен тот же commit, записаны backend/config fingerprints. Оба кеша сохранены: tools 14 MB, assets 880 KB. HEAD-запросы `/`, `/main.dart.js`, `/flutter_bootstrap.js`, `/flutter_service_worker.js` подтвердили `Cache-Control: no-cache`.

Перед web-only сохранены ID, StartedAt и RestartCount всех служб. Тёплый [web-only 29520dd](https://github.com/kerbermeister/voicechat/actions/runs/40118510973) — PASS: total 5m03s, job 4m59s. Assets cache использован повторно (Last used 20:00), tools cache не запрашивался (Last used остался 19:56). Immutable control digest сохранён; ID, StartedAt и RestartCount PostgreSQL/Matrix/control/TURN до и после совпали побайтно; заменён только web.

Реальная SSH preflight-проверка изменённых защищённых файлов отказала с требованием полного деплоя до любых изменений VPS. Финальная версия дополнительно проверяет наличие и здоровье backend перед web и после его healthcheck; изолированный Docker-прогон с четырьмя backend-контейнерами и откатом пройден повторно.

Полный [a37ddbf после web-only](https://github.com/kerbermeister/voicechat/actions/runs/40119196157) — PASS: total 8m16s, job 8m12s. Изменение документации генератора сменило ключ ассетов: старый `7aa399…` остался, новый `0e8dc6…` создан в 20:14. Tools cache `faa061…` (14 MB) восстановлен повторно в 20:09, инструменты не компилировались заново. Проверено изменение входа генератора; сами версии зависимостей не обновлялись. Lock-файлы и версии toolchain входят в exact key и проверены модульным тестом.

На VPS current указывает на `a37ddbf`, previous — на успешный web-only `29520dd`. Полный путь создал encrypted snapshot `50b1c3f52aa49540a4c26861ebc520c97bb834bf2a50e9e19448d663db1953fd` в 18:14:36 UTC и прошёл штатный Restic check. Новый health preflight проверен напрямую на настоящих PostgreSQL/Matrix/control/TURN после обновления. SQLite screen metadata осталась v2, screen sharing — off. Маршруты приложения/Matrix/API работают; screen API без авторизации даёт 401, admin endpoint снаружи — 404.

Владелец подтвердил в своём Chrome: обычный ⌘R открывает регистрацию, локальные настройки/данные сохранились. Дополнительно в тестовом браузере тема Ocean Calm, сохранённая до полного обновления, осталась после обычного reload без очистки данных; JS console ошибок нет. После проверки исходная палитра тестового профиля восстановлена.

## Использование и ограничения

Для минорной правки клиента: новый commit → **Build and deploy** → `mode=web`, `deploy=true`. При backend/config/unknown source изменениях guard требует `full`. Пустой/утраченный кеш не отменяет сборку: снова используется полный путь генерации. По замеру тёплый web-only занял 5m03s вместо прежних 16m19s; это результат конкретных прогонов, не гарантия времени очереди/нагрузки runner.

Для ручного `prototype/build_web_assets.py` нужен датированный nightly из `infra/crypto-tools.json`, а не только alias `nightly`. В этой версии: `rustup toolchain install nightly-2026-10-24 --component rust-src`, затем `rustup target add --toolchain nightly-2026-10-24 wasm32-unknown-unknown`. Версии остальных инструментов заданы там же; CI устанавливает их автоматически при cache miss.

Активный медиазвонок во время замены web/Caddy не проверялся. Backend не перезапускается, но проксируемые WebSocket могут кратко переподключиться. Настоящий отказ healthcheck проверялся в изолированном Compose; production намеренно не ломался. Android/физические устройства и доказательство расшифровки медиапотока в эту проверку инфраструктуры не входили.

[Инструкция опубликованного workflow](https://github.com/kerbermeister/voicechat/blob/main/infra/README.md).
