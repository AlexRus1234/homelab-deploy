# skld00 — Incus-склад образов (LXC-base)

> **Узел:** SKLD00 (bare-metal NAS, паспорт: [`docs/Узлы/SKLD00_NAS.md`](../../docs/Узлы/SKLD00_NAS.md))
> **Адрес:** `172.20.50.1` (`skld00.lan`), сегмент `172.20.50.0/24`; P2P-линк до YADR01 — `172.21.6.249`
> **Роль (новая, с 2026-10-11):** склад образов системных LXC-контейнеров — Incus-сервер
> как источник образов для остальных хостов лабы. Решение — `0_ЦОД/lxc-build/docs/step-2-sborka-i-sklad.md`.

## Почему skld00

Самый статичный узел лабы; склад не должен жить в домене отказа хостов, которые он кормит.
Склад не в рантайме: после кеширования образа на хосте-потребителе склад нужен только для
новых инстансов и обновления кеша. Вторая копия артефактов — `incus image export` вне
хостов-клиентов.

Все команды — через клиент локальной сборки `incus-loc` (пакет из личного rpm-md,
`zypper-sle-alexrus1234`): суффикс `-loc`, состояние в `/var/lib/incus-loc`
(обёртка `/usr/bin/incus-loc` выставляет `INCUS_DIR` сама), демон — юнит
`incus-loc.service` / сокет `incus-loc.socket`.

## Конфигурация (финальная настройка, 2026-10-11)

| Параметр | Значение |
| :--- | :--- |
| API | `sudo incus-loc config set core.https_address=:8443` — выполнено 2026-10-11, слушает `172.20.50.1:8443`, `GET /` отвечает 200 |
| Доступ | токен доверия на каждого потребителя (`incus-loc config trust add <имя>`), публичный режим отклонён |
| Хранилище образов | ZFS-датасет `tank/incus` (pool `tank`), отдельно от данных NAS |
| Образы | `leap16-base` (специальная база, CI `Build/lxc-build`); Slowroll-база — позже |

### Доверие

Токены доверия (`config trust add`) — **одноразовые**: годятся для разового подключения
хоста, для CI не подходят (каждый прогон — новый клиентский ключ). Поэтому:

| Имя | Тип | Кому | Назначение |
| :--- | :--- | :--- | :--- |
| `ci-lxc-build` | клиентский сертификат (EC P-384, CN=ci-lxc-build) | job-контейнеру Forgejo Runner | публикация образов из CI (`Build/lxc-build`, секреты `SKLD00_CLIENT_CRT`/`SKLD00_CLIENT_KEY`); добавлен через `config trust add-certificate` |
| _(по мере подключения хостов)_ | одноразовый токен | хосты-потребители | `incus-loc remote add skld <token>` → `incus-loc launch skld:<alias> <имя>` |

Секреты — в Forgejo/общем secrets-потоке, не в репозитории.

## GitOps-агент узла (pull-модель, как у ВМ)

Узел получает свою декларацию из этого же репозитория тем же механизмом, что ВМ `obshaga`/`panelka`:
`adnanh/webhook` на `:9002` принимает POST от Forgejo (проверка HMAC `X-Gitea-Signature`) и запускает
`servers/skld00/sync-state.sh`, который делает `git pull` в sparse-checkout **только** `servers/skld00/`
и вызывает `reconcile.sh`.

Порт `9002`, а не конвенционный `9000`: на этом узле `:9000` занят RustFS — S3-хранилищем Forgejo
(`172.21.6.249:9000`), поэтому агент посажен на свободный порт.

| | |
| :--- | :--- |
| Рабочий каталог | `/opt/appdata` (клон — `/opt/appdata/git-repo`) |
| Sparse-checkout | `servers/skld00` |
| Агент | системный юнит `webhook.service` под `root` (`User=root`), бинарь `/usr/local/bin/webhook` |
| Хук | `sync-skld00`, `command-working-directory=/opt/appdata`, `execute-command=/opt/appdata/git-repo/servers/skld00/sync-state.sh` |
| Конфиг webhook | `/opt/appdata/config/webhook/hooks.json` (0600), юнит `/etc/systemd/system/webhook.service`, порт `9002` |
| Декларации сервисов | `servers/skld00/services/<имя>.yaml` — формат в `services/README.md` |
| Применение | `reconcile.sh`: создание инстанса по декларации + health-gate; скалярные правки — `incus config set` живьём; смена состава — сообщает «нужен recreate» (путь recreate — следующий шаг) |
| Выключатель автоматики | файл `/etc/lxc-automation.off`: пока он есть, `reconcile.sh` ничего не меняет (только отчёт) — отладочный этап, первый запуск делается руками (см. `services/README.md`) |
| Отчёт | строки в `/var/lib/lxc-update/status`: имя, действие, результат, подробности, длительность |

Для регистрации хука в Forgejo: репозиторий `AlexRus1234/homelab-deploy` → Settings → Webhooks →
Add webhook (Gitea) → URL `http://172.20.50.1:9002/hooks/sync-skld00`, тот же secret, событие
«Push», content type `application/json`.

Проверено 2026-10-13: хук зарегистрирован, `Test delivery` из Forgejo проходит — `sync-state.sh`
отрабатывает и отвечает `Изменений в servers/skld00 нет — делать нечего.`

**Почему root, а не unprivileged-пользователь как на ВМ.** Там `app-runner` оправдан rootless
Podman'ом, который привилегий не требует. Здесь полезная нагрузка — Incus и ZFS: членство в группе
`incus-admin` и так эквивалентно root (из привилегированного контейнера с примонтированным хостовым
`/` выход в корень узла — одна команда), а `zfs create/snapshot/set`, монтирования и uid-shifting
томов данных требуют root напрямую. Отдельный пользователь добавил бы только sudoers-правила —
ту же власть, но размазанную по конфигам.

## Публикация и потребление

- **CI** (`Build/lxc-build`, workflow `build-leap16-base`): сборка → проверка «образ с этим
  `git_sha` уже на складе?» (есть → зелёное завершение без работы) → `incus-loc image import
  <incus.tar.xz> <rootfs.tar.xz> skld: --alias leap16-base` + properties (без `--reuse`:
  reuse-семантика удаляет прежний образ при совпадении алиасов — несовместимо с откатом).
  Подключение к складу — постоянный клиентский сертификат из секретов (см. «Доверие»).
- **Хосты-потребители:** без шага импорта — `incus-loc launch skld:<alias> <имя>` тянет и
  кеширует образ сам.
- Алиас стабильный (`leap16-base`), версия — в properties образа.

## Журнал

- 2026-10-11 — финальная настройка склада: `core.https_address=:8443` (API отвечает, проверено
  по сети: `GET https://172.20.50.1:8443/` → 200); ZFS-датасет `tank/incus` под состояние/образы
  демона (`INCUS_DIR=/var/lib/incus-loc`, пакет `incus-loc`). Доверие CI — клиентский сертификат
  `ci-lxc-build` (`config trust add-certificate`, секреты `SKLD00_CLIENT_CRT`/`SKLD00_CLIENT_KEY`
  в Forgejo); токен доверия CI отозван как непригодный для повторных прогонов (одноразовый).
  Хосты-потребители ещё не подключены.
- 2026-10-11 — первый зелёный прогон публикации `Build/lxc-build`: на складе `leap16-base`
  (текущий) + `leap16-base-prev` (откат), ровно две версии, старше удаляется самим пайплайном.
  Импорт без `--reuse` (reuse-семантика удаляет прежний образ при совпадении алиасов),
  ротацию ведёт CI. Повторный прогон с той же меткой уходит в зелёный скип.
