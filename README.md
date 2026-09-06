# homelab-deploy

Монорепозиторий конфигураций домашнего дата-центра (HomeLab). Управление сервисами осуществляется по модели **GitOps**: все изменения фиксируются в репозитории, а целевые ВМ автоматически подтягивают их через Pull-механизм (Forgejo Webhook + Sparse-Checkout + Rootless Podman Quadlets).

## Ключевые документы

| Документ | Содержание |
| :--- | :--- |
| [`01_архитектура_и_сеть.md`](docs/Инфраструктура/01_архитектура_и_сеть.md) | Топология узлов, сетевая адресация, порты сервисов |
| [`02_спецификация_вм.md`](docs/Инфраструктура/02_спецификация_вм.md) | Стандарт ВМ (диски, пользователи, PKI) |
| [`03_gitops_агент.md`](docs/Инфраструктура/03_gitops_агент.md) | Pull-модель, Webhook, sync-state.sh |
| [`04_доменная_схема.md`](docs/Инфраструктура/04_доменная_схема.md) | Доменные зоны, TLS, Caddy |
| [`05_доменные_имена.md`](docs/Инфраструктура/05_доменные_имена.md) | Сводная таблица всех доменов с IP:port |

## Паспорта узлов

| Документ | Узел |
| :--- | :--- |
| [`SHLZ00_роутер.md`](docs/Узлы/SHLZ00_роутер.md) | Маршрутизатор: железо, интерфейсы, DNS-«сэндвич», PKI, IDS/IPS, QoS |
| [`SKLD00_NAS.md`](docs/Узлы/SKLD00_NAS.md) | NAS: железо, дисковая разметка (Btrfs+ZFS), macvlan БД, Samba |

## Настройка (пошаговые гайды)

| № | Документ | Тема |
| :--- | :--- | :--- |
| 01 | [`01_NAS_система_ZFS_и_Btrfs.md`](docs/Настройка/01_NAS_система_ZFS_и_Btrfs.md) | Разметка NVMe, Btrfs RAID1/RAID0, ZFS RAIDZ2, Snapper |
| 02 | [`02_NAS_сетевые_службы_Samba.md`](docs/Настройка/02_NAS_сетевые_службы_Samba.md) | Samba `\\SKLD00\Share`, wsdd/avahi |
| 03 | [`03_NAS_базы_данных_и_S3.md`](docs/Настройка/03_NAS_базы_данных_и_S3.md) | PostgreSQL/MongoDB/Valkey/MinIO через macvlan |
| 04 | [`04_роутер_базовая_сеть.md`](docs/Настройка/04_роутер_базовая_сеть.md) | systemd-networkd, dnsmasq, nftables, NAT |
| 05 | [`05_роутер_NGFW_DNS_QoS_IPS.md`](docs/Настройка/05_роутер_NGFW_DNS_QoS_IPS.md) | AdGuard+dnsmasq+Unbound, CAKE-шейпер, Zeek/Suricata/CrowdSec |
| 06 | [`06_PKI_Step-CA.md`](docs/Настройка/06_PKI_Step-CA.md) | Свой центр сертификации, ACME для зоны `.internal` |
| 07 | [`07_автоматизация_DNS_и_прокси.md`](docs/Настройка/07_автоматизация_DNS_и_прокси.md) | Хуки Proxmox → DNS + Caddy по SSH |
| 08 | [`08_Proxmox_бекап_PBS.md`](docs/Настройка/08_Proxmox_бекап_PBS.md) | Линк до NAS, монтирование SMB в LXC, бэкап хостов |
| 09 | [`09_Forgejo_Git_CI.md`](docs/Настройка/09_Forgejo_Git_CI.md) | Git + Runner (rootless Podman) + SSO |
| 10 | [`10_Matrix_мессенджер.md`](docs/Настройка/10_Matrix_мессенджер.md) | Synapse + VPS/Coturn |
| 11 | [`11_Authentik_SSO.md`](docs/Настройка/11_Authentik_SSO.md) | SSO через Podman Quadlets, интеграция с Proxmox |
| 12 | [`12_VPN_Headscale_VPS.md`](docs/Настройка/12_VPN_Headscale_VPS.md) | Доступ из интернета, свой DERP, Split DNS |
| 13 | [`13_Intermasq_менеджер_DNS.md`](docs/Настройка/13_Intermasq_менеджер_DNS.md) | Менеджер dnsmasq + авто-провижининг Proxmox |

## Дерево репозитория

```
homelab-deploy/
├── .forgejo/
│   └── workflows/
│       ├── yadr00-obshaga-webhook-deploy.yml
│       ├── yadr00-deploy-intermasq.yml
│       ├── yadr01-deploy-caddy.yml
│       ├── yadr01-deploy-sftpgo.yml
│       └── yadr01-panelka-webhook-deploy.yml
│
├── .gitignore
│
├── docs/
│   ├── Инфраструктура/
│   │   ├── 01_архитектура_и_сеть.md
│   │   ├── 02_спецификация_вм.md
│   │   ├── 03_gitops_агент.md
│   │   ├── 04_доменная_схема.md
│   │   ├── 05_доменные_имена.md
│   │   └── настройка/
│   │       └── 02_настройка_ВМ.md
│   │
│   ├── Узлы/
│   │   ├── SHLZ00_роутер.md
│   │   └── SKLD00_NAS.md
│   │
│   ├── Настройка/
│       ├── 01_NAS_система_ZFS_и_Btrfs.md
│       ├── 02_NAS_сетевые_службы_Samba.md
│       ├── 03_NAS_базы_данных_и_S3.md
│       ├── 04_роутер_базовая_сеть.md
│       ├── 05_роутер_NGFW_DNS_QoS_IPS.md
│       ├── 06_PKI_Step-CA.md
│       ├── 07_автоматизация_DNS_и_прокси.md
│       ├── 08_Proxmox_бекап_PBS.md
│       ├── 09_Forgejo_Git_CI.md
│       ├── 10_Matrix_мессенджер.md
│       ├── 11_Authentik_SSO.md
│       ├── 12_VPN_Headscale_VPS.md
│       └── 13_Intermasq_менеджер_DNS.md
│
│   └── заметки/
│       └── podman/
│           └── 01-автообновление.md
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
    │       │   ├── 02-dashy.container
    │       │   ├── 03-linkstack.container
    │       │   └── 04-memos.container
    │       └── app-configs/
    │           ├── dashy/
    │           │   └── conf.yml
    │           └── memos/
    │               └── .keep
    │
    └── yadr01/
        └── panelka/
            ├── sync-state.sh
            ├── quadlets/
            │   └── 01-nora.container
            └── app-configs/
                └── nora/
                    └── nora.env.example
```
