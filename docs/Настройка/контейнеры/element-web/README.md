# Element Web — Matrix-клиент (ВМ obshaga)

> **Контейнер:** `01-element-web.container` (ВМ `obshaga`, yadr00)
> **Образ:** `git.yadr00.internal/build/element-web:latest` (сборка из репо element-web, пакет Forgejo `Build`)
> **Порт:** `10001` (внешний) → `8080` (nginx-unprivileged внутри)
> **Домен:** `element.obshaga.yadr00.internal` → `172.20.5.17:10001` (регистрация через Pomen по labels)

---

## 1. Как устроено

| Слой | Что | Где |
| :--- | :--- | :--- |
| Quadlet | `.container` с портом, HealthCmd, labels для Pomen | `servers/yadr00/obshaga/quadlets/01-element-web.container` |
| Конфиг | `config.json` (тема, бренд; homeserver НЕ зашит) | `servers/yadr00/obshaga/app-configs/element-web/` |
| Образ | nginx-unprivileged + статика element-web из сборки репо | реестр Forgejo `Build/element-web` |

Это чистая статика: Element ходит в Synapse **из браузера**, а не с сервера — серверной части нет.

Ключевые строки quadlet:
```ini
Environment=ELEMENT_WEB_PORT=8080
PublishPort=10001:8080
Volume=/opt/appdata/config/element-web/config.json:/app/config.json:ro
```

- `ELEMENT_WEB_PORT=8080` — envsubst-шаблон nginx образа; 8080 вместо дефолтного 80, чтобы не городить `Sysctl=net.ipv4.ip_unprivileged_port_start=80` (как у linkstack).
- Входная точка образа (`18-load-element-modules.sh`) копирует `/app/config*.json` в `/tmp/element-web-config`, откуда nginx раздаёт их по пути `/config`. Смонтированный `config.json` просто перекрывает baked-сэмпл.
- Homeserver в `config.json` намеренно не зашит (`default_server_config` отсутствует, `disable_custom_urls: false`): адрес сервера вводится вручную на экране входа — клик по ссылке сервера под полями логина.

Доставка — стандартный GitOps-конвейер: push → webhook → `sync-state.sh` → rsync → `podman auto-update`.

## 2. Деплой с нуля

1. Образ уже публикуется в реестр (пакет `Build/element-web`, тег `latest`) — ничего зеркалировать не нужно.
2. Проверить права на `/opt/appdata/config` (`app-runner:app-runner`) — иначе rsync молча не создаст `element-web/config.json` (п. 2.2 README homepage).
3. Push в main — `sync-state.sh` подхватит quadlet и конфиг, Pomen зарегистрирует домен по labels.
4. Проверка:
   ```bash
   systemctl --user status 01-element-web
   curl -s -o /dev/null -w "HTTP %{http_code}\n" http://127.0.0.1:10001/config.json
   ```

## 3. Troubleshooting

| Симптом | Причина | Лечение |
| :--- | :--- | :--- |
| `/config.json` отдаёт 404 | не смонтировался конфиг | проверить `/opt/appdata/config/element-web/config.json` на ВМ |
| В контейнере `/app/config.json` — каталог | на момент первого старта файла не было (rsync не прошёл / права), podman создал директорию | `systemctl --user stop 01-element-web && rm -rf` «файла»-каталога внутри образа нельзя — перезапустить службу после появления настоящего файла |
| Не удаётся войти (CORS / недоступен сервер) | введённый на экране входа homeserver недоступен из браузера клиента | проверить URL homeserver и его доступность с машины, где открыт Element |
