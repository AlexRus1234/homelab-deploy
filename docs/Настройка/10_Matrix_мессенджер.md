# 10 — Matrix: Суверенный мессенджер (Synapse)

> Ядро Matrix Synapse + веб-админка. Вывод в интернет через VPS + Coturn.
> Домен: `matrix.alexrus1234.ru`. Все тяжёлые данные на NAS ([SKLD00 — NAS](../Узлы/SKLD00_NAS.md)).

## Архитектура

| Компонент | Где | IP |
| :--- | :--- | :--- |
| Synapse (ядро) | LXC `elementsynapse` | `172.20.6.5` |
| PostgreSQL | NAS | `172.20.50.10:5432` |
| Valkey (Redis) | NAS | `172.20.50.12:6379` |
| RustFS (S3 media) | NAS (P2P-линк) | `172.21.6.249:9000` |
| Caddy + Coturn | VPS | белый IP |

---

## Шаг 0. Proxmox (критично!)
В LXC: **Options → Features** → поставить галочки **FUSE** и `Nesting`. Перезагрузить контейнер.

---

## Шаг 1. БД на NAS (требовательна к кодировкам)
```bash
sudo -u postgres psql
CREATE USER synapse WITH PASSWORD 'ТвойСуперПароль';
CREATE DATABASE synapse OWNER synapse ENCODING 'UTF8' LC_COLLATE = 'C' LC_CTYPE = 'C' TEMPLATE template0;
\q
```

---

## Шаг 2. S3 через Rclone (в LXC Synapse)

Бакет `matrix-media` + API-ключ создаются в RustFS (`172.21.6.249:9000`, P2P-линк).
```bash
apt update && apt upgrade -y
apt install -y curl rclone fuse3
echo "user_allow_other" >> /etc/fuse.conf
```

`/root/.config/rclone/rclone.conf`:
```ini
[rustfs]
type = s3
provider = Minio
env_auth = false
access_key_id = ТВОЙ_ACCESS_KEY
secret_access_key = ТВОЙ_SECRET_KEY
endpoint = http://172.21.6.249:9000
force_path_style = true
region = us-east-1
```

Служба монтирования `/etc/systemd/system/rclone-matrix.service`:
```ini
[Unit]
Description=Rclone mount for Matrix Media
After=network-online.target

[Service]
Type=notify
ExecStartPre=/bin/mkdir -p /opt/synapse/data/media_store
ExecStartPre=/bin/mkdir -p /var/cache/rclone
ExecStart=/usr/bin/rclone mount rustfs:matrix-media /opt/synapse/data/media_store \
  --config=/root/.config/rclone/rclone.conf \
  --allow-other --dir-perms 0770 --file-perms 0660 \
  --vfs-cache-mode full --vfs-cache-max-size 5G --vfs-cache-max-age 24h \
  --vfs-read-chunk-size 16M --buffer-size 32M --umask 007
ExecStop=/usr/bin/fusermount3 -uz /opt/synapse/data/media_store
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```
```bash
systemctl daemon-reload
systemctl enable --now rclone-matrix
```

---

## Шаг 3. Установка Synapse (venv)
```bash
apt install -y build-essential python3 python3-dev python3-venv python3-pip \
               libffi-dev libssl-dev libjpeg-dev libxslt1-dev libpq-dev \
               zlib1g-dev libwebp-dev sudo nano

adduser --system --group --no-create-home synapse
chown -R synapse:synapse /opt/synapse

python3 -m venv /opt/synapse/env
source /opt/synapse/env/bin/activate
pip install --upgrade pip setuptools wheel
pip install matrix-synapse[all] psycopg2

cd /opt/synapse/data
python -m synapse.app.homeserver \
    --server-name ВАШ_ДОМЕН.ru \
    --config-path /opt/synapse/data/homeserver.yaml \
    --generate-config --report-stats=no

chown -R synapse:synapse /opt/synapse/data
```

---

## Шаг 4. Тюнинг `homeserver.yaml`

```yaml
listeners:
  - port: 8008
    tls: false
    type: http
    x_forwarded: true
    bind_addresses: ['0.0.0.0']
    cors_allowed_origins:
      - "*"

database:
  name: psycopg2
  args:
    user: "synapse"
    password: "ТвойСуперПароль"
    database: "synapse"
    host: "172.20.50.10"
    port: 5432
    cp_min: 5
    cp_max: 10

redis:
  enabled: true
  host: "172.20.50.12"
  port: 6379
  password: "ТвойСуперПароль"

media_store_path: "/opt/synapse/data/media_store"
enable_registration: false

# Пуши
push:
  enabled: true
  trusted_proxies:
    - "https://matrix.org"
    - "https://vector.im"
    - "https://element.io"
  include_content: true
```

---

## Шаг 5. Запуск и админ
Служба `/etc/systemd/system/matrix-synapse.service` (After/Requires `rclone-matrix.service`):
```bash
systemctl daemon-reload
systemctl enable --now matrix-synapse

/opt/synapse/env/bin/register_new_matrix_user -c /opt/synapse/data/homeserver.yaml http://localhost:8008
# Make admin: yes
```

---

## Шаг 6. Веб-админка (Synapse-Admin)

Статика `/opt/synapse-admin`, раздаёт встроенный Python:
```bash
mkdir -p /opt/synapse-admin && cd /opt/synapse-admin
URL=$(curl -s https://api.github.com/repos/Awesome-Technologies/synapse-admin/releases/latest | grep browser_download_url | grep "\.tar\.gz" | cut -d '"' -f 4)
wget $URL -O admin.tar.gz
tar -xzf admin.tar.gz
mv synapse-admin-*/* . 2>/dev/null
rm -rf synapse-admin-*/ admin.tar.gz
chown -R synapse:synapse /opt/synapse-admin
```

`/etc/systemd/system/synapse-admin.service`:
```ini
[Unit]
Description=Synapse Admin Web UI
After=network.target

[Service]
Type=simple
User=synapse
Group=synapse
WorkingDirectory=/opt/synapse-admin
ExecStart=/usr/bin/python3 -m http.server 5173
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```
```bash
systemctl daemon-reload
systemctl enable --now synapse-admin
```
Доступ: `http://172.20.6.5:5173`. Homeserver URL: `http://172.20.6.5:8008`.

---

## Шаг 6.5. Внутренний https-маршрут `matrix.yadr01.internal` (Caddy LXC yadr01)

Клиентский API по TLS внутри LAN: без него браузерным клиентам (Element, FluffyChat) на https-страницах доступен только `http://172.20.6.5:8008`, а это mixed content (браузер блокирует http-API со страницы по https). Файл `/etc/caddy/caddy_conf/matrix.caddy` на LXC caddy (`172.20.6.2`), затем `systemctl reload caddy`:

```caddy
matrix.yadr01.internal {
    import my_tls

    # 1. Отдаем паспорт для КЛИЕНТОВ (Element, FluffyChat)
    handle_path /.well-known/matrix/client {
        header Access-Control-Allow-Origin "*"
        header Content-Type "application/json"
        respond `{"m.homeserver":{"base_url":"https://matrix.yadr01.internal"}}`
    }

    # 2. Отдаем паспорт для СЕРВЕРОВ (Федерация: связь с matrix.org и другими)
    handle_path /.well-known/matrix/server {
        header Content-Type "application/json"
        respond `{"m.server":"matrix.yadr01.internal:443"}`
    }

    # 3. Проксируем основной трафик в домашний LXC-контейнер через VPN
    reverse_proxy 172.20.6.5:8008 {
        header_up X-Forwarded-For {remote_host}
    }
}
```

Проверка: `curl -k https://matrix.yadr01.internal/_matrix/client/versions` → JSON со списком версий. Используется как дефолтный homeserver в Element (ВМ obshaga, [контейнеры/element-web](контейнеры/element-web/README.md)).

---

## Шаг 7. Вывод в интернет (VPS + Coturn)

### Caddy на VPS (`/etc/caddy/Caddyfile`)
```caddy
xir.alexrus1234.ru {
    handle_path /.well-known/matrix/client {
        header Access-Control-Allow-Origin "*"
        header Content-Type "application/json"
        respond `{"m.homeserver":{"base_url":"https://xir.alexrus1234.ru"}}`
    }
    handle_path /.well-known/matrix/server {
        header Content-Type "application/json"
        respond `{"m.server":"xir.alexrus1234.ru:443"}`
    }
    reverse_proxy 172.20.6.5:8008 {
        header_up X-Forwarded-For {remote_host}
    }
}
```

### Coturn на VPS (`/etc/turnserver.conf`)
```ini
listening-port=3479
tls-listening-port=5349
external-ip=<ВНЕШНИЙ_IP_VPS>          # внешний белый IP VPS
min-port=50000
max-port=52000
use-auth-secret
static-auth-secret=ТвойСуперСекретныйПарольДляЗвонков
realm=xir.alexrus1234.ru
no-tcp-relay
no-cli
```

nftables на VPS:
```nft
udp dport { 3479, 5349, 50000-52000 } accept
tcp dport { 3479, 5349 } accept
```
```bash
sudo sed -i 's/#TURNSERVER_ENABLED=1/TURNSERVER_ENABLED=1/' /etc/default/coturn
sudo systemctl restart coturn
```

### В `homeserver.yaml` (Synapse)
```yaml
turn_uris:
  - "turn:ВАШ_ДОМЕН.ru:3479?transport=udp"
  - "turn:ВАШ_ДОМЕН.ru:3479?transport=tcp"
  - "turns:ВАШ_ДОМЕН.ru:5349?transport=udp"
  - "turns:ВАШ_ДОМЕН.ru:5349?transport=tcp"
turn_shared_secret: "ТвойСуперСекретныйПарольДляЗвонков"
turn_user_lifetime: 86400000
turn_allow_guests: true
```
`systemctl restart matrix-synapse`.

---

## Шпаргалка обслуживания

| Действие | Команда |
| :--- | :--- |
| Обновить Synapse | `source /opt/synapse/env/bin/activate` → `pip install --upgrade matrix-synapse psycopg2` → `systemctl restart matrix-synapse` |
| Сброс кэша админки (CORS) | F12 → Application → Local Storage → удалить ключи → F5 |
