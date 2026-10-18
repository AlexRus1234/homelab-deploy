# homelab-deploy

Монорепозиторий конфигураций домашнего дата-центра (HomeLab). Управление сервисами осуществляется по модели **GitOps**: все изменения фиксируются в репозитории, а целевые ВМ автоматически подтягивают их через Pull-механизм (Forgejo Webhook + Sparse-Checkout + Rootless Podman Quadlets).

## Ключевые документы

| Документ | Содержание |
| :--- | :--- |
| [`00_карта_железа_и_сервисов.md`](docs/Инфраструктура/00_карта_железа_и_сервисов.md) | Сводная карта всего: железо, адресация, гости гипервизоров, софт, домены, цепочки |
| [`01_архитектура_и_сеть.md`](docs/Инфраструктура/01_архитектура_и_сеть.md) | Топология узлов, сетевая адресация, порты сервисов |
| [`02_спецификация_вм.md`](docs/Инфраструктура/02_спецификация_вм.md) | Стандарт ВМ (диски, пользователи, PKI) |
| [`03_gitops_агент.md`](docs/Инфраструктура/03_gitops_агент.md) | Pull-модель, Webhook, sync-state.sh |
| [`04_доменная_схема.md`](docs/Инфраструктура/04_доменная_схема.md) | Доменные зоны, TLS, Caddy |
| [`05_доменные_имена.md`](docs/Инфраструктура/05_доменные_имена.md) | Сводная таблица всех доменов с IP:port |
| [`06_настройка_ВМ.md`](docs/Инфраструктура/06_настройка_ВМ.md) | Подготовка ВМ: Rootless Podman + GitOps-агент |

## Паспорта узлов

| Документ | Узел |
| :--- | :--- |
| [`SHLZ00_роутер.md`](docs/Узлы/SHLZ00_роутер.md) | Маршрутизатор: железо, интерфейсы, DNS-«сэндвич», PKI, IDS/IPS, QoS |
| [`YADR00_Proxmox.md`](docs/Узлы/YADR00_Proxmox.md) | Гипервизор #1 (N100, 32 ГБ): Forgejo, Authentik, obshaga |
| [`YADR01_Proxmox.md`](docs/Узлы/YADR01_Proxmox.md) | Гипервизор #2 (Ryzen 7 5800HS, 64 ГБ, две сети): PBS, SFTPGo, panelka |
| [`SKLD00_NAS.md`](docs/Узлы/SKLD00_NAS.md) | NAS: железо, дисковая разметка (Btrfs+ZFS), macvlan БД, Samba |

## Настройка (пошаговые гайды)

| № | Документ | Тема |
| :--- | :--- | :--- |
| 01 | [`01_NAS_система_ZFS_и_Btrfs.md`](docs/Настройка/01_NAS_система_ZFS_и_Btrfs.md) | Разметка NVMe, Btrfs RAID1/RAID0, ZFS RAIDZ2, Snapper |
| 02 | [`02_NAS_сетевые_службы_Samba.md`](docs/Настройка/02_NAS_сетевые_службы_Samba.md) | Samba `\\SKLD00\Share`, wsdd/avahi |
| 03 | [`03_NAS_базы_данных_и_S3.md`](docs/Настройка/03_NAS_базы_данных_и_S3.md) | PostgreSQL/MongoDB/Valkey (macvlan) + RustFS S3 на P2P-линке |
| 04 | [`04_роутер_базовая_сеть.md`](docs/Настройка/04_роутер_базовая_сеть.md) | systemd-networkd, dnsmasq, nftables, NAT |
| 05 | [`05_роутер_NGFW_DNS_QoS_IPS.md`](docs/Настройка/05_роутер_NGFW_DNS_QoS_IPS.md) | AdGuard+dnsmasq+Unbound, CAKE-шейпер, Zeek/Suricata/CrowdSec |
| 06 | [`06_PKI_Step-CA.md`](docs/Настройка/06_PKI_Step-CA.md) | Свой центр сертификации, ACME для зоны `.internal` |
| 07 | [`07_автоматизация_DNS_и_прокси.md`](docs/Настройка/07_автоматизация_DNS_и_прокси.md) | Хуки Proxmox → DNS + Caddy по SSH |
| 08 | [`08_Proxmox_бекап_PBS.md`](docs/Настройка/08_Proxmox_бекап_PBS.md) | Линк до NAS, монтирование SMB в LXC, бэкап хостов |
| 09 | [`09_Forgejo_Git_CI.md`](docs/Настройка/09_Forgejo_Git_CI.md) | Git + Runner (rootless Podman) + SSO |
| 10 | [`10_Matrix_мессенджер.md`](docs/Настройка/10_Matrix_мессенджер.md) | Synapse + VPS/Coturn |
| 11 | [`11_Authentik_SSO.md`](docs/Настройка/11_Authentik_SSO.md) | SSO через Podman Quadlets, интеграция с Proxmox |
| 12 | [`12_VPN_Headscale_VPS.md`](docs/Настройка/12_VPN_Headscale_VPS.md) | Доступ из интернета, свой DERP, Split DNS |
| 13 | [`13_Intermasq_менеджер_DNS.md`](docs/Настройка/13_Intermasq_менеджер_DNS.md) | Менеджер dnsmasq на SHLZ00 (исходники — репо `Intermasq`) |
| 14 | [`14_SFTPGo_облако.md`](docs/Настройка/14_SFTPGo_облако.md) | Файловое облако поверх NAS: LXC, SSO (OIDC), SFTP |
| 15 | [`15_PBS_сервер.md`](docs/Настройка/15_PBS_сервер.md) | PBS в LXC: datastore на SMB, GC/prune, бэкап самого PBS |

## Проверки контура перед пушем

Логика контура узла `skld00` (разбор деклараций, карта uid, чувствительность хешей, порядок команд
обновления, откат, снятие, уборка) проверяется тремя харнессами на заглушках — узла, root и сети они не
требуют:

```sh
bash servers/skld00/tests/networks-test.sh    # сети: создание, приведение ключей, предпосылки инстансов
bash servers/skld00/tests/teardown-test.sh    # ручные режимы --down/--up: снять и поднять всё объявленное
bash servers/skld00/tests/update-test.sh       # ночной контур: обновление, откат, уборка
bash servers/skld00/tests/reconcile-test.sh    # применение деклараций: create/recreate, хеши, uid
bash servers/skld00/tests/remove-test.sh       # снятие по декларации, удалённой из git
```

Каждый печатает `ok`/`FAIL` по секциям и возвращает ненулевой код при первом расхождении. Чтобы это
происходило **автоматически перед каждым пушем** (в том числе на свежем клоне на другой машине),
включите хук — одна строка на клон:

```sh
git config core.hooksPath .githooks
```

Настройка репозиторная (пишется в `.git/config`), другие репозитории машины не затрагивает; почему нельзя
`--global` и что именно проверяется — в [`servers/skld00/tests/README.md`](servers/skld00/tests/README.md).
Красный харнесс пуш не пускает; осознанный обход — `git push --no-verify`.

## Дерево репозитория

```
homelab-deploy/
├── .forgejo/
│   └── workflows/
│       ├── homepage-image-sync.yaml
│       ├── mirror.yaml
│       ├── yadr00-obshaga-webhook-deploy.yml
│       ├── yadr00-deploy-intermasq.yml
│       ├── yadr01-deploy-caddy.yml
│       ├── yadr01-deploy-sftpgo.yml
│       └── yadr01-panelka-webhook-deploy.yml
│
├── .githooks/
│   └── pre-push                 # проверки контура перед пушем (включается: git config core.hooksPath .githooks)
│
├── .gitattributes
├── .gitignore
│
├── docs/
│   ├── Инфраструктура/
│   │   ├── 00_карта_железа_и_сервисов.md
│   │   ├── 01_архитектура_и_сеть.md
│   │   ├── 02_спецификация_вм.md
│   │   ├── 03_gitops_агент.md
│   │   ├── 04_доменная_схема.md
│   │   ├── 05_доменные_имена.md
│   │   ├── 06_настройка_ВМ.md
│   │   └── старое/
│   │       └── 01_архитектура_и_сеть.md
│   │
│   ├── Узлы/
│   │   ├── SHLZ00_роутер.md
│   │   ├── YADR00_Proxmox.md
│   │   ├── YADR01_Proxmox.md
│   │   └── SKLD00_NAS.md
│   │
│   ├── Настройка/
│   │   ├── 01_NAS_система_ZFS_и_Btrfs.md
│   │   ├── 02_NAS_сетевые_службы_Samba.md
│   │   ├── 03_NAS_базы_данных_и_S3.md
│   │   ├── 04_роутер_базовая_сеть.md
│   │   ├── 05_роутер_NGFW_DNS_QoS_IPS.md
│   │   ├── 06_PKI_Step-CA.md
│   │   ├── 07_автоматизация_DNS_и_прокси.md
│   │   ├── 08_Proxmox_бекап_PBS.md
│   │   ├── 09_Forgejo_Git_CI.md
│   │   ├── 10_Matrix_мессенджер.md
│   │   ├── 11_Authentik_SSO.md
│   │   ├── 12_VPN_Headscale_VPS.md
│   │   ├── 13_Intermasq_менеджер_DNS.md
│   │   ├── 14_SFTPGo_облако.md
│   │   ├── 15_PBS_сервер.md
│   │   │
│   │   └── контейнеры/
│   │       ├── element-web/
│   │       │   └── README.md
│   │       └── homepage/
│   │           └── README.md
│   │
│   └── заметки/
│       └── podman/
│           ├── 01-автообновление.md
│           └── 02-версии-ldflags.md
│
├── report/
│   └── README.md
│
├── system-templates/
│   ├── caddy/
│   │   ├── Caddyfile.yadr00.template
│   │   └── Caddyfile.yadr01.template
│   └── webhook/
│       ├── hooks.json.template
│       └── webhook.service.template
│
└── servers/
    ├── yadr00/
    │   └── obshaga/
    │       ├── sync-state.sh
    │       ├── quadlets/
    │       │   ├── 00-homepage.container
    │       │   ├── 01-element-web.container
    │       │   ├── 04-memos.container
    │       │   ├── 05-mortis.container
    │       │   └── apps.network
    │       └── app-configs/
    │           ├── element-web/
    │           │   └── config.json
    │           ├── homepage/
    │           │   ├── settings.yaml
    │           │   ├── services.yaml
    │           │   ├── bookmarks.yaml
    │           │   ├── widgets.yaml
    │           │   ├── docker.yaml
    │           │   ├── proxmox.yaml
    │           │   └── homepage.env.example
    │           └── memos/
    │               └── .keep
    │
    ├── yadr01/
    │   └── panelka/
    │       ├── sync-state.sh
    │       ├── quadlets/
    │       │   ├── 01-nora.container
    │       │   └── 02-khrazhevnik.container
    │       └── app-configs/
    │           ├── nora/
    │           │   └── nora.env.example
    │           └── khrazhevnik/
    │               └── khrazhevnik.env.example
    │
    └── skld00/                    # bare-metal узел: Incus-склад образов + инстансы
        ├── README.md              # роль узла: склад и GitOps-агент
        ├── sync-state.sh          # pull по webhook → reconcile
        ├── lib.sh                 # общие части контура: разбор деклараций, карта uid, метки, отчёт
        ├── reconcile.sh           # приведение инстансов к services/*.yaml
        ├── update.sh              # ночной контур: zypper dup в инстансах + уборка
        ├── systemd/
        │   ├── lxc-update.service # юнит ночного прогона
        │   └── lxc-update.timer   # окно 02:00–03:00 (случайный сдвиг внутри часа)
        ├── tests/                 # харнессы на заглушках: узла не требуют (см. tests/README.md)
        │   ├── harness-lib.sh
        │   ├── networks-test.sh
        │   ├── teardown-test.sh
        │   ├── update-test.sh
        │   ├── reconcile-test.sh
        │   └── remove-test.sh
        ├── networks/
        │   └── observ0.yaml       # приватная сеть узла 172.26.50.0/24 под служебный трафик
        └── services/
            ├── README.md          # формат деклараций инстансов
            ├── vl1.yaml           # VictoriaLogs  (:9428)
            └── vm1.yaml           # VictoriaMetrics (:8428)
```
