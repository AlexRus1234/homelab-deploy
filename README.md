```
homelab-deploy/
├── .forgejo/
│   └── workflows/
│       ├── yadr00-obshaga-webhook-deploy.yml
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
│       └── настройка/
│           └── 02_настройка_ВМ.md
│
├── report/
│   └── README.md
│
├── system-templates/
│   ├── caddy/
│   │   └── Caddyfile.template
│   └── webhook/
│       ├── hooks.json.template
│       └── webhook.service.template
│
└── servers/
    ├── yadr00/
    │   └── obshaga/
    │       ├── sync-state.sh
    │       ├── quadlets/
    │       │   ├── 01-athens.container
    │       │   ├── 02-dashy.container
    │       │   ├── 03-linkstack.container
    │       │   └── 04-memos.container
    │       └── app-configs/
    │           ├── athens/
    │           │   └── athens.env.example
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
