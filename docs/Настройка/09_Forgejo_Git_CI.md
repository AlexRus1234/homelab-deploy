# 09 — Forgejo: Git + CI/CD + SSO

> Свой Git-сервер + Runner (Rootless Podman) + SSO через Authentik.
> LXC `172.20.1.20` на YADR00. БД PostgreSQL на NAS (`172.20.50.10`).

## Этап 1. Подготовка Proxmox (LXC)

Контейнер **Unprivileged**, шаблон `archlinux`, Root Disk 8 GB, 2 ядра / 1024 MB, статический IP `172.20.1.20/16`.
**Не запускать** — добавить Mount Point: Storage (емкий диск), Disk size 50 GB, Path `/var/lib/forgejo`, галочка Backup.

### Создание БД и пользователя (на NAS)
```bash
sudo -u postgres psql
CREATE USER forgejo WITH PASSWORD 'SuperSecret123';
CREATE DATABASE forgejo OWNER forgejo;
\q
```

---

## Этап 2. Базовая настройка Arch Linux в LXC

В непривилегированном LXC песочница pacman падает — отключаем:
```bash
nano /etc/pacman.conf
# В [options] раскомментировать: DisableSandbox

pacman-key --init
pacman-key --populate archlinux
pacman -Sy archlinux-keyring --noconfirm
pacman -Syu
pacman -S forgejo nano nftables openssh
chown forgejo:forgejo /var/lib/forgejo
```

---

## Этап 3. Конфликт SSH-портов

Системный SSH → `22224`, 22-й отдаём Forgejo (Git clone без указания порта).

```bash
nano /etc/ssh/ssd_config
# Port 22224
systemctl restart sshd
```

Forgejo слушает `2222`, firewall перекидывает 22 → 2222:
```bash
cat << 'EOF' > /etc/nftables.conf
flush ruleset
table ip nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        tcp dport 22 redirect to :2222
    }
}
EOF
systemctl enable --now nftables
```

Корневой сертификат Step-CA:
```bash
nano /etc/ca-certificates/trust-source/anchors/step-ca.crt   # вставить текст
update-ca-trust
```

---

## Этап 4. Первичная инициализация

```bash
systemctl enable --now forgejo
# Браузер: http://172.20.1.20:3000
```
В установщике:
- БД: PostgreSQL (IP, юзер, пароль)
- Путь репозиториев: `/var/lib/forgejo/repos`
- Путь логов: `/var/lib/forgejo/log`
- Создать администратора (`Admin`)

---

## Этап 5. Конфиг `app.ini`

`/etc/forgejo/app.ini` — поддержка S3 (MinIO), Valkey (Redis), динамическая подмена доменов для Caddy:

```ini
APP_NAME = Ваш Forgejo
RUN_USER = forgejo
RUN_MODE = prod
WORK_PATH = /var/lib/forgejo

[server]
PROTOCOL = http
DOMAIN = git.yadr00.internal
HTTP_PORT = 3000
ROOT_URL = https://git.yadr00.internal/
START_SSH_SERVER = true
SSH_LISTEN_PORT = 2222
SSH_DOMAIN = git.yadr00.internal
SSH_PORT = 22
APP_DATA_PATH = /var/lib/forgejo
DISABLE_SSH = false
OFFLINE_MODE = true
LFS_START_SERVER = true
USE_X_FORWARDED_HOST = true
PUBLIC_URL_DETECTION = auto

[database]
DB_TYPE = postgres
HOST = 172.20.50.10:5432
NAME = forgejo
USER = forgejo
PASSWD = Ваш_Пароль_От_БД
SSL_MODE = disable
LOG_SQL = false

[cache]
ADAPTER = redis
HOST = redis://:Ваш_Пароль_От_Valkey@172.20.50.12:6379/0

[session]
PROVIDER = redis
PROVIDER_CONFIG = redis://:Ваш_Пароль_От_Valkey@172.20.50.12:6379/1

[storage]
STORAGE_TYPE = minio
MINIO_ENDPOINT = 172.20.50.13:9000
MINIO_ACCESS_KEY_ID = Ваш_Access_Key
MINIO_SECRET_ACCESS_KEY = Ваш_Secret_Key
MINIO_BUCKET = forgejo-data
MINIO_USE_SSL = false

[service]
DISABLE_REGISTRATION = true
REQUIRE_SIGNIN_VIEW = false
DEFAULT_KEEP_EMAIL_PRIVATE = true
DEFAULT_ALLOW_CREATE_ORGANIZATION = true

[openid]
ENABLE_OPENID_SIGNIN = true
ENABLE_OPENID_SIGNUP = false

[repository]
ROOT = /var/lib/forgejo/repos

[log]
MODE = console
LEVEL = info
ROOT_PATH = /var/lib/forgejo/log

[security]
INSTALL_LOCK = true
PASSWORD_HASH_ALGO = pbkdf2_hi
REVERSE_PROXY_TRUSTED_PROXIES = 172.20.0.1/16
```

Безопасность (пароли в открытом виде):
```bash
chown forgejo:forgejo /etc/forgejo/app.ini
chmod 600 /etc/forgejo/app.ini
systemctl restart forgejo
```

---

## Этап 6. Caddy (два домена)

```caddy
# Внутренний (для себя, сертификат Step-CA)
git.yadr00.internal {
    reverse_proxy 172.20.1.20:3000 {
        header_up X-Forwarded-Host git.yadr00.internal
    }
    import my_tls
}

# Внешний (для всех, Let's Encrypt)
git.alexrus1234.ru {
    # Блок POST /user/login снаружи (защита от брутфорса)
    @block_login {
        method POST
        path /user/login
    }
    respond @block_login "Local login is disabled for external users. Use SSO." 403

    reverse_proxy 172.20.1.20:3000 {
        header_up X-Forwarded-Host git.alexrus1234.ru
    }
}
```

---

## Этап 7. SSO через Authentik

1. В Authentik: провайдер `Forgejo` (OAuth2/OIDC), Redirect URI:
   `https://git.yadr00.internal/user/oauth2/Authentik/callback`
   `https://git.alexrus1234.ru/user/oauth2/Authentik/callback`
2. Discovery URL: `https://authentic.yadr00.internal/application/o/forgejo/.well-known/openid-configuration`
3. В Forgejo: Администрирование → Источники аутентификации → OAuth2.
4. Выйти → «Войти через Authentik» → **«Привязать к существующему аккаунту»** → логин/пароль админа.

---

## Forgejo Runner (CI/CD, Rootless Podman)

Выделенная ВМ KVM (Arch Linux). Безопасность: всё в rootless-контейнерах.

```bash
pacman -Syu podman forgejo-runner --noconfirm

# Пользователь forgejo-runner → полноценная сессия + subuid/subgid
usermod -s /bin/bash -d /var/lib/forgejo-runner --add-subuids 100000-165535 --add-subgids 100000-165535 forgejo-runner
chage -E -1 forgejo-runner
loginctl enable-linger forgejo-runner

# DNS и доверие CA
nano /etc/systemd/network/10-ens18.network
# [Network]
# DHCP=yes
# DNS=172.20.0.1
# Domains=~internal

nano /etc/ca-certificates/trust-source/anchors/step-ca.crt   # вставить root_ca
update-ca-trust
```

Сессия через `machinectl` (не `su`):
```bash
machinectl shell forgejo-runner@
systemctl --user enable --now podman.socket
id -u   # запомнить UID (например 968)
```

`config.yaml`:
```yaml
runner:
  capacity: 2
  labels:
    - "docker"
container:
  docker_host: "unix:///run/user/968/podman/podman.sock"
  options: "--security-opt label=disable"
```

Регистрация:
```bash
forgejo-runner register --config config.yaml --no-interactive \
  --instance https://git.yadr00.internal/ --token <ТОКЕН> --name "YADR-RUNNER-01"
```

Служба `~/.config/systemd/user/forgejo-runner.service`:
```ini
[Unit]
Description=Forgejo Runner (Rootless Podman)
After=network.target podman.socket

[Service]
Type=simple
WorkingDirectory=%h
ExecStart=/usr/bin/forgejo-runner daemon --config %h/config.yaml
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
```
```bash
systemctl --user daemon-reload
systemctl --user enable --now forgejo-runner
```

### Пример пайплайна (`.forgejo/workflows/build.yaml`)
```yaml
name: CI/CD Pipeline
on: [push]
jobs:
  build:
    runs-on: docker
    container:
      image: docker.io/library/alpine:latest
    steps:
      - name: System Check
        run: cat /etc/os-release
```

---

## Подключение своего ПК к Forgejo
```bash
ssh-keygen -t ed25519 -C "ваша_почта@example.com"
cat ~/.ssh/id_ed25519.pub    # вставить в Forgejo → Settings → SSH/GPG keys

cd /путь/к/проекту
git init
git add .
git commit -m "Инициализация проекта"
git remote add origin git@git.ВАШ_ДОМЕН.ru:<user>/my-project.git
git branch -M main
git push -u origin main
```
