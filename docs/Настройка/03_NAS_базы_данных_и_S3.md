# 03 — NAS: Базы данных и S3

> Узел: **SKLD00**. Слой баз данных bare-metal (macvlan) + S3 (RustFS) на P2P-линке.
> Контекст: [SKLD00 — NAS](../Узлы/SKLD00_NAS.md)

## Архитектурные решения

1. **БД вынесены из Docker/Proxmox на голое железо NAS** — устранение оверхеда виртуализации, прямой доступ к ZFS, единый Data-слой.
2. **Сетевая изоляция через `macvlan`** — каждый сервис БД имеет свой виртуальный интерфейс в LAN, без NAT/проброса портов.
3. **Тюнинг ZFS** — `special_small_blocks=0` для `tank/db` (спасает потребительские SSD от износа); `recordsize`: PostgreSQL `16k`, MongoDB `64k`.
4. `logbias=latency` (дефолт) — оставлен ZIL, медленнее сейчас, но спасает диски от фрагментации через годы.

| Сервис | IP | Порт |
| :--- | :--- | :--- |
| PostgreSQL | `172.20.50.10` | 5432 |
| MongoDB | `172.20.50.11` | 27017 |
| Valkey (Redis) | `172.20.50.12` | 6379 |
| RustFS (S3) | `172.21.6.249` (P2P-линк) | 9000 |

> ⚠️ Все БД слушают **только** свой macvlan-IP и адреса на P2P-линке до YADR01 (`172.21.6.0/24`). Никогда `0.0.0.0` или localhost.

---

## PostgreSQL 🐘

```bash
sudo -u postgres psql
```
```sql
-- Примеры создания БД и пользователей:
CREATE USER forgejo WITH PASSWORD 'SuperSecret123';
CREATE DATABASE forgejo OWNER forgejo;

CREATE USER synapse WITH PASSWORD 'ТвойСуперПароль';
-- Matrix ОЧЕНЬ требователен к кодировкам — обязательно локаль 'C' и template0:
CREATE DATABASE synapse OWNER synapse ENCODING 'UTF8' LC_COLLATE = 'C' LC_CTYPE = 'C' TEMPLATE template0;

CREATE USER authentik WITH PASSWORD 'SuperSecretPassword';
CREATE DATABASE authentik OWNER authentik;

CREATE USER khrazhevnik WITH PASSWORD 'SuperSecretPassword';
CREATE DATABASE khrazhevnik OWNER khrazhevnik;
\q
```

**Конфиг:**
- Путь данных: `/var/lib/postgres/data`
- `listen_addresses = '172.20.50.10, 172.21.6.249'` (macvlan + P2P-линк до panelka)
- `pg_hba.conf`: `scram-sha-256` для `172.20.0.0/16` и `172.21.6.0/24`

---

## MongoDB 🍃

- Путь данных: `/var/lib/mongodb`
- `bindIp: 172.20.50.11,172.21.6.249`
- **Авторизация:** пользователи привязаны к конкретным БД (`authSource`). При подключении извне (DBeaver) обязательно `?authSource=имя_бд`, иначе драйвер ищет юзера в `admin` и падает с `Authentication failed`.

---

## Valkey / Redis ⚡

> Свободный форк Redis (Arch Linux перешёл на него из-за смены лицензии Redis на проприетарную). Работает 1:1 как Redis.

- Путь данных: `/var/lib/valkey`
- `bind 172.20.50.12 172.21.6.249`
- **Авторизация:** нет классических «логинов», глобальный пароль `requirepass`. В DBeaver поле «User» пустое (или `default`).

---

## RustFS 🦀 (S3)

> **Единственное** S3-хранилище узла (заменил MinIO). Современные приложения (Forgejo, Matrix, NORA, Khrazhevnik) работают с объектным хранилищем по HTTP API, а не с примонтированными SMB/NFS. Доступ — только по прямому линку `172.21.6.0/24` (endpoint `http://172.21.6.249:9000`), мимо основного коммутатора.

- **API:** `http://172.21.6.249:9000` — S3-совместимый (в rclone указывается `provider = Minio`)
- Сервисы на линке различаются портами, план адресации — в [Архитектура и сеть](../Инфраструктура/01_архитектура_и_сеть.md)

### Создание бакетов и ключей (для сервисов)
- Бакет `matrix-media` + API-ключ (для Synapse через rclone)
- Бакет `forgejo-data` + Access/Secret ключи (для Forgejo)
- Бакет `nora-storage` + Access/Secret ключи (для NORA Artifact Registry)
- Бакет `khrazhevnik` + Access/Secret ключи (для Хражевника — кеш linux-репозиториев; PostgreSQL — там же, `172.21.6.249:5432`)

---

## Бэкапы БД ⏳

> **Якорь:** раздел будет оформлен отдельно в будущем. Текущая практика — снапшоты ZFS (`tank/db`) с последующей записью на LTO-ленту; `pg_dump`/`mongodump` не используются.
