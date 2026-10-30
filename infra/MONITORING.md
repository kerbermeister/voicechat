# Внешний контроль одного VPS

`VoiceChat health monitor` (`.github/workflows/monitor.yml`) запускается на
стандартном GitHub-hosted Ubuntu runner: каждый час в минуты07/22/37/52 UTC,
а также вручную. Runner находится вне A: полная недоступность VPS не мешает
выполнению проверки и отправке GitHub-уведомления.

Проверяются DNS каждого входа относительно inventory, HTTPS route readiness с
правильными service/edge IDs и matrix/control=true, публичные TLS web/TURN и
необходимость продления за7 дней. По существующему pinned SSH запускается только
чтение: штатный `node_diagnostics.report` из проверенного immutable source на A.
Это WireGuard/network, процессы, Matrix/control, TLS и минимум2GiB свободного диска.
Ожидаются полный набор проверок, текущая identity узла и свежий bounded JSON;
приватные конфиги, профили, сообщения и stderr не выводятся.

Используются существующие production `SERVER_ROLE_CONFIG`, `DEPLOY_ROOT` и
`DEPLOY_SSH_KEY`. SSH host key закреплён в inventory; TOFU/agent forwarding нет.
`environment.deployment: false` сохраняет доступ к существующим secrets/vars,
но монитор не создаёт фиктивные production deployments.
Новые credentials не создаются. Существующий deploy key имеет прежние deploy
права; монитор использует его только для диагностического чтения.

При сбое job завершается ошибкой и GitHub отправляет email согласно настройке
владельца **Actions → Email → Failed workflows only**. Эта настройка проверена
30.10.2026; адрес получателя и credentials в репозитории не сохраняются.
Успех/сбой и отдельные категории доступны в Actions и job summary. После
восстановления обычная проверка вновь должна быть healthy; это не отдельная
система incident management и не обещание email на каждое восстановление.

## Проверка и тестовая тревога

В Actions → VoiceChat health monitor → Run workflow выбрать main. Обычный запуск:
`test_notification=false`. Для проверки доставки письма явно выбрать
`test_notification=true`: сначала проходят настоящие проверки, затем отдельный
шаг выдаёт **TEST ONLY**, не изменяя VPS. Название запуска также начинается TEST.
По расписанию тестовая тревога не включается. После теста повторить обычный
запуск и проверить healthy. Не останавливать production ради теста уведомлений.

Локальная проверка с тем же публичным конфигом и существующим SSH key:

```sh
python3 -B infra/service_monitor.py --identity /secure/existing-core-key
```

`SERVER_ROLE_CONFIG` и `DEPLOY_ROOT` задаются окружением. Команда не выполняет
release, reboot, смену DNS, создание ключей или доступ к содержимому переписки.
Незавершённый rollout/backup младше15 минут показывается как maintenance;
проблемы TLS, диска, DNS и SSH это не скрывает. Старый зависший journal не
подавляет тревогу бесконечно.

## Границы

GitHub schedule — best effort: запуск может задержаться. В public repository
расписание отключается после60 дней отсутствия repository activity; оператор
должен контролировать время последней проверки и состояние schedule. Это
доступный базовый внешний контроль, не круглосуточный мониторинг с SLA.
Источник: [GitHub schedule](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule).
Стандартные GitHub-hosted runners в public repository не расходуют платные
минуты: [GitHub billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions).
[Доставка уведомлений](https://docs.github.com/en/actions/concepts/workflows-and-actions/notifications-for-workflow-runs)
зависит от настроек аккаунта; полученное письмо проверяется отдельно от failed job.

Нормальные probes не доказывают authenticated WSS, передачу/расшифровку медиа,
физический микрофон/экран или телефон. Это отдельная клиентская приёмка в
[общем реестре](../docs/user-acceptance.md). При будущем добавлении внешнего edge
сверить inventory и доступ CI; SSH-диагностика сейчас проверяет core/cohost-роли,
а внешние входы — по публичным DNS/HTTPS/TLS, без проверки их локальных дисков.
