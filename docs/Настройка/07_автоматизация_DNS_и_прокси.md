# 07 — Автоматизация DNS и Reverse Proxy

> Автоматическое разворачивание сервисов с HTTPS и DNS-именами в локальной сети.
> Контекст: [SHLZ00 — Роутер](../Узлы/SHLZ00_роутер.md), PKI см. [06 — PKI Step-CA](06_PKI_Step-CA.md)

## Архитектура

- **CA:** роутер SHLZ (`172.20.0.1:9000`) — выпуск сертификатов зоны `.internal`.
- **Reverse Proxy:** Caddy в LXC на YADR00 (`172.20.5.3`). Конфиг `/etc/caddy/Caddyfile`, динамически импортирует `/etc/caddy/caddy_conf/*.caddy`.
- **DNS:** dnsmasq на роутере. Динамические хосты в `/etc/dnsmasq.d/yadr172x20x5p34.conf`, добавляются скриптом по SSH.
- **Скрипты:** лежат на хосте Proxmox в `/var/lib/vz/snippets/`.

---

## Этап 1. Подготовка роутера (безопасность DNS)

Цель: разрешить менять DNS без root.

Скрипт-обёртка `/usr/local/bin/update_dns_record.sh`:
```bash
chmod +x /usr/local/bin/update_dns_record.sh
echo "<user> ALL=(ALL) NOPASSWD: /usr/local/bin/update_dns_record.sh" | sudo tee /etc/sudoers.d/dns_update
sudo chmod 0440 /etc/sudoers.d/dns_update
```

---

## Этап 2. Подготовка Caddy

В `/etc/caddy/Caddyfile` добавить в конец:
```caddy
import /etc/caddy/caddy_conf/*.caddy
```
```bash
systemctl reload caddy
```

---

## Этап 3. Автоматизация на Proxmox

**Скрипт-хук** `/var/lib/vz/snippets/hook_auto_dns.sh` (запускается Proxmox при `post-start` контейнера):
1. Получает ID контейнера (например, `105`).
2. Вычисляет IP по формуле `172.20.5.(ID - 100 + 2)` (для ID 105 → `.7`).
3. Читает порт сервиса из поля Description (Notes). Если пусто → 80.
4. **SSH → Роутер:** обновляет DNS-запись (`hostname` → `IP`), перезагружает `dnsmasq`.
5. **SSH → Caddy:** создаёт `/etc/caddy/caddy_conf/HOSTNAME.caddy` (Reverse Proxy + TLS от ACME), делает `systemctl reload caddy`.

```bash
chmod +x /var/lib/vz/snippets/hook_auto_dns.sh
```

**Скрипт-наблюдатель** `/usr/local/bin/proxmox-hook-watcher.sh`:
- Раз в 10 сек сканирует `/etc/pve/lxc/*.conf`.
- Находит контейнеры **без** `hookscript` и автоматически прописывает хук: `pct set VMID -hookscript ...`.

```bash
chmod +x /usr/local/bin/proxmox-hook-watcher.sh
```

**Служба Systemd** `/etc/systemd/system/pve-hook-watcher.service`:
```bash
systemctl daemon-reload
systemctl enable --now pve-hook-watcher.service
```

---

## Как добавить новый сервис

1. Создать LXC-контейнер в Proxmox.
2. В **Hostname** указать имя (например, `plex`).
3. В **Notes** (Описание) указать порт (например, `32400`).
4. Запустить контейнер.
5. **Готово.** Через 5–10 сек сервис доступен по `https://plex.yadr00.internal`.

---

## Troubleshooting

**Нет HTTPS / ошибка SSL:**
- `ssh root@172.20.5.3 "journalctl -u caddy"`
- `curl -k https://172.20.0.1:9000/acme/acme/directory` (доступность CA)

**Не работает DNS:**
- `ssh <user>@172.20.0.1 "cat /etc/dnsmasq.d/yadr172x20x5p34.conf"`
- `tail -f /var/log/proxmox-hook.log`

**Скрипт не срабатывает:**
- `pct config ID | grep hook` (прописан ли хук)
- запущен ли Watcher.

---

## Бэкапы критичных компонентов
- Скрипты: `/var/lib/vz/snippets/` (в бэкап хоста Proxmox).
- Данные Caddy: `/var/lib/caddy` в контейнере 101.
- **Ключи PKI:** на роутере в `/root/.step`. **КРИТИЧНО ВАЖНО БЭКАПИТЬ ROOT KEY.**
