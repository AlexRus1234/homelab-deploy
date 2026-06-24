
```
homelab-deploy/
├── .forgejo/
│   └── workflows/
│       ├── yadr01-deploy-sftpgo.yml       
│       ├── yadr01-deploy-caddy.yml
│       └── yadr00-obshaga-deploy-webhook.yml
│
├── system-templates/                      # Универсальные шаблоны
│   ├── caddy/
│   │   └── Caddyfile.template
│   └── webhook/
│       ├── hooks.json.template
│       └── webhook.service.template
│
└── servers/                               # Корень машин
    └── yadr00/                            #
        └── obshaga/                       # 
            ├── sync-state.sh              # Скрипт синхронизации
            ├── quadlets/                  # 
            │   ├── 01-athens.container
            │   ├── 02-dashy.container
            │   ├── 03-verdaccio.container
            │   ├── 04-memos.container
            │   ├── 03-linkstack-data.volume
            │   └── 03-linkstack.container
            │
            └── app-configs/               # Настройки программ
                ├── athens/
                │   └── athens.env.example
                ├── dashy/
                │   └── conf.yml
                ├── verdaccio/
                │   └── config.yaml
                ├── memos/
                │   └── .keep              # 
                └── linkstack/
                    └── linkstack.env
```