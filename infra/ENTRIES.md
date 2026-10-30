# Подключение и замена входного сервера

Этот документ описывает операторский контракт подключения и замены. Актуальные
результаты и ограничения проверок: [точка продолжения](../docs/iterations/19-three-vps-resume.md)
и [единый реестр приёмки](../docs/user-acceptance.md). Документ сам по себе не
является свидетельством внешнего production onboarding. Принятый раздельный
deploy описан в [production evidence](../docs/iterations/split-deployment-production.md).

## Входные данные

Работать из чистого согласованного checkout. Приватный ключ подписи каталога
остаётся на операторском Mac/runner и никогда не передаётся VPS. Перед первым
использованием новой версии оператора требуется соответствующая production
`full` baseline; CLI проверяет оба source fingerprints и переиспользует её
immutable application images. Backend/клиенты ради нового адреса не переписываются.

Новый узел: Debian 12 amd64, root SSH, свободные публичные порты, IPv4 и проверенный
через консоль провайдера SSH host key. TOFU/`ssh-keyscan` вместо проверки не подходят.
Приватный WireGuard key создаётся на самом узле. Внешние package repositories
должны содержать закреплённые версии из `host_packages.py`.

Конфигурация операции содержит:

- `root`: существующий managed root A;
- `bootstrap_inventory`: прежний доверенный inventory, используемый только для
  первого pinned SSH к A; последующие назначения берутся из проверенной baseline;
- `entry`: новый/заменяемый `id`, `public_ip`, `ssh_host_key`. Только для нового ID
  дополнительно нужны постоянные `origin` и `turn_host`;
- `dns`: `domain`, ожидаемый прежний список IPv4 `expected` (один адрес или пустой
  список), `token_file` — путь credential на A;
- `tls`: централизованный выпуск или заранее предоставленные сертификаты.

CLI сам добавляет запись в topology/inventory, выбирает свободный адрес из /24
приватного адреса A и повышает generation заменяемого узла. Замена сохраняет
прежние HTTPS/TURN имена и приватный адрес. Существующий cohost-вход с A этим
сценарием не переносится: это отдельная миграция.

`--identities` — private JSON map физических узлов (`core`, `edge-b`, …) в
существующие SSH private-key references или profiles `identity_file/host/port/user`.
Для нового узла добавить одну ссылку. Ключи не копируются с одного VPS на другой.

TLS по умолчанию подготавливается на A через существующий `acme.py`:

```json
{
  "mode": "acme",
  "directory": "/var/lib/voicechat-acme",
  "token_file": "/secure/duckdns-token",
  "accept_tos": true,
  "config": {
    "schema": 1,
    "provider": "duckdns",
    "environment": "production",
    "email": "operator@example.com",
    "domains": ["installation.duckdns.org", "entry-c.duckdns.org"]
  }
}
```

Это пример, не уже созданные адреса/credentials. Список domains должен покрывать
все SAN names, включая canonical origin. `accept_tos` задаёт оператор, имеющий
право принять условия CA. Все ACME jobs используют один центральный directory:
DuckDNS TXT для вложенных имён общий, параллельные writers запрещены.

Для уже выпущенных цепочек поддерживается `mode=existing` и ссылки на A:
`web_chain`, `web_key`, `turn_chain`, `turn_key`. TLS-проверки остаются теми же:
системное доверие, SAN, соответствие ключа и минимум семь дней действительности.
Для новой generation должны быть подготовлены новые приватные TLS keys.

## Одна команда и повтор

```sh
python3 infra/entry_ssh.py \
  --config /secure/entry-c.json \
  --identities /secure/node-identities.json \
  --signing-key /secure/operator-route-catalog.pem \
  --state /secure/entry-c-operation \
  --execute
```

Без `--execute` проверяется структура ввода без SSH. Для новой операции signing key
обязателен; он должен совпасть с прежним публичным pin установки. Каталог получает
следующую revision и подписывается локально. Для возобновления повторить команду
с теми же state/config и checkout; `--signing-key` повторно не нужен. Не заменять
source archive, config, journal или fingerprints, чтобы «пройти» отказ guard.

Локальный state и журнал на A сохраняют точную source delivery, attempt, входы и
подтверждения шагов. CLI не печатает TLS keys, registry tokens или TURN secrets.
Не запускать две операции одновременно. Другие релизы блокируются активным
lifecycle. После обрыва продолжать прежнюю операцию, не запускать новый full/initial.

Ошибочный SSH pin или ранний package failure можно отменить:

```sh
python3 infra/entry_ssh.py --config /secure/entry-c.json \
  --identities /secure/node-identities.json \
  --state /secure/entry-c-operation --cancel
```

Отмена разрешена только до возможной передачи TLS/application credentials и
изменения действующих узлов. Исходные записи архивируются; данные не удаляются.
После этой границы предусмотрено продолжение вперёд: автоматический откат не
возвращает доступ отозванной машине или её секретам.

## Порядок и гарантии

1. Закреплённые зависимости, локальный WG key и регистрация public identity.
2. Сеть нового узла, централизованные TLS pairs, каталог и immutable web image.
3. Claims действующих ролей, обновление peers/ACL без перезапуска Docker.
4. При добавлении — согласованное обновление конфигураций; при замене — новая
   общая TURN epoch на A и всех оставшихся входах. Core получает consistent backup
   до изменения. Database identity и остальные runtime secrets сохраняются.
5. Реальный запуск, trusted-SNI HTTPS/upstream checks, фактические image refs,
   authenticated TURN allocation/cleanup; при замене старые временные TURN
   credentials должны быть отвергнуты всеми действующими TURN endpoints.
6. DNS cutover после готовности; затем проверка resolver convergence, публикация
   подписанного каталога, независимое HTTPS-чтение каталога с каждого входа.
7. Commit новой managed baseline, поузловое освобождение fences и обновление
   maintenance delegates. Прежние release-каталоги не удаляются.

TURN secret сейчас общий. Замена его эпохи может кратко прервать звонки и
перезапустить core writers/TURN; не обещаем бесшовную ротацию скомпрометированного
входа. Отзыв WG key сам по себе не отзывает прежний общий TURN secret.

Private web image получает новый хост через производный repository-read bearer,
выпущенный на A только для этого repository. Исходные GHCR credentials остаются A.
Bearer передаётся в локальный Docker Engine для одного pull; `docker login` и
постоянный credential file на новом входе не создаются. Это стандартные
[registry bearer scopes](https://docs.docker.com/reference/api/registry/auth/) и
[Moby RegistryToken](https://github.com/moby/moby/blob/master/api/types/registry/authconfig.go).

DuckDNS поддерживает один выбранный IPv4 domain, который не разделяется с
canonical или другим входом. Existing AAAA — отказ до записи. Контракт —
проверка ожидаемого значения и повторная проверка после записи; [DuckDNS API](https://www.duckdns.org/spec.jsp)
не имеет atomic compare-and-swap. Другие DDNS writers выбранного домена должны
быть отключены; при изменении DNS после завершения старую операцию не переигрывать.
Свой домен/DNS API остаётся отдельной целевой задачей.

## Следующий выпуск через GitHub Actions

CLI сохраняет новую топологию на A и публикует каталог для клиентов. GitHub
Environment при этом сам не меняется. До следующего production workflow нужно
согласованно обновить его операторские настройки:

- `SERVER_ROLE_CONFIG`: текущие `public` и `inventory` из завершённой операции,
  прежние `root` и `subnet`; при замене — новый IP, generation и SSH host key.
- `DEPLOY_NODE_SSH_KEYS`: отдельный действующий deploy key для каждого физического
  узла. При замене удалить соответствие старому хосту и добавить ключ нового.
- `DEPLOY_NODE_SSH_CONNECTIONS`, если используются нестандартные SSH host/port/user.

Публичные `public`/`inventory` есть в локальном `--state/operation.json`; сверять
их с завершённой baseline на A. Не переносить туда private WG/TLS/catalog keys,
не публиковать локальный state целиком: он является операторским журналом.
Отдельный доступ CI к новому узлу настраивается осознанно; CLI не копирует SSH
private keys в GitHub автоматически. Старый identity map не считается доступом
к новому серверу. Перед workflow проверить его полноту и pinned SSH для всех
физических узлов. Это изменение конфигурации, без правок приложения.

Установленным клиентам не нужен выпуск ради нового входа: они получают подписанный
каталог. Настройка CI требуется для будущего обслуживания нового узла и не является
условием чтения каталога уже работающим клиентом.

## Предел приёмки

Сквозное подключение и замена проверяются на изолированных Linux VM с тестовыми
TLS/DNS/registry и аккаунтами. Это не реальные B/C, физические устройства, медиа
или E2EE приёмка. Пользовательские сценарии и остаток проекта фиксируются только
в `docs/user-acceptance.md`. Live external providers и аппаратные ограничения
не закрываются по synthetic fixtures.
