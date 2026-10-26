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
| `network.sync.update_limit` | `20` (в bridgev2 по умолчанию `100`) | сколько последних диалогов обходить при синхронизации; снижено, чтобы старт не тонул в обходе 205 диалогов |
| `network.sync.create_limit` | по умолчанию `15` | сколько порталов создавать за один проход |
| `network.sync.direct_chats` | `true` | личные чаты тоже становятся порталами |
| `network.member_list.max_initial_sync` | `0` (по умолчанию `100`) | сколько участников подтягивать в портал при старте; `0` — не тянуть заранее, участники появятся по мере того, как сами напишут. Снижено вместе с `update_limit`: синхронизация участников тянет профиль и аватар на каждого, и старт на 205 порталах перестаёт успевать за потоком |
| `backfill.max_catchup_messages` | по умолчанию 500 на портал | сколько пропущенного дотягивать после рестарта моста |
| `network.max_member_count` | `-1` | порог размера для **супергрупп** (broadcast-каналы не проверяются); `-1` — без ограничения, см. «Порталы и приглашения» |
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

## Порталы и приглашения: что создаётся автоматически

Мост держит по порталу на каждый чат Telegram и при создании портала приглашает владельца логина в новую
Matrix-комнату. Создание происходит в двух случаях: при синхронизации диалогов (не больше
`network.sync.create_limit` порталов за проход) и по входящему сообщению из чата, у которого комнаты ещё нет
(каждое сообщение ставит `CreatePortal: true`). Приглашение приходит **один раз на чат**: если у портала уже есть
комната, новых приглашений не будет.

Выход из комнаты ничего не пересоздаёт: при `leave` мост отбрасывает событие (пока `bridge.bridge_matrix_leave:
false`), комната и портал остаются. Поэтому поток приглашений после переезда на новую версию — это комнаты для
чатов, у которых их ещё не было, по одной на чат, а не повторные приглашения в те же комнаты.

Создание ограничивается пятью ключами (все действуют **только в момент создания**, уже связанные комнаты не
затрагиваются):

| Ключ | Смысл |
| :--- | :--- |
| `network.max_member_count` | не создавать портал, если участников больше N. **Действует только на супергруппы** (`Megagroup`): broadcast-каналы проверку не проходят и создаются при любом размере. У нас `-1` (без ограничения) |
| `bridge.portal_create_filter.mode: allow` + `list` | создавать только перечисленные чаты. **Пустой список = не создавать ничего автоматически**, и тогда личное сообщение от нового человека в Matrix не придёт — только в Telegram |
| `bridge.portal_create_filter.mode: deny` + `list` | создавать всё, кроме перечисленного (точечные исключения из общего потока) |
| `network.sync.direct_chats` | создавать ли порталы для личных чатов при синхронизации |
| `network.sync.create_limit` | сколько порталов создаётся за один проход синхронизации |

Три следствия, которые важно держать в голове:

- порог по размеру **не спасает от каналов** — их он не проверяет вообще;
- порог проверяется при получении сведений о чате, поэтому блокирует и ручные команды: большую супергруппу не
  связать ни `!tg join`, ни `!tg bridge`, пока порог ниже её размера. Если такая группа нужна — временно поднять
  `max_member_count` (`-1`), рестарт, связать, вернуть значение: созданная комната остаётся, порог действует только
  при создании;
- уже связанные большие чаты порог не затрагивает — они в ветку создания не попадают. Исключение: если такой
  портал отвязать (`!tg unbridge`), новая комната для него уже не создастся.

### Сколько чатов ещё ждёт приглашения

Ответ даёт база, без захода в комнаты (SKLD00):

```sh
# сколько всего порталов и сколько ещё без комнаты
sudo -u postgres psql -d mautrix_tg -Atc "select count(*) as всего, count(*) filter (where coalesce(mxid,'')='') as без_комнаты from portal"

# кто именно ещё «выстрелит» приглашением
sudo -u postgres psql -d mautrix_tg -Atc "select id, name from portal where coalesce(mxid,'')='' order by name"
```

Поток конечен: каждому чату комната создаётся один раз. Два способа его закрыть — принять и выйти вручную (выход
безопасен, повторного приглашения по этому чату не будет), либо запретить создание списком `deny`. Список для
`deny` генерируется из базы, без ручного набора; эта команда печатает готовые строки YAML для каналов и групп **без
комнаты**, исключая личные чаты:

```sh
sudo -u postgres psql -d mautrix_tg -Atc "select '            - ' || id from portal where coalesce(mxid,'')='' and id not like 'user:%' order by id"
```

Считать надо не строки, а чаты: после миграции часть порталов заведена дважды — `channel:1664906567` и
`channel:1664906567:-1`. Суффикс — «получатель» портала (пара чат + логин), и фильтр по короткому ID его **не ловит**:
запрет на `channel:1664906567` комнату для `channel:1664906567:-1` не остановит. У нас на 101 записи пришлось
64 уникальных чата, то есть 37 чатов стучатся по два раза. Поэтому список собирается по второму полю ID:

```sh
# сразу готовый файл для tg-deny from-file, исключая нужные чаты по их ID
sudo -u postgres psql -d mautrix_tg -Atc "select id from portal where coalesce(mxid,'')='' and split_part(id,':',1) in ('channel','chat') and split_part(id,':',2) not in ('1703721750','1767686479','2240261097','1916957909') order by id" > ~/deny-rest.txt
```

Названий у таких порталов обычно нет: мост ни разу не получал сведений о чате, поэтому `name` пустой — «кто из них кто»
по базе не отвечается, только по факту прихода сообщения. Практика: остаток банится целиком, а нужный чат, попавший
туда по ошибке, снимается одной командой `tg-deny del <id>`.

### Скрипт `tg-deny` — ведение списка запретов

Список в конфиге ведёт скрипт `tools/tg-deny` из этого репозитория (bash + `python3` из venv моста, без
зависимостей). Ставится на CT 104:

```sh
install -m 0755 tools/tg-deny /usr/local/bin/tg-deny
tg-deny help
```

Без аргументов и с `help` он печатает справку — что делает, формат ID и порядок действий.

| Команда | Что делает |
| :--- | :--- |
| `tg-deny list` | показать запрещённые чаты |
| `tg-deny add <id> [<id> …]` | запретить создание портала, применить, перезапустить мост |
| `tg-deny del <id> [<id> …]` | снять запрет (чат снова начнёт приходить) |
| `tg-deny check <id>` | есть ли чат в списке (код возврата 0 — да) |
| `tg-deny from-file <файл>` | добавить пачкой, по одному ID в строке, `#` — комментарий |

Что он делает с конфигом: правит **только строки между маркерами** `# >>> tg-deny: managed` и
`# <<< tg-deny: end` внутри `bridge.portal_create_filter.list`, перед правкой кладёт рядом
`config.yaml.bak-<штамп>`, возвращает владельца `mautrix:mautrix`, перезапускает юнит и ждёт `active` до 20 секунд.
Если мост не поднялся — сам возвращает бэкап и перезапускает с ним. Хранит 20 последних бэкапов.

Секция `portal_create_filter` в конфиге уже есть (её приносит миграция) — в виде `mode: deny` и **inline-пустого**
`list: []`. Скрипт это учитывает: inline-список превращается в блочный, а если в нём уже что-то перечислено —
элементы забираются в управляемый блок (маркеры), ничего не теряется. Отдельно он понимает `mode: allow`
и не переключает режим сам.

Если после правки YAML не парсится, скрипт печатает причину (`YAML не парсится: DuplicateKeyError …`), сохраняет
сгенерированный вариант рядом как `config.yaml.invalid-<штамп>` и возвращает исходный конфиг — мост при этом не
перезапускается. Такой файл и есть материал для разбора: `diff` с рабочим конфигом показывает, что именно не так.

Порядок для одного чата (важен именно такой):

1. в комнате: `!tg id` — записать ID;
2. в комнате: `!tg unbridge` — мост удаляет комнату и очищает `mxid`;
3. в шелле: `tg-deny add channel:-100…`.

Без шага 2 фильтр не поможет: он действует при создании комнаты, а приглашение по существующему порталу приходит
независимо от списка. Возврат: `tg-deny del <id>`, затем `!tg create-portal <id>` либо просто дождаться сообщения.

### Как добавить новый чат

Численный ID нужен не всегда — для нового чата есть путь через ссылку:

| Задача | Команда |
| :--- | :--- |
| Вступить в новый чат и завести портал | `!tg join <ссылка или username>` — принимает `t.me/+hash`, `t.me/joinchat/…` и `t.me/<username>`; мост сам резолвит чат через Telegram API и после вступления создаёт портал |
| Создать комнату для чата, который уже есть в базе, но без комнаты | `!tg create-portal <chat ID>` |
| Привязать **свою** Matrix-комнату к чату | `!tg bridge <chat ID>` (выполняется в этой комнате) |
| Начать личный чат с человеком | `!tg start-chat <username или телефон>` — дальше портал создаётся сам |

Порядок при включённом фильтре: сначала `join`, потом при необходимости `!tg filter allow <chat ID>` — без записи в
списке портал не появится, потому что событие из чата отбрасывается.

### Как узнать ID чата

1. В уже связанной комнате — команда `!tg id`:
   ```
   This room is bridged to channel:-1001234567890 on Telegram
   ```
   Значение в обратных кавычках и есть ID: `channel:-100…` для каналов и супергрупп, `user:…` для личных чатов.
2. Из ссылки на любое сообщение в приватной супергруппе: `t.me/c/2691256007/123` → ID `channel:-1002691256007`
   (префикс `-100` плюс число из ссылки).
3. Из базы — все порталы с именами (SKLD00):
   ```sh
   sudo -u postgres psql -d mautrix_tg -Atc "select id, name from portal order by name"
   ```
4. Из журнала — при создании портала мост пишет `portal_id=…`.

### Как внести чат в белый список (allow)

```yaml
bridge:
    portal_create_filter:
        mode: allow
        list:
            - channel:-1001234567890
            - user:123456789
        always_deny_from_login: []
```

```sh
chown mautrix:mautrix /opt/mautrix-telegram/config.yaml
systemctl restart mautrix-telegram
```

В этом режиме всё, чего нет в списке, автоматически не создаётся — а нужные чаты связываются либо добавлением ID в
список, либо вручную (см. ниже).

### Ручное связывание

```
!tg bridge <chat ID>
```

Команда выполняется в той Matrix-комнате, которую нужно связать с чатом, и идёт мимо фильтра автоматического
создания — это способ завести нужный чат при `mode: allow` с пустым списком.

Команда `!tg filter deny|allow <chat ID>` тоже умеет править список, но её изменения **только в памяти** (справка
апстрима: «Changes are currently in-memory only») и теряются при рестарте. Постоянный список — только через конфиг.

### Чего не делать

- `!tg delete-chat` — удаляет чат **в Telegram**, а не комнату в Matrix;
- `!tg unbridge` — отвязывает портал и удаляет Matrix-комнату; при пустом allow-списке обратно она не создастся,
  при `deny` или без фильтра — может быть создана заново при следующем событии.

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

## 403 при публикации в комнату (комнаты Python-эпохи)

Симптом в журнале:

```
ERR Failed to send message part to Matrix error="M_FORBIDDEN (HTTP 403): You don't have permission to post
    that to the room. user_level (0) < send_level (50)" portal_id=channel:2479181954 portal_mxid=!…
    sender=channel-2479181954 remote_message_id=…
```

Причина: комнаты, созданные прежней (Python) версией моста, выдали 100 только `@telegrambot`, а ghost канала
`@telegram_channel-<id>` в `m.room.power_levels` отсутствует — у него `user_level` 0 при требуемых 50. Комнаты,
созданные текущей версией, ghost'а в правах содержат и не болеют.

Последствие двойное: сообщение в Matrix не попадает **и** обработка этого события зависает, задерживая всю очередь
(см. «Логи и наблюдаемость»). Поэтому «в комнате идёт переписка» и «в логе 403» спокойно сосуществуют — часть
событий проходит, часть клинит.

По каждому такому чату:

| Чат | Что делать |
| :--- | :--- |
| нужен в Matrix | в комнате `!tg unbridge`, дальше следующее сообщение канала создаёт комнату с правильными правами. История комнаты в Matrix теряется, в Telegram остаётся |
| нужен только в Telegram | в комнате `!tg unbridge`, затем `tg-deny add <id>` — иначе комната создастся заново |
| нужен, история важна | править `power_levels` под `@telegrambot` (у него 100 в этих комнатах): токен выдаёт admin API `POST /_synapse/admin/v1/users/<mxid>/login`, затем `PUT …/state/m.room.power_levels` с добавлением ghost'а на 100. Своим токеном это не сделать — у него в этих комнатах 0, а вход по паролю отключён |

Проверить одну комнату (SKLD00):

```sh
set +H
sudo -u postgres psql -d synapse -Atc "select ej.json::jsonb->'content'->'users' from current_state_events cse join event_json ej on ej.event_id=cse.event_id where cse.type='m.room.power_levels' and cse.room_id='!…:matrix.alexrus1234.ru'"
```

Полный обход — сверка списка порталов с правами комнат (печатает ID каналов, у которых ghost'а в правах нет):

```sh
set +H; sudo -v
sudo -u postgres psql -d mautrix_tg -Atc "select id, mxid from portal where id like 'channel:%' and coalesce(mxid,'')<>''" > /root/portals.tsv
: > /root/broken.txt
while IFS='|' read -r pid mxid; do
    ghost="@telegram_${pid/channel:/channel-}:matrix.alexrus1234.ru"
    has=$(sudo -u postgres psql -d synapse -Atc "select coalesce((ej.json::jsonb->'content'->'users') ? '$ghost', false) from current_state_events cse join event_json ej on ej.event_id=cse.event_id where cse.type='m.room.power_levels' and cse.room_id='$mxid'" | tr -d '\r')
    [ "$has" = "t" ] || echo "$pid" >> /root/broken.txt
done < /root/portals.tsv
echo "комнат без ghost'а: $(wc -l < /root/broken.txt)"
```

## Логи и наблюдаемость

```sh
systemctl is-active mautrix-telegram            # active
ss -ltnp | grep 29317                           # LISTEN 0.0.0.0:29317
journalctl -u mautrix-telegram -n 50 --no-pager
journalctl -f -u mautrix-telegram               # живой поток
```

Признаки нормальной работы в логе: `Sent message part to Matrix … event_id=…` (сообщение ушло в Matrix),
ответ `200` на `/_matrix/app/v1/transactions/…` (Synapse доставил событие), `handle matrix event` без ошибок
(сообщение ушло в Telegram). `Run: end … dc_id=N` + `Generating new auth key` — переподключение к медиа-датацентру
Telegram, норма.

`WRN Telegram update handling is taking long … started_at=<время>` — пачка апдейтов ещё обрабатывается. Сама по себе
строка безобидна, если `started_at` в ней **меняется** (каждая запись — новая пачка) и рядом идут `Sent message part`.

Клин отличается так:

- `started_at` в `taking long` **не меняется** десятки минут — обработка стоит на одном и том же месте;
- `Sent message part` за это время не появляется ни одного, входящие из Telegram не доходят до Matrix;
- бот сам присылает в Matrix: `State update for <user>: UNKNOWN_ERROR (tg-update-handler-stuck): Processing messages from
  Telegram is stuck` — это watchdog моста, он видит, что не успевает обрабатывать апдейты.

Застрявшее событие видно отдельной строкой — по ней и надо идти:

```
WRN Event handling is taking long action="handle remote event" bridge_evt_type=RemoteEventMessage
    portal_id=channel:… portal_mxid=!… sender=channel-… started_at=…
```

Чаще всего это публикация в комнату, куда мост не имеет прав (403, см. «403 при публикации в комнату»): событие
не может завершиться и держит очередь. Порядок действий — убрать такие комнаты из-под моста (`!tg unbridge` +
`tg-deny add`), затем `systemctl restart mautrix-telegram`.

```sh
journalctl -u mautrix-telegram | grep 'taking long' | tail -2          # меняется ли started_at
journalctl -u mautrix-telegram --since '-5 min' | grep -c 'Sent message part'
journalctl -u mautrix-telegram --since '-5 min' | grep -cE 'M_FORBIDDEN|taking long'
```

Если клин повторяется на пустом месте (403 нет, а `started_at` замер) — снять стек процесса и разбирать его:

```sh
kill -QUIT "$(systemctl show -p MainPID --value mautrix-telegram)"
journalctl -u mautrix-telegram --since '-1 min' --no-pager | head -120
```

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
| уведомления идут, а часть комнат молчит | `M_FORBIDDEN … user_level (0) < send_level (50)` — комнаты Python-эпохи без ghost'а в правах, см. «403 при публикации в комнату» |
| входящие из Telegram не доходят, `taking long` с одним и тем же `started_at` | клин очереди; искать `Event handling is taking long … portal_id=…` и убирать эту комнату из-под моста, см. «Логи и наблюдаемость» |
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
  из уже существующих комнат, ограничена `backfill.max_catchup_messages` и затухает сама. Отличие от клина —
  `started_at` в `taking long` меняется, а `Sent message part` идёт.
- **`taking long` — не всегда безобидно.** Если `started_at` замер, `Sent message part` нет, а бот пишет
  `UNKNOWN_ERROR (tg-update-handler-stuck)`, это остановка очереди; лечится не рестартом (он повторяется через
  полминуты), а устранением комнат, куда мост не может писать.
- **Комнаты, созданные Python-версией, содержат в правах только `@telegrambot`.** В них мост не может постить от
  имени канала — отсюда 403 и зависания. Признак: сообщения в комнате идут, но часть публикаций в лог падает.
- **`list: []` в конфиге — валидный YAML**, но именно на нём спотыкались скрипты, ищущие строку `list:`.
  `tg-deny` такой список понимает и переводит в блочный вид.
- **Один чат может быть заведён двумя порталами:** `channel:X` и `channel:X:-1`. Запрет по короткому ID второй не
  покрывает, и приглашение приходит как будто «из забаненного» чата. Список собирать по `split_part(id,':',2)`.
- **Принятие приглашения в комнату канала ничего не даёт.** В логе при этом `ERR Failed to handle Matrix membership
  change error="unsupported channel membership change type invite -> join"`: вы уже подписаны на канал в Telegram,
  повторно «вступить» нельзя. Ошибка безвредна, комнату можно просто покинуть.
- **Файловые логи не нужны**: stdout уходит в journald, ротацией занимается systemd; файловый writer только
  растит диск контейнера (8 ГБ rootfs).

## Связанные документы

- [10 — Matrix: Synapse](10_Matrix_мессенджер.md) — homeserver, СУБД, медиа в S3, вывод наружу через VPS и Coturn
- [03 — NAS: базы данных и S3](03_NAS_базы_данных_и_S3.md) — PostgreSQL, к которому ходит мост
- [00 — карта железа и сервисов](../Инфраструктура/00_карта_железа_и_сервисов.md), [01 — архитектура и сеть](../Инфраструктура/01_архитектура_и_сеть.md)
- [контейнеры/element-web](контейнеры/element-web/README.md) — веб-клиент, с которым мост работает в паре
