
```
homelab-deploy/
├── .forgejo/
│   └── workflows/
│       ├── yadr00-obshaga-deploy-webhook.yml
│       ├── yadr00-obshaga-webhook-deploy.yml
│       ├── yadr01-deploy-caddy.yml
│       └── yadr01-deploy-sftpgo.yml
│
├── system-templates/
│   ├── caddy/
│   │   └── Caddyfile.template
│   └── webhook/
│       ├── hooks.json.template
│       └── webhook.service.template
│
└── servers/
    └── yadr00/
        └── obshaga/
            ├── sync-state.sh
            ├── quadlets/
            │   ├── 01-athens.container
            │   ├── 02-dashy.container
            │   ├── 03-linkstack-data.volume
            │   ├── 03-linkstack.container
            │   ├── 04-memos.container
            │   └── 06-verdaccio.container
            │
            └── app-configs/
                ├── athens/
                │   └── athens.env.example
                ├── dashy/
                │   └── conf.yml
                ├── linkstack/
                │   ├── .keep
                │   └── linkstack.env
                ├── memos/
                │   └── .keep
                └── verdaccio/
                    └── config.yaml
```