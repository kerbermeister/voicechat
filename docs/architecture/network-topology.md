# Сетевая топология VoiceChat: от одного VPS к нескольким входам

29 октября 2026. Production работает по первой схеме: один VPS A с отдельными
core и cohost edge-a, shared-front и сохранёнными данными/identity. Переход выполнен
[run51](../iterations/three-vps-evidence/2026-10-29-production-initial-postcheck.json).
Схема расширения B/C/D/E ниже — целевая, дополнительные VPS ещё не подключены. Основание:
[ТЗ](../three-vps-spec.md), [план](../tasks/19-three-vps.md),
[проверки и ограничения](../iterations/19-three-vps.md).

## Начало: один физический VPS

```mermaid
flowchart LR
    U["Клиенты: Android, macOS, web<br/>будущий Windows — тот же контракт"]
    subgraph VPS["Один VPS: две отдельные роли"]
        subgraph E["edge-a · отдельный Compose project"]
            I["HAProxy :443<br/>HTTPS и TURN/TLS по SNI"]
            W["Caddy<br/>web, API/WSS proxy, каталог входов"]
            T["coturn<br/>временный медиарелей"]
            I -->|"API / сайт"| W
            I -->|"TURN TLS"| T
        end
        P["Приватный адрес A<br/>wg-vc, без удалённых peers"]
        subgraph A["core A · прежние данные и identity"]
            API["Synapse + control<br/>авторизация, чаты, управление звонком"]
            SFU["LiveKit SFU"]
            DB[("PostgreSQL, SQLite,<br/>зашифрованные вложения")]
            API --> DB
        end
        W -->|"Локальный путь к private IP"| P
        P -->|"8088 / 8090"| API
        P -->|"7880 · signaling"| SFU
        T -->|"Медиа к SFU"| SFU
    end
    U -->|"HTTPS / WSS / TURN TLS :443"| I
    U -->|"TURN UDP/TCP :3478"| T
```

Один VPS остаётся одной точкой отказа. Разделение ролей готовит последующий перенос,
но ещё не даёт резервирования. Private IP должен существовать даже без удалённых
серверов; два проекта не могут одновременно делить публичные порты со старым
single-host web/TURN. Этот переход требует отдельной миграции.

Если на том же VPS уже работает другой сайт, общий порт 443 принадлежит отдельному
shared-front. Он не зависит от `voicechat-network.service` и не управляется edge
deploy/stop. Ниже профиль текущего VPS после production миграции.

```mermaid
flowchart LR
    U["Клиент TLS :443"] --> F["Общий HAProxy shared-front<br/>только SNI, без TLS-ключей"]
    F -->|"VoiceChat HTTPS · PROXY v2"| W["edge-a Caddy :8443"]
    F -->|"TURN имя"| T["edge-a coturn :5349"]
    F -->|"Остальные SNI · PROXY v2<br/>отдельный bridge /29"| L["Прежний Caddy<br/>соседний сайт"]
    H["HTTP :80<br/>ACME HTTP-01"] --> L
    W -->|"private IP · wg-vc"| A["Core A"]
    G["voicechat-network.service"] -.->|"Разрешает запуск только VoiceChat"| W
    G -.-> A
```

Shared-front владеет постоянным edge bridge; edge использует его как external
network и не удаляет при остановке. Caddy edge доверяет PROXY v2 только точному
адресу shared-front. Соседний Caddy получает отдельный точный адрес доверия на /29.
Отказ приватной сети должен закрывать VoiceChat, сохраняя TLS соседнего сайта;
это отдельная обязательная проверка перед production. Dedicated B/C сохраняют
свой HAProxy внутри роли edge. Изменение shared-front требует полного согласованного
rollout; web-only не меняет его конфигурацию.

## После расширения: один core, произвольное число входов

```mermaid
flowchart LR
    U["Клиент<br/>выбор доступного входа<br/>и сохранение сессии"]
    B["VPS B · edge<br/>HAProxy + Caddy + coturn"]
    C["VPS C · edge<br/>HAProxy + Caddy + coturn"]
    D["VPS D / E / … · edge<br/>тот же код и шаблоны"]
    subgraph A["VPS A · единственный core с рабочими данными"]
        WG["WireGuard · wg-vc<br/>отдельный peer/key каждого входа"]
        API["Private API<br/>Matrix :8088 · control :8090"]
        SIGNAL["LiveKit signaling :7880"]
        SFU["LiveKit SFU<br/>медиапорт TCP :7981<br/>UDP :50300–50400"]
        DB[("Единственная серверная копия<br/>БД, identity, история, вложения")]
        WG --> API
        WG --> SIGNAL
        API --> DB
        SIGNAL --> SFU
    end
    U -->|"HTTPS/WSS или TURN"| B
    U -->|"Резервный путь"| C
    U -->|"Из подписанного каталога"| D
    B -->|"API/WSS внутри WireGuard · UDP :51820"| WG
    C -->|"Свой WireGuard peer"| WG
    D -->|"Свой WireGuard peer"| WG
    B -->|"TURN → публичный медиапорт SFU"| SFU
    C -->|"TURN → публичный медиапорт SFU"| SFU
    D -->|"TURN → публичный медиапорт SFU"| SFU
    BACKUP[("Внешняя резервная копия<br/>целевой этап после MVP")]
    DB -.->|"Будущая согласованная выгрузка"| BACKUP
```

Здесь два разных сетевых пути:

| Что передаём | Путь и защита |
| --- | --- |
| Вход, сообщения, файлы, управление звонком | Клиент → HTTPS edge → WireGuard → API A. Пользовательская авторизация выполняется на A. |
| Сигнализация LiveKit | Клиент → WSS edge → WireGuard → LiveKit на A. |
| Медиа через SFU | Клиент → TURN на доступном edge → публичный медиапорт SFU A. Firewall допускает входы из inventory, прямой доступ клиента к SFU закрыт. Внешний адрес A должен быть доступен самому edge. |
| Личный WebRTC/P2P путь | ICE выбирает прямое соединение участников или TURN. Эти потоки не обязаны проходить через SFU A. |
| Push callback (новые подписки) | Synapse на A → private IP A:8090 → control; затем HTTPS к push provider. Для старых pushers ещё требуется миграция URL. |
| Выбор/обновление входов | HTTPS readiness и проверяемый подписанный каталог на известных edge; приватный ключ подписи хранится отдельно. |

В текущем конфиге **TURN→SFU идёт к публичному медиапорту A, не через WireGuard**.
Общий запрет private/metadata peers у coturn сохранён. Закрытый SFU через туннель
потребовал бы отдельно согласованного узкого исключения и медиапроверки; на схеме
такая возможность не выдаётся за реализованную. WireGuard защищает межсерверный
API/WSS участок и не заменяет E2EE пользовательских данных и медиапотоков.

У входов нет рабочих БД и пользовательского media storage. Они имеют только
необходимые своей роли TLS/TURN/tunnel credentials, публичные web/update assets,
каталог и ограниченные служебные логи. B/C/D не зависят от связи друг с другом.
У каждого физического узла свой WireGuard-ключ; `AllowedIPs` ограничены /32.
Список peers не заменяет ACL: фильтр разрешает через туннель только API/signaling,
запрещает транзит в другие сети и учитывает исходный порт до Docker DNAT.
В одноузловой схеме к API допускаются локальные web/health, к медиа — coturn.

## Добавление входа и переключение

```mermaid
sequenceDiagram
    participant O as Администратор / deploy
    participant N as Новый edge D
    participant A as Core A
    participant B as Известный клиенту edge B
    participant U as Установленный клиент
    O->>N: Подготовка хоста, уникальные ключи, TLS и роль edge
    O->>A: Добавление WireGuard peer D и разрешённых путей
    O->>N: Проверка API, WSS и TURN
    O->>B: Новый подписанный каталог с D
    O->>N: Тот же подписанный каталог
    U->>B: Получение каталога через известный адрес
    U->>U: Проверка подписи, identity, срока и revision
    U->>N: Проверка готовности нового пути
    Note over U,B: B становится недоступен
    U->>N: API/WSS через D, прежний профиль и ключи
    N->>A: Запросы через свой WireGuard peer
    Note over U,A: При необходимости медиа восстанавливается с актуальным TURN
```

Выпуск/распространение каталога и подготовка хоста — отдельные операции. Один новый
IP в конфиге не устанавливает ПО, не выпускает TLS и не создаёт firewall. Конечная
автоматизация должна выполнять эти шаги; её полный rollout ещё не завершён.
Хотя бы один ранее известный клиенту адрес должен оставаться доступен, иначе клиент
не узнает о новом D. Замена C не требует доступа к диску старого C.

## Что уже подтверждено локально

- Один bootstrap entry расширяется подписанным каталогом без новой сборки клиента;
  после отказа старых входов сохранены native Matrix profile и расшифровка файлов.
- Настоящий macOS LiveKit resume и full restart через другой proxy с доставкой
  данных и сохранением key provider. Это не приёмка расшифрованного звука/экрана.
- Настоящие Linux WireGuard B→A/C→A, замена ключа B, отказ старому ключу без restart A,
  сохранение C и приватный адрес единственного A без peers.
- Scoped firewall и его atomic apply/resume прошли локальный Linux kernel fixture:
  INPUT/FORWARD, DNAT, отказ постороннему клиенту/транзиту, совмещённые роли.
- Схемы/генераторы ролей и guarded role manifests. Полный host bootstrap,
  TLS renewal, CI rollout/rollback и production миграция остаются открытыми.

Без внешней копии потеря A означает потерю единственной серверной копии данных.
Дополнительные входы защищают доступность сетевого пути, но не заменяют backup A.
