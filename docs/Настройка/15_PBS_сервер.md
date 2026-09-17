# 15 — PBS: Сервер резервного копирования

> Установка Proxmox Backup Server в LXC на YADR01 (`172.20.6.3:8007`), datastore на SMB-шаре NAS, расписания GC/prune, бэкап самого PBS.
> Клиентская часть (бэкап хостов `/etc`, восстановление) — [08 — Proxmox: бекап PBS](08_Proxmox_бекап_PBS.md).
> Контекст: [YADR01 — Proxmox](../Узлы/YADR01_Proxmox.md), [SKLD00 — NAS](../Узлы/SKLD00_NAS.md)

## Архитектура

| Компонент | Где | Адрес |
| :--- | :--- | :--- |
| PBS (LXC CT 101) | YADR01 | `172.20.6.3:8007`, `pbs.yadr01.internal` |
| Datastore `shara` | SMB-шара NAS (bind mount) | `//172.21.6.249/Share` через хост yadr01 |
| Namespaces | — | `yadr00`, `yadr01` (бэкапы хостов) + snapshot-бэкапы гостей |

> ⚠️ PBS **не может бэкапить сам себя** (datastore переходит в read-only). Поэтому контейнер PBS дополнительно сохраняется vzdump'ом на SMB-шару — см. Этап 5.

---

## Этап 1. Создание LXC

Через Community-Scripts (Proxmox VE → Shell):
* Продвинутая установка: **unprivileged**, 10 GB / 2 vCPU / 2 GB, DHCP (статика выдаётся Intermasq ниже), storage `local-btrfs`.
* **Теги: `port-8007`, `pbs`, `https`** — по ним Intermasq/Povez автоматически выдают домен `pbs.yadr01.internal` и маршрут в Caddy.

```bash
pct enter 101
passwd   # задать root-пароль
```

---

## Этап 2. Статический IP через Intermasq

В панели Intermasq (SHLZ00) привязать MAC контейнера → `172.20.6.3` (шаблон выдачи как у остальных LXC, см. [13 — Intermasq](13_Intermasq_менеджер_DNS.md)).

---

## Этап 3. Datastore на SMB-шаре

1. На хосте yadr01 примонтировать шару (методика двойного монтирования — [08, §2](08_Proxmox_бекап_PBS.md)), например в `/mnt/backup`:
   ```text
   /mnt/.nas_root_hidden/YADR/becap /mnt/backup none bind,_netdev,... 0 0
   ```
2. Проброс внутрь контейнера:
   ```bash
   pct set 101 -mp0 /mnt/backup,mp=/mnt/backup
   ```
3. В Web UI PBS: **Administration → Storage/Disks** → Directory: `/mnt/backup`, name `shara`.
   > Создание datastore занимает время — в datastores `.chunks` создаётся ~65 000 папок.
4. **Namespaces:** в datastore `shara` создать `yadr00` и `yadr01`.

---

## Этап 4. Расписания обслуживания datastore

В свойствах datastore `shara` (Web UI PBS):

| Задача | Расписание | Примечание |
| :--- | :--- | :--- |
| **Garbage Collection** | ежедневно | Подчищает потерянные чанки |
| **Prune** | пятница | Ротация по keep-политике (например `keep-daily 7`, `keep-weekly 4`) |

---

## Этап 5. Бэкап самого PBS и джобы из PVE

**vzdump контейнера PBS** (на хосте yadr01 или через Web UI): режим Snapshot, target — SMB-шара (не datastore PBS!). Выполнять вручную после значимых изменений конфигурации PBS.

**Джобы бэкапа гостей** — на каждой ноде PVE:
* Datacenter → Backup: режим **Snapshot**, время ~23:00, хранилище — PBS (`172.20.6.3`, datastore `shara`).
* Селекция: все гости, **кроме CT 101 (сам PBS)**.

---

## Этап 6. Доступ к Web UI

```caddy
pbs.yadr01.internal {
    reverse_proxy https://172.20.6.3:8007 {
        transport http {
            tls_insecure_skip_verify
        }
    }
    import my_tls
}
```
(Уже входит в `system-templates/caddy/Caddyfile.yadr01.template`.)

---

## Подводные камни

- **Fingerprint:** при добавлении PBS-хранилища в PVE — обрезанный fingerprint даёт `unexpected EOF`, криво вставленный — 500/401.
- **storage.cfg** лучше добавлять через GUI PVE, а не копированием файла (pmxcfs «виртуализирует» папки).
- Права токенов бэкапа хостов — только `DatastoreBackup` на конкретные namespace-пути (см. [08, §3](08_Proxmox_бекап_PBS.md)); `DatastoreAdmin` — только если нужна автоматическая ротация.
- Полная процедура восстановления ноды из PBS (включая магию `pmxcfs` и два архива `/etc` + `/etc/pve`) — [08, §4](08_Proxmox_бекап_PBS.md).
