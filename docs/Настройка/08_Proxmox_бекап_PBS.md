# 08 — Proxmox: Монтирование SMB и Backup Server (PBS)

> Ноды YADR00/YADR01 (Proxmox VE). Подключение NAS, бэкап хостов и ВМ.
> Контекст: [SKLD00 — NAS](../Узлы/SKLD00_NAS.md)

## 1. Прямой линк Proxmox ↔ NAS

Point-to-Point `/31` для ускорения трафика БД.

**На Proxmox** (`/etc/network/interfaces`):
```text
auto nic1
iface nic1 inet static
        address 172.21.6.254/31
```
```bash
ifreload -a
ip a show nic1
```

**На Arch (NAS)** (`/etc/systemd/network/10-enp8s0.network`):
```ini
[Match]
Name=enp8s0

[Network]
Address=172.21.6.255/31
```
```bash
sudo systemctl restart systemd-networkd
ping 172.21.6.254   # проверка с обеих сторон
```

---

## 2. Монтирование SMB-шары NAS в LXC

**Задача:** непривилегированные LXC (Paperless, Karakeep и др.) пишут на NAS, но данные хранятся на SKLD00.

**Дано:** NAS `172.20.50.1`, шара `Share`, подпапка `YADR/shara/yadr00`.

### Шаг 1. Скрытый файл пароля
```bash
nano /root/.smbcredentials
# username=ВАШ_ЛОГИН
# password=ВАШ_ПАРОЛЬ
chmod 600 /root/.smbcredentials
```

### Шаг 2. Папки на хосте
```bash
mkdir -p /mnt/.nas_root_hidden
mkdir -p /mnt/becap
```

### Шаг 3. Двойное монтирование (fstab)
```bash
nano /etc/fstab
```
```text
# 1. Техническое монтирование корня NAS (скрыто)
//172.20.50.1/Share /mnt/.nas_root_hidden cifs credentials=/root/.smbcredentials,uid=100000,gid=100000,forceuid,forcegid,dir_mode=0777,file_mode=0777,iocharset=utf8,noperm,nofail 0 0

# 2. Bind только рабочей папки
/mnt/.nas_root_hidden/YADR/becap /mnt/becap none bind 0 0
```
```bash
systemctl daemon-reload
mount -a
ls -ln /mnt/becap   # владелец должен быть 100000 100000
```

> `uid=100000, forceuid` — внутри непривилегированного контейнера root имеет ID 100000. Без `forceuid` будет `Permission Denied`.

### Шаг 4. Проброс в контейнеры
```bash
mkdir -p /mnt/nas_data/paperless_media
pct set 106 -mp0 /mnt/nas_data/paperless_media,mp=/opt/paperless/media
pct set 111 -mp0 /mnt/nas_data/karakeep_data,mp=/opt/hoarder/data
```

---

## 3. Proxmox Backup Server (PBS)

**Подводный камень:** `/etc/pve` — это `pmxcfs` (FUSE/SQLite в памяти). Обычный бэкап `/etc` пропустит её как «другую ФС». Поэтому `/etc` и `/etc/pve` бэкапим как **два отдельных архива**.

### Шаг 1. На стороне PBS (юзер и токен)
В веб-интерфейсе PBS:
1. **Configuration → Access Control → User Management:** добавить `<user>@pbs`.
2. **API Tokens:** создать токен `hostbackup` → **скопировать Token Secret** (больше не покажут). Полное имя: `<user>@pbs!hostbackup`.
3. **Permissions → API Token Permission:**
   - Path `/datastore/shara/yadr00`, токен `<user>@pbs!hostbackup`, Role `DatastoreBackup`.
   - Path `/datastore/shara/yadr01`, тот же токен, та же роль.

### Шаг 2. Скрипт бэкапа на ноде PVE
`/root/backup-host.sh` (на YADR00):
```bash
#!/bin/bash
export PBS_REPOSITORY='<user>@pbs!hostbackup@172.20.6.3:8007:shara'
export PBS_PASSWORD='ТОКЕН_SECRET_ИЗ_БЛОКНОТА'
export PBS_FINGERPRINT=''

echo "Starting backup of /etc to PBS..."
proxmox-backup-client backup host-etc.pxar:/etc --ns yadr00
echo "Backup finished."
```
```bash
chmod +x /root/backup-host.sh
/root/backup-host.sh   # тест руками
```

На YADR01 — то же, но `--ns yadr01`.

### Шаг 3. Автоматизация (cron)
```bash
crontab -e
# 0 3 * * * /root/backup-host.sh > /dev/null 2>&1
```

---

## 4. Восстановление из бэкапа

### Полное восстановление хоста (сгорел SSD)
FUSE-монтирование архива прямо на чистом Proxmox:
```bash
mkdir /mnt/host_backup
export PROXMOX_BACKUP_FINGERPRINT=""
export PROXMOX_BACKUP_PASSWORD="ПАРОЛЬ_PBS"

proxmox-backup-client mount host/yadr01/2026-03-15T07:27:41Z host-etc.pxar /mnt/host_backup \
  --repository root@pam@172.20.6.3:ИМЯ_ДАТАСТОРА --ns yadr00

ls -la /mnt/host_backup
```

Восстановление:
```bash
cp -r /mnt/host_backup/pve/* /etc/pve/           # ВМ и хранилища (магия pmxcfs на лету)
cp /mnt/host_backup/network/interfaces /etc/network/interfaces
cp /mnt/host_backup/hostname /etc/hostname
cp /mnt/host_backup/hosts /etc/hosts
cp -a /mnt/host_backup/ssh/ssh_host_* /etc/ssh/  # ключи
cp /mnt/host_backup/passwd /etc/passwd           # пользователи
cp /mnt/host_backup/shadow /etc/shadow
cp /mnt/host_backup/group /etc/group
cp /mnt/host_backup/vzdump.conf /etc/vzdump.conf
systemctl daemon-reload
```

> 🛑 **КАТЕГОРИЧЕСКИ НЕЛЬЗЯ копировать `fstab`** — новые диски имеют другие UUID, система упадёт в `initramfs`.

```bash
cd && umount /mnt/host_backup && reboot
```

### Скрипт-автомат восстановления
`/tmp/restore.sh` — тянет архивы `system-etc.pxar` и `proxmox-cluster.pxar` через `proxmox-backup-client restore`, раскладывает критичные файлы автоматически.

### Достать один файл через веб-интерфейс PBS
Datastore → Namespace (`yadr00`) → группа `host/host-etc` → снапшот по дате → иконка **File Restore** → проводник в браузере → **Download**.

> Тяжёлые данные (медиа Paperless и др.) лежат на NAS через SMB — PBS их **не** бэкапит (внешнее монтирование), экономя место и время.
