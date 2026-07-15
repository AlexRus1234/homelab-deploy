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
│   └── Инфраструктура/
│       ├── 01_архитектура_и_сеть.md
│       ├── 02_спецификация_вм.md
│       ├── 03_gitops_агент.md
│       ├── 04_доменная_схема.md
│       ├── 05_доменные_имена.md
│       └── настройка/
│           └── 02_настройка_ВМ.md
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
