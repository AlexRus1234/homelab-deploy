# 14 — SFTPGo: Своё файловое облако

> Облако поверх обычных POSIX-файлов NAS (без opaque-хранилищ): Web UI, WebDAV/SFTP/FTP, REST API. SSO через Authentik (OIDC), БД — PostgreSQL на NAS.
> LXC `sftpgo` (CT 106) на YADR01: `172.20.6.8` (eth0) + `172.21.6.251` (eth1, прямой линк до NAS).
> Контекст: [YADR01 — Proxmox](../Узлы/YADR01_Proxmox.md), [03 — NAS: БД и S3](03_NAS_базы_данных_и_S3.md), [Архитектура и сеть](../Инфраструктура/01_архитектура_и_сеть.md)

## Архитектурное решение

Отказ от Nextcloud (лаги, OOM) и «opaque»-хранилищ (Seafile/MinIO-стиль: файлы — блобы, руками не залезть). SFTPGo — «обёртка» над обычными файлами на ZFS NAS: данные остаются прозрачными, qBittorrent/Immich работают с теми же путями напрямую.

| Компонент | Где | Адрес |
| :--- | :--- | :--- |
| SFTPGo (LXC) | YADR01 | `172.20.6.8` + `172.21.6.251` |
| Данные (bind mount) | NAS через хост yadr01 | `/srv/sftpgo/data` |
| PostgreSQL | NAS | `172.21.6.249:5432` (P2P-линк) |
| Caddy (реверс) | LXC yadr01 | `sftpgo.yadr01.internal` → `:8081`, `sftpgo.alexrus1234.ru` → `:8080` |
| Authentik (OIDC) | YADR00 | `authentic.yadr00.internal` |

Порты: **8080** — web (внешний контекст), **8081** — web (внутренний контекст), **2022** — SFTP.

---

## Этап 1. Подготовка сети

Прямой линк `172.21.6.0/24` уже должен быть настроен (см. [08 — Proxmox: бекап PBS, §1](08_Proxmox_бекап_PBS.md)). Специфика SFTPGo: контейнер получает **второй интерфейс на `vmbr1`** (без шлюза) — трафик данных/БД идёт в NAS напрямую.

---

## Этап 2. Подготовка файловой системы (bind mount на хосте yadr01)

```bash
mkdir -p /mnt/sftpgo_data
nano /etc/fstab
```
```text
/mnt/.nas_root_hidden /mnt/sftpgo_data none bind,_netdev,x-systemd.requires-mounts-for=/mnt/.nas_root_hidden,x-systemd.before=pve-guests.service 0 0
```
```bash
systemctl daemon-reload && mount -a
```

---

## Этап 3. Создание LXC

1. Proxmox → Create CT:
   * **Unprivileged**, шаблон `archlinux`, **ID 106**, hostname `sftpgo`
   * **Disk:** 8 GB | **CPU:** 2 vCPU | **RAM:** 1024 MB
   * **net0:** `vmbr0`, IP `172.20.6.8/16`, GW `172.20.0.1`
   * **net1:** `vmbr1`, IP `172.21.6.251/24`, **без шлюза**
   * **Не запускать.**
2. Проброс данных:
   ```bash
   nano /etc/pve/lxc/106.conf
   # mp0: /mnt/sftpgo_data,mp=/srv/sftpgo/data
   ```
3. Запустить, базовая настройка Arch:
   ```bash
   # /etc/pacman.conf → раскомментировать DisableSandbox
   pacman-key --init && pacman-key --populate archlinux
   pacman -Sy archlinux-keyring --noconfirm
   pacman -Syu base-devel git micro sudo --noconfirm
   ```
4. Корневой сертификат Step-CA в `/etc/ca-certificates/trust-source/anchors/step-ca.crt` → `update-ca-trust`.

---

## Этап 4. БД на NAS

```bash
sudo -u postgres psql
CREATE USER sftpgo WITH PASSWORD 'Ваш_Пароль_От_БД';
CREATE DATABASE sftpgo OWNER sftpgo;
\q
```

---

## Этап 5. Установка (AUR)

```bash
useradd -m -G wheel builduser
passwd -d builduser
echo "builduser ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
su - builduser
git clone https://aur.archlinux.org/sftpgo-bin.git
cd sftpgo-bin
makepkg -si --noconfirm
exit
```

> ⚠️ Команды после `su -` выполнять от `builduser` — не вставлять весь блок целиком от root (`makepkg` от root падает).

---

## Этап 6. Конфиг `/etc/sftpgo/sftpgo.json`

* В `data_provider`: `driver` → `"postgresql"`, `host` → `"172.21.6.249"`, логин/пароль из Этапа 4.
* В `httpd.bindings` — **два раздельных блока** с независимыми OIDC-редиректами:

**Блок 1 — внешний контекст (порт 8080):**
```json
{
  "port": 8080, "address": "0.0.0.0",
  "hide_login_url": 3, "disabled_login_methods": 12,
  "enable_web_admin": true, "enable_web_client": true,
  "oidc": {
    "client_id": "<CLIENT_ID>", "client_secret": "<CLIENT_SECRET>",
    "config_url": "https://authentic.yadr00.internal/application/o/sftp-go",
    "redirect_base_url": "https://sftpgo.alexrus1234.ru",
    "scopes": ["openid", "profile", "email"],
    "username_field": "preferred_username", "implicit_roles": true
  }
}
```

**Блок 2 — внутренний контекст (порт 8081):**
```json
{
  "port": 8081, "address": "0.0.0.0",
  "hide_login_url": 2, "disabled_login_methods": 8,
  "enable_web_admin": true, "enable_web_client": true,
  "oidc": {
    "client_id": "<CLIENT_ID>", "client_secret": "<CLIENT_SECRET>",
    "config_url": "https://authentic.yadr00.internal/application/o/sftp-go",
    "redirect_base_url": "https://sftpgo.yadr01.internal",
    "scopes": ["openid", "profile", "email"],
    "username_field": "preferred_username", "implicit_roles": true
  }
}
```
```bash
systemctl enable --now sftpgo
```

---

## Этап 7. Caddy

```caddy
# Внутренний домен (OIDC-редирект локальной сети)
sftpgo.yadr01.internal {
    import my_tls
    reverse_proxy 172.20.6.8:8081
}

# Внешний домен (публичный доступ, Caddy на VPS)
sftpgo.alexrus1234.ru {
    reverse_proxy 172.20.6.8:8080
}
```
SFTP-порт пробрасывается через layer4 Caddy yadr01 (`:65022` → `172.20.6.8:2022`, см. `system-templates/caddy/Caddyfile.yadr01.template`).

---

## Этап 8. Первичная настройка и клиенты

**Web (SSO):**
1. Открыть `https://sftpgo.yadr01.internal` → вход через Authentik.
2. Раздел **Users** → у OIDC-пользователя указать **Home Dir**: `/srv/sftpgo/data`.

**SFTP-клиенты (FolderSync, FileZilla и т.п.):**
SFTP не умеет OIDC — авторизация локальная. Два варианта:

*Вариант А (пароль):* в разделе **Users** задать локальный Password. Подключение: `sftp://172.20.6.8:2022` (или `sftpgo.yadr01.internal:65022`).

*Вариант Б (рекомендуется — SSH-ключ):* локальный пароль удалить, в поле SSH-ключа указать публичный слепок. Подключение теми же параметрами, аутентификация файлом секретного ключа. По прямому линку адрес клиента — `172.21.6.251:2022`.

> Администратор (WebAdmin) и пользователь — **раздельные сущности** SFTPGo; Initial Setup выполняется при первом запуске.
