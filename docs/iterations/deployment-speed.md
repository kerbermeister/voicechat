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

Перед web-only сохранены ID, StartedAt и RestartCount всех служб. Тёплый web-only запуск и сравнение контейнеров ещё ожидаются.
