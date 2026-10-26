# 16 — Matrix-мост в Telegram (mautrix-telegram, Go)

> **Гость:** LXC CT 104 `brige-matrix` на узле YADR01 (имя гостя историческое — с опечаткой, менять не стал)
> **Адрес:** `172.20.6.6`, appservice-HTTP `:29317`
> **Связка:** работает в паре с homeserver'ом — [10 — Matrix: Synapse](10_Matrix_мессенджер.md)
> **Версия:** Go-сборка `mautrix-telegram v26.09` (переход с Python-версии выполнен один раз 2026-10-26;
> старый Python-мост не поддерживается и в работе не участвует)

## Что делает мост

Связывает комнаты Matrix с чатами Telegram в режиме **puppeting**: Telegram-аккаунт пользователя один раз
логинится в мост, и дальше переписка идёт от его же имени в обе стороны — в Matrix сообщения приходят от
puppet-пользователя `@telegram_<tgid>:matrix.alexrus1234.ru`, обратно уходят через тот же аккаунт.

Что этим **не** закрывается:

- **relaybot** — отдельный Telegram-бот для комнат, где у Matrix-пользователя нет своего Telegram-логина.
  В Go-версии старый relaybot не поддерживается, у нас он и не использовался (в прежнем конфиге токен был
  `disabled`), поэтому мост работает только через личные логины;
- **шифрование моста (E2EE)** — не включено: ни один портал не помечен `encrypted`, ключи не раздаются;
- **своего домена у моста нет.** Это appservice, наружу он не публикуется: Synapse ходит к нему по
  `http://172.20.6.6:29317` внутри LAN. Записи в [`05_доменные_имена.md`](../Инфраструктура/05_доменные_имена.md)
  у него нет и быть не должно.

## Как устроено взаимодействие

```
        Telegram (MTProto)                          Matrix-клиенты
                │                                          │
                ▼                                          ▼
   ┌─────────────────────────┐   appservice HTTP   ┌──────────────────┐
   │ мост CT 104             │◄────────────────────│ Synapse CT 103   │
   │ 172.20.6.6:29317        │  POST /_matrix/app/ │ 172.20.6.5:8008  │
   │ systemd: mautrix-       │  v1/transactions    │                  │
   │ telegram.service        │────────────────────►│                  │
   └───────────┬─────────────┘  client API (v3)    └──────────────────┘
               │
               ▼
   PostgreSQL `mautrix_tg` на NAS (172.20.50.10:5432)
```

Кто инициатор:

- **мост — клиент по отношению к Synapse**: сам вызывает `/_matrix/client/v3/...` от имён puppet'ов
  и слушает appservice-эндпоинты на `:29317`;
- **Synapse — клиент по отношению к мосту**: при новом событии в комнате моста он делает POST на
  `:29317` (`hs_token` в query), мост отвечает и при необходимости пишет в Telegram;
- оба конца — внутри LAN, TLS не используется (`tls_cert: false`).

## Раскладка на диске

| Путь | Что это |
| :--- | :--- |
| `/opt/mautrix-telegram/mautrix-telegram-amd64` | исполняемый файл моста (статический бинарь, ~57 МБ, владелец `mautrix`) |
| `/opt/mautrix-telegram/config.yaml` | конфиг, `0600` `mautrix:mautrix` — **единственный источник истины о настройках** |
| `/opt/mautrix-telegram/registration.yaml` | appservice-регистрация (id `telegram`, токены, namespace'ы) |
| `/opt/mautrix-telegram/env/` | venv Python-версии; в работе **не участвует**, оставлен как путь быстрого отката кода |
| `/opt/mautrix-telegram/config.yaml.pre-go`, `registration.yaml.pre-go` | копии конфигов до перехода на Go (архив, не читаются) |
| `/etc/systemd/system/mautrix-telegram.service` | юнит |

Логи в файл не пишутся: единственный writer — stdout, всё уходит в journald (`journalctl -u mautrix-telegram`).
Файловые логи Python-версии (`mautrix-telegram.log*`) больше не наполняются — старые файлы удаляются разово.

## Юнит systemd

```ini
[Unit]
Description=Mautrix-Telegram bridge
After=network.target

[Service]
Type=simple
User=mautrix
Group=mautrix
WorkingDirectory=/opt/mautrix-telegram
ExecStart=/opt/mautrix-telegram/mautrix-telegram-amd64 -c /opt/mautrix-telegram/config.yaml
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

Строка запуска Python-версии остаётся в файле закомментированной (`#OLD …`) — откат кода = раскомментировать
её, закомментировать Go-строку, `systemctl daemon-reload`, `systemctl restart mautrix-telegram`. Напоминание:
база после перехода на Go уже в новой схеме, поэтому откат кода без восстановления дампа БД (см. «Резервное
копирование») оставит Python-мост неработоспособным.

## Конфиг: что где лежит

Формат — bridgev2: общие секции на верхнем уровне, всё специфичное для Telegram — внутри `network:`.

| Секция / ключ | Значение у нас | Комментарий |
| :--- | :--- | :--- |
| `homeserver.address` | `http://172.20.6.5:8008` | клиентский API Synapse |
| `homeserver.domain` | `matrix.alexrus1234.ru` | домен MXID |
| `appservice.address` | `http://172.20.6.6:29317` | адрес, по которому Synapse зовёт мост |
| `appservice.hostname` / `port` | `0.0.0.0` / `29317` | слушает все интерфейсы, порт только LAN |
| `database` | `postgresql://mautrix_tg:***@172.20.50.10:5432/mautrix_tg` | **верхний уровень**; в Python-версии URI лежал вложенным в `appservice.database` |
| `network.api_id` / `api_hash` | ключи приложения Telegram | из `my.telegram.org`, менять нельзя — привязка к логинам |
| `network.sync.update_limit` | по умолчанию `100` (значение унаследовано из прежних `bridge.sync_*`) | сколько последних диалогов обходить при синхронизации |
| `network.sync.create_limit` | по умолчанию `15` | сколько порталов создавать за один проход |
| `network.sync.direct_chats` | `true` | личные чаты тоже становятся порталами |
| `backfill.max_catchup_messages` | по умолчанию 500 на портал | сколько пропущенного дотягивать после рестарта моста |
| `bridge.permissions` | см. ниже | уровни прав bridgev2 |
| `logging.min_level` | `info` | `debug`/`trace` дают JSON-дампы ответов Telegram — включать только для отладки |

### Права

Уровни bridgev2 — `block`, `relay`, `commands`, `user`, `admin`. Значения из Python-эпохи (`relaybot`, `full`)
недопустимы: на них мост падает с `invalid permissions level` до старта.

```yaml
bridge:
    permissions:
        '*': relay                                        # посторонние: только чтение через релей, без команд
        matrix.alexrus1234.ru: user                        # весь домен: логин и переписка от своего аккаунта
        '@AlexRus1234:matrix.alexrus1234.ru': admin        # владелец: плюс админ-команды
```

Ключом может быть MXID, домен (без `@`) или `*`; поиск идёт от точного MXID к домену и затем к `*`.

## База данных

| | |
| :--- | :--- |
| Сервер | PostgreSQL на SKLD00, `172.20.50.10:5432` (версия 18.6) |
| База и роль | `mautrix_tg` |
| Размер | ~263 МБ (дамп ~39 МБ) |
| Требование апстрима | PostgreSQL ≥ 16, база не делится с другими программами — у нас отдельная, рядом с `synapse` живёт только общий сервер |

Схема — bridgev2. Статистика порталов на момент перевода: 205 порталов (146 каналов, 16 супергрупп,
40 личных чатов, 3 мини-группы), E2EE не используется, активен один puppet-логин.

## Регистрация в Synapse

- мост: `/opt/mautrix-telegram/registration.yaml` — `id: telegram`, `url: http://172.20.6.6:29317`,
  namespace'ы `@telegram_.*`, `@telegrambot`, `#telegram_.*`, `rate_limited: false`;
- Synapse: `/opt/synapse/data/telegram-registration.yaml` — побайтовая копия, подключена в `homeserver.yaml`
  через `app_service_config_files`;
- токены (`as_token`, `hs_token`) и `sender_localpart` должны совпадать на обеих сторонах.

Обычная работа токенов не требует. Перегенерация (`mautrix-telegram -g`) — только при осознанной ротации, и тогда
порядок строгий: сгенерировать → скопировать в CT 103 → `systemctl restart matrix-synapse` → запустить мост.
Иначе Synapse отвергает запросы моста (403), а мост не получает транзакции.

## Логи и наблюдаемость

```sh
systemctl is-active mautrix-telegram            # active
ss -ltnp | grep 29317                           # LISTEN 0.0.0.0:29317
journalctl -u mautrix-telegram -n 50 --no-pager
journalctl -f -u mautrix-telegram               # живой поток
```

Признаки нормальной работы в логе: `Sent message part to Matrix … event_id=…` (сообщение ушло в Matrix),
ответ `200` на `/_matrix/app/v1/transactions/…` (Synapse доставил событие), `handle matrix event` без ошибок
(сообщение ушло в Telegram).

`WRN Telegram update handling is taking long … started_at=<время>` — большая пачка апдейтов ещё обрабатывается;
это не ошибка, а индикатор, что первичный обход/догон не закончен. `Run: end … dc_id=N` + `Generating new auth key`
— переподключение к медиа-датацентру Telegram, норма.

## Обновление версии

Миграций схемы между релизами `v26.04+` нет: обновление — замена бинаря и рестарт.

```sh
cd /opt/mautrix-telegram
cp -a mautrix-telegram-amd64 mautrix-telegram-amd64.prev     # путь отката версии
curl -fsSLO https://github.com/mautrix/telegram/releases/download/<тег>/mautrix-telegram-amd64
curl -fsSLO https://github.com/mautrix/telegram/releases/download/<тег>/sha256sums.txt
grep 'mautrix-telegram-amd64$' sha256sums.txt | sha256sum -c -
chmod +x mautrix-telegram-amd64 && chown mautrix:mautrix mautrix-telegram-amd64
systemctl restart mautrix-telegram
systemctl is-active mautrix-telegram
```

Регистрация и конфиг при этом не трогаются. Если новая версия ведёт себя неправильно — остановить юнит, вернуть
`mautrix-telegram-amd64.prev` на место бинаря, запустить; схема БД между релизами не меняется, поэтому откат
версии безопасен.

## Резервное копирование

Контейнер (`vzdump`/`pct snapshot`) закрывает код, конфиг и регистрацию — **но не базу**: она на NAS.

```sh
sudo -u postgres pg_dump -Fc -d mautrix_tg -f /tank/pg-dumps/mautrix_tg-$(date +%F-%H%M).dump
sudo pg_restore --list /tank/pg-dumps/mautrix_tg-<штамп>.dump | head -5   # проверить, что дамп читается
```

Восстановление — только при остановленном мосте:

```sh
systemctl stop mautrix-telegram
sudo -u postgres pg_restore -d mautrix_tg --clean --if-exists /tank/pg-dumps/mautrix_tg-<штамп>.dump
systemctl start mautrix-telegram
```

Медиа в резервной копии не нужны: файлы живут в Telegram, локальной медиатеки у моста нет.

## Диагностика

| Симптом | Что смотреть |
| :--- | :--- |
| сообщения не идут в Matrix | `journalctl -u mautrix-telegram -n 50`, ответы на `/_matrix/app/v1/transactions`; если 403 — рассинхрон токенов с `telegram-registration.yaml` |
| сообщения не идут в Telegram | `handle matrix event` + ошибки MTProto рядом; при `AuthKeyUnregistered` нужен повторный логин через `!tg login` |
| мост не поднимается | `Failed to parse config: …` — конфиг невалиден (см. «Грабли»), `journalctl` показывает строку ошибки целиком |
| лавина уведомлений после рестарта | это `backfill.max_catchup_messages` дотягивает пропущенное. Петля отличается тем, что в логе повторяются **одни и те же** `msgid` без строки `Ignoring duplicate message` |
| порталов стало больше/меньше | `select peer_type, megagroup, count(*) from portal group by 1,2` в базе `mautrix_tg` |

Команды в чате: `!tg help` печатает актуальный список (он зависит от версии бинаря). Из рабочих:
`sync-chats` — переобойти диалоги, `upgrade` — превратить мини-группу в супергруппу, `join` — войти в чат по инвайт-ссылке,
`login` / `logout` — управление Telegram-логином, `set-management-room` — назначить комнату управления (в ней команды
работают без префикса `!tg`).

## Грабли

- **`sed -i` от root ломает владельца конфига.** Правка `config.yaml` под root оставляет файл `root:root 0600`,
  и мост под `mautrix` его не прочитает. После любой правки — `chown mautrix:mautrix /opt/mautrix-telegram/config.yaml`.
- **Конфиг лежит в `/opt/mautrix-telegram`, а не в `/etc/mautrix-telegram`.** Grep по `/etc` даёт пустоту, и все
  секции выглядят «отсутствующими».
- **Уровни прав — только bridgev2.** `relaybot` и `full` из Python-эпохи роняют старт с
  `invalid permissions level`: `relaybot` → `relay`, `full` → `user`.
- **Токен бота вида `disabled` — это не «бот настроен»**, а «бота нет»: мост отбрасывает всё, что начинается
  с `disable`. Наличие `@telegrambot` в namespace'ах registration ничего не доказывает — это дефолт
  `appservice.bot_username`.
- **Перерегистрация без рестарта Synapse** даёт 403 на транзакциях: мост и Synapse должны видеть одни токены
  одновременно.
- **Первый запуск после крупного обновления/рестарта — это догон, а не сбой**: волна уведомлений приходит
  из уже существующих комнат, ограничена `backfill.max_catchup_messages` и затухает сама.
- **Файловые логи не нужны**: stdout уходит в journald, ротацией занимается systemd; файловый writer только
  растит диск контейнера (8 ГБ rootfs).

## Связанные документы

- [10 — Matrix: Synapse](10_Matrix_мессенджер.md) — homeserver, СУБД, медиа в S3, вывод наружу через VPS и Coturn
- [03 — NAS: базы данных и S3](03_NAS_базы_данных_и_S3.md) — PostgreSQL, к которому ходит мост
- [00 — карта железа и сервисов](../Инфраструктура/00_карта_железа_и_сервисов.md), [01 — архитектура и сеть](../Инфраструктура/01_архитектура_и_сеть.md)
- [контейнеры/element-web](контейнеры/element-web/README.md) — веб-клиент, с которым мост работает в паре
