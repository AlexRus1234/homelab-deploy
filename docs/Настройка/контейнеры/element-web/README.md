# Element Web — Matrix-клиент (ВМ obshaga)

> **Контейнер:** `01-element-web.container` (ВМ `obshaga`, yadr00)
> **Образ:** `git.yadr00.internal/build/element-web:latest` (сборка из репо element-web, пакет Forgejo `Build`)
> **Порт:** `10001` (внешний) → `8080` (nginx-unprivileged внутри)
> **Домен:** `element.obshaga.yadr00.internal` → `172.20.5.17:10001`. Pomen: домен = `ContainerName` (у нас `element`), label с именем — только fallback; DNS — wildcard `*.obshaga.yadr00.internal` → Caddy `172.20.5.3`

---

## 1. Как устроено

| Слой | Что | Где |
| :--- | :--- | :--- |
| Quadlet | `.container` с портом, HealthCmd, labels для Pomen | `servers/yadr00/obshaga/quadlets/01-element-web.container` |
| Конфиг | `config.json` (тема, бренд, дефолтный сервер) | `servers/yadr00/obshaga/app-configs/element-web/` |
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
- Homeserver: `default_server_config` ОБЯЗАТЕЛЕН для этой сборки — без него app.tsx (`verifyServerConfiguration`) бросает `invalid_configuration_no_server` до экрана входа. Дефолт — `https://matrix.yadr01.internal` (LXC synapse через Caddy yadr01, маршрут `/etc/caddy/caddy_conf/matrix.caddy` c well-known-делегацией; matrix.org не годится — заблокирован РКН, свежая сборка висит на нём чёрным экраном). Чужие серверы — через «изменить сервер» на экране входа (`disable_custom_urls: false`).

Доставка — стандартный GitOps-конвейер: push → webhook → `sync-state.sh` → rsync → `podman auto-update`.

## 2. Внешний доступ — `element.alexrus1234.ru` (Caddy на VPS)

Цель инстанса — публичный клиент: чужие люди открывают, вводят **свой** homeserver на экране входа (`disable_custom_urls: false`). Внутренний `element.obshaga.yadr00.internal` чужим бесполезен (DNS + Step-CA только в LAN).

Блок на VPS (схема mortis/homer из [12_VPN_Headscale_VPS.md](../../Инфраструктура/12_VPN_Headscale_VPS.md)):

```caddy
element.alexrus1234.ru {
    encode zstd gzip

    @static path /bundles/* /themes/* /vector-icons/* /i18n/* /fonts/*
    header @static Cache-Control "public, max-age=604800, immutable"

    reverse_proxy https://element.obshaga.yadr00.internal {
        transport http {
            tls_insecure_skip_verify
        }
        header_up Host {upstream_hostport}
    }
}
```

- `encode zstd gzip` — **критично**: образ отдаёт статику без сжатия (nginx образа без gzip), первый груз ~20 МБ в сотне файлов; без сжатия через туннель VPS↔дом ~минута, с ним ~10 с
- `@static` + immutable-кэш — имена файлов хэшированы, повторные заходы не качают статику
- `tls_insecure_skip_verify` — серт внутреннего Caddy от Step-CA, VPS ему не верит; `header_up Host {upstream_hostport}` — внутренний Caddy маршрутизирует по Host

## 3. Деплой с нуля

1. Образ уже публикуется в реестр (пакет `Build/element-web`, тег `latest`) — ничего зеркалировать не нужно.
2. Проверить права на `/opt/appdata/config` (`app-runner:app-runner`) — иначе rsync молча не создаст `element-web/config.json` (п. 2.2 README homepage).
3. Push в main — `sync-state.sh` подхватит quadlet и конфиг, Pomen зарегистрирует домен по labels.
4. Проверка:
   ```bash
   systemctl --user status 01-element-web
   curl -s -o /dev/null -w "HTTP %{http_code}\n" http://127.0.0.1:10001/config.json
   ```

## 4. Troubleshooting

| Симптом | Причина | Лечение |
| :--- | :--- | :--- |
| `/config.json` отдаёт 404 | не смонтировался конфиг | проверить `/opt/appdata/config/element-web/config.json` на ВМ |
| В контейнере `/app/config.json` — каталог | на момент первого старта файла не было (rsync не прошёл / права), podman создал директорию | `systemctl --user stop 01-element-web && rm -rf` «файла»-каталога внутри образа нельзя — перезапустить службу после появления настоящего файла |
| Не удаётся войти (CORS / недоступен сервер) | введённый на экране входа homeserver недоступен из браузера клиента | проверить URL homeserver и его доступность с машины, где открыт Element |
| Правка `config.json` в репо не применяется | `sync-state.sh` перезапускает только изменённые `.container`; bind-mount одиночного файла держит старый inode | на ВМ: `systemctl --user restart 01-element-web` (entrypoint копирует конфиг в nginx только при старте) |
| Домен открывается, но пусто / SPA-ошибка `cannot_load_config` | DNS wildcard ведёт в Caddy, а маршрута для этого имени нет (Pomen не зарегистрировал) | сверить маршрут: `curl http://172.20.5.3:2019/config/` — имя хоста должно совпадать с `ContainerName` |
| Чёрный экран (конфиг грузится, логина нет) | дефолтный homeserver из `default_server_config` недоступен из браузера и **медленно** отваливается (matrix.org за РКН — таймауты, свежая сборка висит) | дефолт = быстро отвечающий сервер (`matrix.yadr01.internal`); подтверждено практикой 20.09.2026 |
| Инкогнито работает, обычное окно — старая ошибка | кэш/service worker профиля, либо прокси-расширение (в инкогнито выключено) | F12 → Application → Service Workers → Unregister + Storage → Clear site data; не помогло — отключить прокси/adblock-расширения; диагностический приём — F12 → Network → «Disable cache» + F5 |
| Наружу грузится минуту | VPS-блок без `encode zstd gzip` (статика ~20 МБ без сжатия) | см. блок в п. 2 |
