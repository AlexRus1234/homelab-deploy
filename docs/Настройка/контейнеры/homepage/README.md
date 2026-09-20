# Homepage — дашборд сервисов (ВМ obshaga)

> **Контейнер:** `00-homepage.container` (ВМ `obshaga`, yadr00)
> **Образ:** `git.yadr00.internal/build/homepage:latest` (зеркало `ghcr.io/gethomepage/homepage`)
> **Порт:** `10000` (внешний) → `3000` (Next.js внутри)
> **Домен:** `homepage.obshaga.yadr00.internal` → `172.20.5.17:10000` (регистрация через Pomen по labels)
> Заменил Dashy (квадлет `02-dashy` удалён; конфиги `/opt/appdata/config/dashy/` и старую DNS/Caddy-запись `dashy.obshaga...` удалить вручную).

---

## 1. Как устроено

| Слой | Что | Где |
| :--- | :--- | :--- |
| Quadlet | `.container` с портом, HealthCmd, labels для Pomen | `servers/yadr00/obshaga/quadlets/00-homepage.container` |
| Конфиги | YAML homepage: settings/services/bookmarks/widgets/proxmox | `servers/yadr00/obshaga/app-configs/homepage/` |
| Секреты | `homepage.env` (в git — только `.example`), подстановка `{{HOMEPAGE_VAR_*}}` в YAML | на ВМ: `/opt/appdata/config/homepage/homepage.env` |
| Образ | еженедельное зеркало ghcr.io → реестр Forgejo | `.forgejo/workflows/homepage-image-sync.yaml` |

Доставка — стандартный GitOps-конвейер (см. [03_gitops_агент.md](../../Инфраструктура/03_gitops_агент.md)): push → webhook → `sync-state.sh` → rsync → `podman auto-update`.

Ключевые строки quadlet:
```ini
PublishPort=10000:3000
Environment=HOMEPAGE_ALLOWED_HOSTS=homepage.obshaga.yadr00.internal
EnvironmentFile=/opt/appdata/config/homepage/homepage.env
Volume=/opt/appdata/config/homepage:/app/config:Z
```
`HOMEPAGE_ALLOWED_HOSTS` **обязателен** за reverse-proxy — middleware проверяет Host-заголовок и без него отдаёт 400.

---

## 2. Деплой с нуля

### 2.1. Образ в реестре

Workflow `homepage-image-sync.yaml` зеркалит multiarch-образ раз в неделю (пн 04:30 UTC) и по кнопке *Run workflow*. Перед первым запуском задать в Forgejo → репозиторий → **Settings → Secrets**:

| Секрет | Что |
| :--- | :--- |
| `REGISTRY_USER` | пользователь Forgejo с правом записи в packages |
| `REGISTRY_TOKEN` | его access token (scope `write:packages`) |

Разово руками (альтернатива): `skopeo copy --all docker://ghcr.io/gethomepage/homepage:latest docker://git.yadr00.internal/build/homepage:latest`.

### 2.2. Права на каталог конфигов (ВАЖНО)

`/opt/appdata/config` — корень смонтированной ФС и должен принадлежать `app-runner` (этап 1.3 в [06_настройка_ВМ.md](../../Инфраструктура/06_настройка_ВМ.md)). Если он `root:root`, rsync **молча** не создаёт новые app-конфиги (код возврата скриптом не проверяется):

```bash
ls -ld /opt/appdata/config        # проверка
sudo chown app-runner:app-runner /opt/appdata/config   # фикс (не рекурсивно!)
```

### 2.3. Env с секретами на ВМ

```bash
cp /opt/appdata/config/homepage/homepage.env.example /opt/appdata/config/homepage/homepage.env
nano /opt/appdata/config/homepage/homepage.env
```

### 2.4. API-токены Proxmox (для CPU/RAM на карточках)

На **каждом** узле PVE (yadr00 и yadr01 — не кластеризованы), см. [gethomepage.dev/configs/proxmox](https://gethomepage.dev/configs/proxmox/):

1. Datacenter → Permissions → **Groups** → Create: `api-ro-users`
2. Add → **Group Permission**: Path `/`, Role `PVEAuditor`, Propagate ✓
3. **Users** → Add: `homepage`, Realm `Linux PAM`, Group `api-ro-users`
4. **API Tokens** → Add: User `homepage@pam`, Token ID `homepage`, Privilege Separation ✓
5. Add → **API Token Permission**: Path `/`, токен `homepage@pam!homepage`, Role `PVEAuditor`, Propagate ✓
6. Секрет (UUID) показывается **один раз** → сразу в `homepage.env`:
   ```ini
   HOMEPAGE_VAR_PROXMOX_SECRET_YADR00=<секрет с yadr00>
   HOMEPAGE_VAR_PROXMOX_SECRET_YADR01=<секрет с yadr01>
   ```

Имя `homepage@pam!homepage` уже прописано в `proxmox.yaml`. TLS PVE проверять не нужно — widget-запросы homepage идут с `rejectUnauthorized: false`.

### 2.5. Старт и проверка

```bash
systemctl --user restart 00-homepage && systemctl --user status 00-homepage
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://127.0.0.1:10000
```

---

## 3. TODO в конфигах (по мере желания)

- `services.yaml` — закомментированные `proxmoxVMID`: LXC Vaultwarden, ВМ panelka, LXC synapse; порт веб-UI AdGuard на SHLZ00
- `widgets.yaml` — координаты погоды (open-meteo, без API-ключа)

## 4. Troubleshooting

| Симптом | Причина | Лечение |
| :--- | :--- | :--- |
| 400 Bad Request по домену/IP | Host не в `HOMEPAGE_ALLOWED_HOSTS` | проверить `Environment=` в quadlet (порт 443 не пишется) |
| `Failed to load environment files` | нет `homepage.env` на ВМ | `cp` из `.example`, рестарт |
| `image not known` / нет контейнера | образа нет в реестре | запустить workflow зеркалирования, проверить secrets |
| Новая папка в `app-configs` не появляется на ВМ | `/opt/appdata/config` не `app-runner` | п. 2.2, затем rsync руками |
| Push прошёл, изменения не применились | репо на ВМ уже было свежим → `sync-state.sh` вышел по «Изменений не найдено» до rsync | применить шаги руками: `rsync -rlptD servers/yadr00/obshaga/app-configs/ /opt/appdata/config/` + `daemon-reload` |
| Карточки PVE без CPU/RAM | токен/секрет неверен | `journalctl --user -u 00-homepage -n 30 --no-pager`, пересоздать токен |
