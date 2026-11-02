# 17 — Jellyfin: медиасервер во временном LXC

> **Статус: временное решение, вне GitOps.** Контейнер `jellyfin` (CT 125) на YADR00 собран руками на `archlinux-base`, обновлений не получает, декларации в репозитории нет. Живёт до переезда — что нужно для постоянного варианта, в §9. Медиатека на момент установки лежала на LTO-лентах: контейнер настроен, но библиотека ещё не восстановлена.
>
> Контекст: [SKLD00 — NAS](../Узлы/SKLD00_NAS.md), [YADR00 — гипервизор](../Узлы/YADR00_Proxmox.md), [08 — монтирование SMB в LXC](08_Proxmox_бекап_PBS.md).

## 1. Что развёрнуто

| Параметр | Значение |
| :--- | :--- |
| Узел | YADR00 (`172.20.5.1`), N100 (4 потока), iGPU Gen12 QSV |
| Контейнер | LXC CT 125 `jellyfin`, шаблон `archlinux-base`, непривилегированный |
| Ресурсы | 2 CPU, 4096 МБ RAM, 16 ГБ диск |
| Адрес | `172.20.5.27` (LAN, `vmbr0`) |
| Домен | `jellyfin.yadr00.internal` → Caddy → `172.20.5.27:8096` |
| Пакеты | `jellyfin-server 12.4`, `jellyfin-web 12.4`, `jellyfin-ffmpeg 8.1.3p1`, `vpl-gpu-rt`, `intel-media-driver`, `noto-fonts`, `libva-utils` |
| База данных | своя, SQLite — внешней СУБД сервис не требует |
| Медиатека | `/media` в контейнере ← `media` на шаре NAS (только чтение) |
| Транскод-скрэтч | tmpfs 1024 МБ на `/var/lib/jellyfin/transcodes` |

Диск: ОС и пакеты ≈ 4 ГБ, метаданные и постеры для библиотеки 1.3 ТБ ≈ 1–4 ГБ. Trickplay (превью-скраббинг) не включать — он в гигабайтах.

## 2. Аппаратное ускорение: проброс iGPU в контейнер

На хосте YADR00: `render` = gid **993**, `video` = gid **44**. В контейнере те же номера заняты иначе (`render` 987, `video` 983, `disk` 993), поэтому группы заводятся с явным маппингом.

`/etc/pve/lxc/125.conf` — дописать:

```
lxc.cgroup2.devices.allow: c 226:0 rwm
lxc.cgroup2.devices.allow: c 226:128 rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.idmap: u 0 100000 65536
lxc.idmap: g 0 100000 950
lxc.idmap: g 950 993 1
lxc.idmap: g 951 44 1
lxc.idmap: g 952 100952 64584
```

- контейнерный gid **950 → хост 993** (`render`), **951 → хост 44** (`video`);
- строку `u 0 100000 65536` писать обязательно: как только в конфиге появляется любой `lxc.idmap`, дефолтный маппинг Proxmox перестаёт действовать;
- `lxc.idmap` применяется только при старте — контейнер перезапускается.

На хосте `/etc/subgid` — **без этих строк маппинг не поднимется**:

```
root:100000:65536
root:993:1
root:44:1
```

Симптом без них: `newgidmap: gid range [950-951) -> [993-994) not allowed`, `Failed to set up id mapping`, `TASK ERROR: startup for container '125' failed`.

Внутри контейнера — группы и членство:

```
groupadd -g 950 dri
groupadd -g 951 dri-video
usermod -aG dri,dri-video jellyfin
```

Проверка: `runuser -u jellyfin -- vainfo` показывает `Intel iHD driver`, а в профилях — `HEVCMain10` и `AV1Profile0`.

**Альтернатива без idmap** (если правка `/etc/subgid` нежелательна): убрать строки `lxc.idmap`, оставить `cgroup2.devices.allow` и `mount.entry`, а устройство перевесить на группу, которая уже мапится по умолчанию (хост 100967 = контейнерный 967):

```
groupadd -g 100967 lxc-jellyfin
printf 'SUBSYSTEM=="drm", KERNEL=="renderD128", GROUP="lxc-jellyfin", MODE="0660"\n' > /etc/udev/rules.d/99-render-lxc.rules
udevadm control --reload && udevadm trigger --subsystem-match=drm
```

Цена: `renderD128` на хосте перестаёт принадлежать `render` — хостовый сервис, которому понадобится QSV, потеряет доступ.

## 3. Доверие к CA сети и pacman через Хражевник

Пакеты берутся с зеркала склада, не с апстрима. Сначала корень Step-CA — в Arch путь другой, чем в Red Hat-рецептах:

```
install -d -m 755 /etc/ca-certificates/trust-source/anchors
curl -sk https://172.20.0.1:9000/roots.pem -o /etc/ca-certificates/trust-source/anchors/step-ca.crt
update-ca-trust
```

Проверка: `curl -s https://khrazhevnik.panelka.yadr01.internal/…` отвечает без `-k`.

`/etc/pacman.conf`:

```
[options]
SigLevel    = Required DatabaseOptional
DisableDownloadTimeout

[core]
Server = https://khrazhevnik.panelka.yadr01.internal/pacman/arch/$repo/os/$arch

[extra]
Server = https://khrazhevnik.panelka.yadr01.internal/pacman/arch/$repo/os/$arch

[pacman-alexrus1234]
SigLevel = PackageNever DatabaseRequired
Server = https://khrazhevnik.panelka.yadr01.internal/repo/pacman-alexrus1234
```

- `DatabaseOptional` в `[options]` обязателен: зеркало не отдаёт `*.db.sig`, а глобальный `DatabaseRequired` ломает любой `pacman -Sy`;
- **`DisableDownloadTimeout` — не украшение.** Склад работает как pull-through: первый запрос некэшированного пакета идёт через апстрим, и pacman успевает упасть с `Operation too slow. Less than 1 bytes/sec transferred the last 10 seconds` (так сорвалась первая транзакция на `jellyfin-web`, 32 МБ). Повторный запрос того же файла отдаётся из кэша за 0,2 с;
- ключ личного репо: `pacman-key --init`, `pacman-key --populate archlinux`, `pacman-key --add key.asc`, `pacman-key --lsign-key CC3411B6EFC625A595161038C7142B956F015EF1`.

## 4. Установка и запуск

```
pacman -Syu                                  # один полный апгрейд, до установки пакетов
pacman -S --needed jellyfin-server jellyfin-web jellyfin-ffmpeg vpl-gpu-rt intel-media-driver noto-fonts libva-utils
systemctl enable --now jellyfin.service
```

Почему именно так:

- **`jellyfin-ffmpeg` обязателен** — системный ffmpeg не содержит VPP-фильтров и QSV-обвязки Jellyfin;
- **`vpl-gpu-rt` + `intel-media-driver` обязательны оба**: первый — QSV-рантайм (пакет `onevpl-intel-gpu` из репозиториев исчез), второй — драйвер VA-API (iHD);
- `jellyfin-ffmpeg` держит точные soname-зависимости (`libx264.so`, `libva.so`, `libdrm`), поэтому **частичный апгрейд в этом контейнере запрещён** — только `pacman -Syu` целиком.

tmpfs под транскод — `/etc/systemd/system/var-lib-jellyfin-transcodes.mount` (владелец — uid/gid `jellyfin`, 967):

```
[Unit]
Description=tmpfs для каталога транскода Jellyfin (временное решение, до переезда)
DefaultDependencies=no
Before=jellyfin.service

[Mount]
What=tmpfs
Where=/var/lib/jellyfin/transcodes
Type=tmpfs
Options=size=1024M,mode=0750,uid=967,gid=967,nosuid,nodev

[Install]
WantedBy=multi-user.target
```

## 5. Медиатека

Шара монтируется на хосте YADR00 по [гайду 08](08_Proxmox_бекап_PBS.md) (`/mnt/.nas_root_hidden`, `uid=100000,forceuid`), в контейнер отдаётся подкаталог, **только чтение**:

```
pct set 125 -mp0 /mnt/.nas_root_hidden/media,mp=/media,ro=1
```

Медиатека — `media/` в корне шары (`/tank/data/media` на NAS): `anime/`, `film/`, `mult/`, `serial/`, `video/`, `torentfile/`. На момент установки содержимое было на LTO-лентах; после восстановления библиотека появляется в `/media` сама, менять ничего не нужно — только пересканировать в Jellyfin.

Проверка доступа не от root: `runuser -u jellyfin -- test -r /media`.

## 6. Маршрут в Caddy

Маршрута в git нет — он добавлен в живой конфиг через Admin API (`@id: pod-jellyfin-yadr00`, upstream `172.20.5.27:8096`). Снять:

```
curl -X DELETE http://172.20.5.3:2019/id/pod-jellyfin-yadr00
```

Обычная асимметрия этого контура: удаление контейнера маршрут не убирает, и наоборот.

## 7. Приёмка (замеры 29.10.2026, синтетические клипы — медиатека была на лентах)

| Проверка | Результат |
| :--- | :--- |
| `vainfo` от `jellyfin` | Intel iHD driver 26.3.5, VA-API 1.24; профили `HEVCMain10`, `AV1Profile0` |
| HEVC 10-бит 1080p → H.264 (QSV + VPP) | 5.88x реального времени, CPU-user 0.36 с |
| Два потока параллельно (HEVC10 1080p) | 3.9x и 3.86x каждый |
| AV1 720p → H.264 (QSV) | 10.5x, CPU-user 0.19 с |
| AV1 720p → HEVC (QSV) | 4.55x |
| Софт-эталон HEVC10 1080p → H.264 | 2.57x, CPU-user **4.1 с** (два ядра заняты целиком) |

**Грабли, которые стоит помнить при ручных прогонах:** 10-битный вход нельзя отдать в `h264_qsv` напрямую — `Current pixel format is unsupported`, энкодер не открывается. Нужна конверсия в VPP: `-vf vpp_qsv=format=nv12`. Jellyfin вставляет её сам, `ffmpeg` из консоли — нет.

Возможности N100 (Gen12 Xe-LP): HEVC 8/10-бит декод и энкод — есть; **AV1 декод — есть, AV1 энкод — нет** (появляется с Gen 12.5/12.7). Для библиотеки на HEVC/AV1 это ровно то, что нужно: AV1 декодируется аппаратно, кодируется в H.264/HEVC.

## 8. Настройки мастера первого запуска

- Hardware acceleration: **Intel Quick Sync (QSV)**; аппаратное декодирование HEVC, AV1, VP9; аппаратное кодирование H.264/HEVC.
- **Tone mapping — выключить**, пока не смотрим HDR-клиентами: в библиотеке есть один файл `Forrest Gump 2160p HDR Dolby Vision`, и тонирование отнимает VPP-движок у второго потока.
- **Trickplay не включать** (16 ГБ диска).
- Transcode path оставить пустым — по умолчанию это `/var/lib/jellyfin/transcodes`, где уже tmpfs.

## 9. Что нужно, чтобы решение стало постоянным

1. **Пакет в свой репо.** Сейчас `jellyfin-server/web/ffmpeg` ставятся из `extra` — конвенция «собираю сам» требует своих пакетов в `pacman-alexrus1234` (PKGBUILD из Arch, репозиторий `0_ЦОД/pacman-pkg-build`).
2. **Контур обновлений.** У Арч-LXC на YADR00 нет ни таймера, ни git-деплоя (в отличие от инстансов `skld00` с `lxc-update.timer`) — сейчас контейнер остаётся без обновлений сознательно.
3. **Декларация.** Либо перенос сервиса в контур `skld00` (инстанс Incus с `services/jellyfin.yaml`, `gpu`+`disk` устройства), либо свой шаблон LXC и pull-механизм для YADR00 — сейчас такого контура для LXC нет.
4. **Тяжёлая артиллерия.** Свободный `yadr03` (Ryzen 7 7840HS, 64 ГБ, прямой линк к NAS, Radeon 780M = VCN 4.0 с AV1-**энкодом**) снимает все ограничения N100; для одного Jellyfin расчехлять не требовалось.

## 10. Удаление (что остаётся на диске)

```
pct stop 125
pct destroy 125
```

Остаётся и снимается отдельно:

- строки `root:993:1` и `root:44:1` в `/etc/subgid` на YADR00;
- маршрут в Caddy (§6);
- монтирование шары на хосте (`/mnt/.nas_root_hidden` — общее, не трогать) и `mp0` — уходит вместе с конфигом контейнера;
- SSH-доступ root'а контейнера по ключу агента Hermes (временный, при выводе удалить строку из `/root/.ssh/authorized_keys`).
