# 11 — Authentik: SSO (единый вход)

> Развёртывание Authentik через Podman Quadlets. SSO для Forgejo, Proxmox, Matrix и др.
> БД PostgreSQL на NAS (`172.20.50.10`), Valkey на NAS (`172.20.50.12`).

## Шаг 1. БД на NAS
```bash
sudo -u postgres psql
CREATE USER authentik WITH PASSWORD 'SuperSecretPassword';
CREATE DATABASE authentik OWNER authentik;
\q
```

---

## Шаг 2. Пакеты и чистка docker-compose
```bash
sudo pacman -S podman podlet podman-compose openssl --noconfirm

mkdir ~/authentik-build && cd ~/authentik-build
wget https://goauthentik.io/docker-compose.yml
nano docker-compose.yml
```

Хирургическая чистка `docker-compose.yml`:
1. Удалить блоки `postgresql:` и `redis:` (внешние БД).
2. Удалить `depends_on:` в `server` и `worker`.
3. В `worker` удалить `- /var/run/docker.sock:...` (Podman без демона).
4. Удалить блоки `environment:` (пароли через `.env`).
5. `env_file:` → `- /etc/authentik/.env`.
6. Удалить блок `volumes:` внизу.

Итог:
```yaml
services:
  server:
    command: server
    env_file: [ /etc/authentik/.env ]
    image: ${AUTHENTIK_IMAGE:-ghcr.io/goauthentik/server}:${AUTHENTIK_TAG:-2026.2}
    ports:
    - ${COMPOSE_PORT_HTTP:-9000}:9000
    - ${COMPOSE_PORT_HTTPS:-9443}:9443
    restart: unless-stopped
    shm_size: 512mb
    volumes:
    - ./data:/data
    - ./custom-templates:/templates
  worker:
    command: worker
    env_file: [ /etc/authentik/.env ]
    image: ${AUTHENTIK_IMAGE:-ghcr.io/goauthentik/server}:${AUTHENTIK_TAG:-2026.2}
    restart: unless-stopped
    shm_size: 512mb
    user: root
    volumes:
    - ./data:/data
    - ./certs:/certs
    - ./custom-templates:/templates
```

---

## Шаг 3. Файл секретов `/etc/authentik/.env`
```bash
openssl rand -base64 36     # сгенерировать AUTHENTIK_SECRET_KEY

sudo mkdir -p /etc/authentik
sudo nano /etc/authentik/.env
```
```env
AUTHENTIK_POSTGRESQL__HOST=172.20.50.10
AUTHENTIK_POSTGRESQL__NAME=authentik
AUTHENTIK_POSTGRESQL__USER=authentik
AUTHENTIK_POSTGRESQL__PASSWORD=Твой_Пароль_От_БД

AUTHENTIK_REDIS__HOST=172.20.50.12
AUTHENTIK_REDIS__PASSWORD=Твой_Пароль_От_Valkey

AUTHENTIK_SECRET_KEY=сгенерированная_строка
```
```bash
sudo chmod 600 /etc/authentik/.env
```

---

## Шаг 4. Конвертация в Quadlets
Временный `.env` для подстановки переменных:
```bash
nano .env
```
```env
AUTHENTIK_IMAGE=ghcr.io/goauthentik/server
AUTHENTIK_TAG=2026.2
COMPOSE_PORT_HTTP=9000
COMPOSE_PORT_HTTPS=9443
```
```bash
podman-compose config > resolved.yml
```
В `resolved.yml` переименовать `server:` → `authentik-server:`, `worker:` → `authentik-worker:`. Затем:
```bash
podlet -f . compose ./resolved.yml
```

---

## Шаг 5. Правки `.container` и запуск

В `authentik-server.container` и `authentik-worker.container`:
1. В `[Container]` добавить `AutoUpdate=registry`.
2. Объём `Volume=./data:/data` → `Volume=/opt/authentik/data:/data` (абсолютные пути).
3. Добавить блок `[Install]` → `WantedBy=multi-user.target`.

Итог `authentik-server.container`:
```ini
[Container]
EnvironmentFile=/etc/authentik/.env
Exec=server
Image=ghcr.io/goauthentik/server:2026.2
PublishPort=9000:9000
PublishPort=9443:9443
ShmSize=512mb
Volume=/opt/authentik/data:/data
Volume=/opt/authentik/custom-templates:/templates
AutoUpdate=registry

[Service]
Restart=always

[Install]
WantedBy=multi-user.target
```

Запуск:
```bash
sudo mkdir -p /opt/authentik/{data,certs,custom-templates}
sudo mkdir -p /etc/containers/systemd/
sudo mv *.{container,network,volume} /etc/containers/systemd/ 2>/dev/null
sudo systemctl enable --now podman-auto-update.timer
sudo systemctl daemon-reload
sudo systemctl start authentik-server authentik-worker
journalctl -fu authentik-server   # ждать "Starting gunicorn"
```
Первичная настройка: `http://ВАШ_IP:9000/if/flow/initial-setup/`.

---

## Шаг 6. Caddy
```caddy
auth.alexrus1234.ru {
    reverse_proxy 172.20.5.4:9000
}
```
```bash
sudo systemctl reload caddy
```

---

## Интеграция с Proxmox (SSO)

`root@pam` нельзя привязать к OIDC — но учётке из Authentik выдаём права Администратора.

**В Authentik:** Applications → Providers → OAuth2/OpenID → `Proximox`. Redirect URI:
- `https://pve.вашдомен.ru/api2/extjs/access/oidc/callback`
- `https://proxmox.yadr00.internal`

**В Proxmox:** Datacenter → Permissions → Realms → Add → OpenID Connect:
- Realm: `authentik`
- Issuer URL: `https://auth.вашдомен.ru/application/o/proxmox/` (со слэшем!)
- Client ID / Client Key из Authentik
- Галочка **Autocreate Users**
- **Username Claim:** `preferred_username` (критично — иначе «user name is too long»)
- **Scopes:** `openid profile email`

**Права:** Datacenter → Permissions → Add → User Permission → Path `/`, User `<user>@authentik`, Role `Administrator`.

Вход: на экране Proxmox выбрать Realm `authentik` → Login (OpenID Connect) → редирект в Authentik → 2FA → возврат с правами админа.
