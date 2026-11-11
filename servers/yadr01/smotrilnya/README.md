# smotrilnya — ВМ мониторинга (yadr01)

> **Узел:** YADR01 (Proxmox). **ОС:** openSUSE MicroOS (Tumbleweed-генерация).
> **Адрес LAN:** `172.20.6.13/16` статиком, шлюз и DNS `172.20.0.1` *(MAC зарезервирован;
> если адрес другой — правятся две джобы в `app-configs/vmagent/scrape.yml` и два адреса
> в `app-configs/node/*`)*.
> **Плечо на P2P-линк:** `172.21.6.201/24`, без шлюза (бридж `vmbr1`).
>
> Роль: сбор и проверка (V²) → хранение на SKLD00 (V²) → показ (G). Хранилище
> (VictoriaMetrics/VictoriaLogs) здесь НЕ живёт: оно LXC-инстансами на SKLD00.
>
> **Модель — чистый исполнитель.** Всё состояние, которое может жить вне ВМ, живёт вне ВМ:
> метрики и логи — на SKLD00, конфиги — в git. Локально остаётся только вынужденное:
> каталоги в `/var/lib` (sqlite Grafana, тишины Alertmanager, буфер vmagent) и образы podman.

## Диски

| Диск | Размер | Что лежит | Почему так |
| :--- | :--- | :--- | :--- |
| `scsi0` (единственный) | **24 ГиБ** | ОС (A/B-снапшоты `transactional-update`), `/opt/appdata/config` (конфиги из git), `/var/lib/{grafana,alertmanager,vmagent}`, образы podman (~1.5 ГиБ), журнал, состояние Vector (`/var/lib/vector-loc`) | ниже 20 ГиБ selfinstall-образ MicroOS не разворачивается; второго диска у ВМ нет и он не нужен: `vmagent` ограничен `-remoteWrite.maxDiskUsagePerURL=512MB`, Vector пишет в память, sqlite и тишины занимают десятки мегабайт |

Состояние по сервисам:

| Сервис | Где состояние |
| :--- | :--- |
| метрики | VictoriaMetrics на SKLD00 `172.20.50.100:8428` |
| логи | VictoriaLogs на SKLD00 `172.20.50.101:9428` |
| Grafana (пользователи, настройки UI) | локальная sqlite, `/var/lib/grafana`; дашборды и источник — provisioning из git |
| Alertmanager (silences, журнал уведомлений) | локально, `/var/lib/alertmanager` — внешнего хранилища у него нет |
| vmagent | локально, `/var/lib/vmagent` — это очередь отправки, а не данные |

База `grafana` на PostgreSQL SKLD00 **не используется**: её там нет, а создание — изменение
на NAS, которого эта ВМ не делает. Дашборды и источники данных ведутся в git (provisioning),
в sqlite остаются только пользователи и настройки UI — расходное.

## Что тянет контур, а что делается руками

| Часть | Механизм | Что именно |
| :--- | :--- | :--- |
| Пять контейнеров (`quadlets/`) | **Pull по пушу**: webhook `:9000` → `sync-state.sh` → sparse-checkout этой папки → `rsync --delete` quadlets → `daemon-reload` → старт `*.network` → `podman auto-update` → точечный restart изменённых `.container` | grafana, vmagent, vmalert, blackbox, alertmanager |
| Конфиги приложений (`app-configs/{grafana,vmagent,vmalert,blackbox,alertmanager}`) | тот же push, `rsync` **без** `--delete` в `/opt/appdata/config/` | provisioning Grafana, scrape, правила, политика алертов |
| Конфиги уровня хоста (`app-configs/node/`) | **руками** | агент работает от `app-runner` и в `/etc` не пишет; раскладка и команды — `app-configs/node/README.md` |
| Агенты-пакеты (`node_exporter-loc`, `vector-loc`, `prometheus-podman-exporter-loc`, `webhook-loc`) | **руками**, `transactional-update pkg install …` + **полный** `reboot` | из своего rpm-md `zypper-tw-alexrus1234` |
| Секреты | руками, gitignored | `/opt/appdata/config/grafana/grafana.env`; секрет хука — в `~app-runner/.config/webhook-loc/hooks.yaml` |

Отдельно про правку конфигов: `sync-state.sh` перезапускает юниты **только** при изменениях в
`quadlets/`. Конфиг, смонтированный файлом (`scrape.yml`, `alertmanager.yml`, `blackbox.yml`),
после `rsync` в контейнере остаётся старым: новый файл — это новый inode, а контейнер держит
прежний. Поэтому правка конфига применяется в три шага: `git pull` → `rsync` (их делает
`sync-state.sh`) → `systemctl --user restart <юнит>` (руками).

## Порты (нумерация этой ВМ, от 10000)

| Порт | Юнит | Что |
| :--- | :--- | :--- |
| `10000` | `00-grafana` | Grafana UI (`:3000` внутри) |
| `10001` | `01-vmagent` | vmagent (`:8429`) — служебный UI/метрики |
| `10002` | `02-vmalert` | vmalert (`:8880`) |
| `10003` | `04-alertmanager` | Alertmanager (`:9093`) |
| `10004` | `03-blackbox` | blackbox_exporter (`:9115`) |

Службы хоста — вне диапазона 10000+, потому что это не контейнеры:
`node_exporter-loc` → `172.20.6.13:9100`, `prometheus-podman-exporter-loc` →
`172.20.6.13:9882`, `webhook-loc` (приём вебхуков Forgejo) →
`172.20.6.13:9000/hooks/<id>`.

## Образы

| Образ | Тег | Что за версия сейчас |
| :--- | :--- | :--- |
| `git.yadr00.internal/build/grafana` | `latest` | v13.3.0 |
| `git.yadr00.internal/build/victoria-tools` (vmagent + vmalert) | `latest` | v1.155.0 |
| `git.yadr00.internal/build/blackbox_exporter` | `latest` | v0.29.1 |
| `git.yadr00.internal/build/alertmanager` | `latest` | v0.34.2 |

Политика — как во всём контуре: `:latest` + `AutoUpdate=registry`, обновление
приходит пушем (`sync-state.sh` → `podman auto-update`) и ночным таймером
03:00–04:00. Пин по digest с этой политикой несовместим: если понадобится
заморозить версию, у юнита ставится `Image=…@sha256:…` **без** `AutoUpdate`, и
тогда обновление — только правкой строки в git.

## Что не скрейпится и почему

Экспортёры SKLD00 (`node_exporter-loc`, `smartctl_exporter-loc`, `zfs_exporter-loc`)
слушают только `172.26.50.1` — адрес бриджа `observ0`, который из LAN не
маршрутизируется. Их забирает `victoriametrics1` внутри узла. Вариант «а»:
источники не выставляются в сеть, в обмен на это снаружи их не видно.

## Порядок первого запуска

1. ВМ установлена, сеть готова (статик на LAN + плечо на `vmbr1`).
2. **В образе `16.0.0-SelfInstall` нет podman, git и rsync** — ставятся пакетами:
   `transactional-update pkg install podman git rsync`, затем **полный** `reboot`
   (`transactional-update reboot` может выбрать soft-reboot и не переключить снапшот:
   проверка — `rpm -q podman` и `snapper list`, активный снапшот помечен `*`).
3. Пользователь контейнеров: `useradd -m -s /bin/bash app-runner`, `loginctl enable-linger app-runner`,
   от `app-runner`: `systemctl --user enable --now podman.socket` (сокет обязателен user-юниту
   podman-exporter — в пакете стоит `Requires=podman.socket`).
4. Каталоги состояния — **до** первого старта контейнеров, иначе podman создаст их от root
   и uid 472/10001 внутрь не запишут:
   `install -d -o app-runner -g app-runner -m 0750 /var/lib/grafana /var/lib/alertmanager /var/lib/vmagent`.
5. Агенты: `transactional-update pkg install node_exporter-loc vector-loc prometheus-podman-exporter-loc webhook-loc`,
   полный `reboot`, затем конфиги хоста по `app-configs/node/README.md`, `systemctl enable --now node_exporter-loc vector-loc`
   и user-юниты от `app-runner`: `prometheus-podman-exporter-loc`, `webhook-loc`
   (ни один из них не включается скриптлетами пакета — только руками).
6. В `/opt/appdata/config/grafana/grafana.env` — пароль администратора Grafana (файл gitignored).
7. Хук: `~app-runner/.config/webhook-loc/opts` с `-ip 0.0.0.0 -port 9000 -urlprefix hooks`
   (дефолт юнита — `127.0.0.1:9001`, из LAN он недостижим), `~app-runner/.config/webhook-loc/hooks.yaml`
   с хуком `sync-smotrilnya` (HMAC по заголовку `X-Gitea-Signature`), вебхук в Forgejo на
   `http://172.20.6.13:9000/hooks/sync-smotrilnya`.
8. Первый прогон — **руками**: контур применяет только разницу коммитов, а в свежем чек-ауте разницы нет
   (`sync-state.sh` выходит на «Изменений не найдено» до `rsync`). От `app-runner`:
   `mkdir -p ~/.config/containers/systemd /opt/appdata/config` (rsync не создаёт промежуточные каталоги) →
   `rsync -rlptD --delete servers/yadr01/smotrilnya/quadlets/ ~/.config/containers/systemd/` →
   `rsync -rlptD servers/yadr01/smotrilnya/app-configs/ /opt/appdata/config/` →
   `systemctl --user daemon-reload` → `systemctl --user start apps-network.service` →
   `systemctl --user start 00-grafana 01-vmagent 02-vmalert 03-blackbox 04-alertmanager`.
   Quadlet-юниты **не включаются**: `systemctl enable` отвечает «transient or generated», автозапуск
   обеспечивает генератор через `default.target.wants` — проверка `ls /run/user/<uid>/systemd/generator/default.target.wants/`.
9. Дальше — авто: любой push в эту папку запускает `sync-state.sh` через вебхук. Приёмка: `systemctl --user status`
   по пяти юнитам, `curl` на `:10000/api/health`, таргеты `up` в vmagent (`:10001/targets`).
   Grafana не поднимется без `/opt/appdata/config/grafana/grafana.env` (`EnvironmentFile=` без минуса —
   файл обязателен), vmalert не поднимется, если `-rule` указывает на каталог, а не на маску `*.yml`.

## Что проверено, а что на месте

- Проверено по собранным артефактам: имена пакетов и юнитов, uid/gid образов
  (`victoria-tools`/`alertmanager`/`blackbox` — 10001, `grafana` — 472:0), пути
  конфигов в образах, дефолтные порты, теги и дайджесты всех четырёх образов в своём реестре.
- Проверено на самой ВМ (`rpm -q`): образ `16.0.0-SelfInstall` **не содержит** podman, git, rsync,
  crun, nano и qemu-guest-agent; `containers-common` тоже нет — дефолты лежат в `/usr/share/containers`,
  `registries.conf` в `/etc` отсутствует и не нужен при полных именах образов.
- **Проверить на месте:** эндпоинты здоровья `/health` у vmagent/vmalert (в образе
  `HEALTHCHECK` на них уже стоит), поведение `UserNS=keep-id` для uid 472 у Grafana,
  и что `prometheus-podman-exporter-loc` в user-режиме видит контейнеры `app-runner`.
