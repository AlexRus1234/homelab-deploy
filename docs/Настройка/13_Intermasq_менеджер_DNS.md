# 13 — Intermasq: Менеджер dnsmasq + YADR Auto-Provisioner

> Intermasq — модульный менеджер конфигурации `dnsmasq` (Go + Vue 3, единый бинарник ~10 МБ).
> YADR Auto-Provisioner — плагин для авто-развёртывания инфраструктуры в Proxmox VE.

## Intermasq — концепция безопасности (Rootless)

- Служба от непривилегированного пользователя `intermasq`.
- Запись разрешена только в `/etc/intermasq/` и `/etc/dnsmasq.d/`.
- Повышение прав — только через `sudoers`: `/usr/bin/systemctl restart dnsmasq` и `systemctl is-active dnsmasq`.

---

## Возможности

**Управление статикой:** чтение всех `dhcp-host` из `/etc/dnsmasq.d/*.conf`, умные вкладки по файлам, редактирование в один клик, массовое удаление чекбоксами.

**Импорт:** вставка сырого текста (Excel/консоль) → Smart Regex распознаёт MAC/IP/Hostname → предпросмотр → батч-запись.

**Мониторинг:** индикатор «Онлайн» через ARP-кэш ядра (каждые 30с), список активных аренд DHCP, быстрый перенос аренды в статику.

**Безопасность:** кнопка «Откат» (`.bak` перед каждым изменением), Pre-flight Check (`dnsmasq --test` — нельзя «положить» DNS опечаткой), Live Backup в ZIP, JWT-авторизация, защита от Path Traversal.

---

## REST API (требуют `Authorization: Bearer <token>`, кроме `/status` и `/login`)

| Метод | Назначение |
| :--- | :--- |
| `GET /api/status` | Статус инициализации |
| `POST /api/login` | Авторизация |
| `GET /api/hosts` | Статические записи |
| `GET /api/leases` | Динамические аренды |
| `GET /api/arp` | Живые MAC |
| `POST /api/hosts` | Добавить/обновить запись |
| `POST /api/hosts/bulk` | Массовое добавление |
| `DELETE /api/hosts/:mac?file=/path` | Удалить запись |
| `POST /api/rollback` | Откат файла из `.bak` |
| `POST /api/reload` | Валидация + рестарт dnsmasq |
| `GET /api/backup` | Скачать ZIP конфигов |

---

## YADR Auto-Provisioner (v3.0)

Плагин для авто-разворачивания: находит новые контейнеры/ВМ по MAC, вычисляет статические IP, настраивает DNS (dnsmasq) и Reverse Proxy (Caddy) с TLS от Step-CA.

**Связь:** Unix Domain Socket `/run/intermasq/sockets/prov.sock` (никаких открытых TCP).

**Алгоритм:**
1. Сверка аренд (`leases`) со списком хостов (`static`) → вывод неизвестных MAC.
2. Deep Scan: опрос API всех нод Proxmox, пока не найдётся MAC (в LXC/QEMU).
3. Парсинг тегов: `port-XXXX`, `proto-XXXX`, `name-XXXX`.
4. IP = `[Подсеть ноды].[VMID - 98]`.
5. DNS: короткое имя + IP → dnsmasq.
6. Caddy (API `:2019`): маршрут + TLS-политика (Step-CA).
7. **The Nuke:** команда `/stop` в Caddy → systemd перезапуск (очистка кэша, применение сертификата).

### Предварительные требования

**DNS (роутер)** — `/etc/dnsmasq.conf`, wildcard на каждую ноду:
```ini
address=/.yadr00.internal/172.20.5.3
address=/.yadr01.internal/172.20.6.2
```

**Caddy** на каждой ноде (`/etc/caddy/Caddyfile`):
```caddyfile
{
    admin :2019
    debug
    local_certs false
    acme_ca https://172.20.0.1:9000/acme/acme/directory
    acme_ca_root /etc/caddy/root_ca.crt
}
:80 {
    respond "ACME Listener" 200
}
```

`/etc/systemd/system/caddy.service.d/override.conf`:
```ini
[Service]
ExecStart=
ExecStart=/usr/bin/caddy run --environ --resume --config /etc/caddy/Caddyfile
Restart=always
RestartSec=1
```
```bash
systemctl daemon-reload && systemctl restart caddy
```

### `config.json` плагина (`/etc/intermasq/plugins/prov/`)
```json
{
    "intermasq_url": "http://172.20.0.1:8080/api",
    "intermasq_key": "СЕКРЕТНЫЙ_КЛЮЧ",
    "base_domain": ".internal",
    "nodes": {
        "yadr00": {
            "subnet": "172.20.5",
            "caddy_url": "http://172.20.5.3:2019",
            "pve_url": "https://172.20.5.1:8006/api2/json",
            "pve_token_id": "apiuser@pve!yadr00_token",
            "pve_secret": "uuid-секрет"
        },
        "yadr01": {
            "subnet": "172.20.6",
            "caddy_url": "http://172.20.6.2:2019",
            "pve_url": "https://172.20.6.1:8006/api2/json",
            "pve_token_id": "apiuser@pve!yadr01_token",
            "pve_secret": "uuid-секрет"
        }
    }
}
```
> Для каждой ноды — уникальный API-токен Proxmox с правами `PVEAuditor` на `/`.

### Тегирование в Proxmox

| Тег | Описание | Пример |
| :--- | :--- | :--- |
| `port-<порт>` | Порт сервиса (обязателен) | `port-8080` |
| `proto-<http/https>` | Протокол бэкенда | `proto-https` |
| `name-<имя>` | Переопределение домена | `name-database` |

> Исключение: если имя контейнера содержит `caddy` — выдаётся статический IP, но проксирование не настраивается.

### De-provisioning (умное удаление)
1. Остановить контейнер в Proxmox.
2. Скопировать MAC.
3. В интерфейсе плагина → «Очистка инфраструктуры» → вставить MAC → «Удалить всё».
4. Плагин удаляет HTTP/TLS маршруты в Caddy по ID и стирает запись в dnsmasq.
