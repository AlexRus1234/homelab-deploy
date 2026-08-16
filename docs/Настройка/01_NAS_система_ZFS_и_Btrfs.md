# 01 — NAS: Система ZFS и Btrfs

> Узел: **SKLD00** (Arch Linux). Сборка дисковой подсистемы.
> Контекст: [SKLD00 — NAS](../Узлы/SKLD00_NAS.md)

---

## 1. Установка базовых пакетов

```bash
sudo pacman -Syu gptfdisk btrfs-progs snapper grub-btrfs inotify-tools base-devel linux-firmware dosfstools parted
```

---

## 2. Зеркала pacman (Reflector)

```bash
sudo pacman -S reflector
sudo nano /etc/xdg/reflector/reflector.conf
```

```ini
--save /etc/pacman.d/mirrorlist
--protocol https
--age 24
--number 20
--sort rate
--country Russia,Germany,Netherlands,Finland,France
```

Таймер (раз в сутки со случайной задержкой до 12ч):
```bash
sudo mkdir -p /etc/systemd/system/reflector.timer.d
sudo nano /etc/systemd/system/reflector.timer.d/override.conf
```
```ini
[Timer]
OnCalendar=
OnCalendar=daily
RandomizedDelaySec=12h
```
```bash
sudo systemctl daemon-reload
sudo systemctl start reflector.service
sudo pacman -Syy
```

---

## 3. Разметка NVMe (гибридная схема)

Создаём разделы на `nvme1n1`:
```bash
# Раздел 3 (340 GiB) — кэш загрузок
sudo sgdisk -n 3:0:+340G -t 3:8300 -c 3:"torent" /dev/nvme1n1
# Раздел 4 (350 GiB) — ZFS Metadata
sudo sgdisk -n 4:0:+350G -t 4:BF00 -c 4:"metaZFS" /dev/nvme1n1

# Клонируем разметку на второй диск и генерируем новые UUID
sudo sgdisk -R /dev/nvme0n1 /dev/nvme1n1
sudo sgdisk -G /dev/nvme0n1
```

---

## 4. Система (Root) — Btrfs RAID1

```bash
# Добавляем второй диск в корневую ФС и конвертируем в зеркало
sudo btrfs device add -f /dev/nvme0n1p2 /
sudo btrfs balance start -dconvert=raid1 -mconvert=raid1 /

# EFI на втором диске
sudo mkfs.fat -F32 /dev/nvme0n1p1
sudo grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB /dev/nvme1n1
sudo mkdir -p /mnt/efi-second
sudo mount /dev/nvme0n1p1 /mnt/efi-second
sudo grub-install --target=x86_64-efi --efi-directory=/mnt/efi-second --bootloader-id=GRUB /dev/nvme0n1
sudo umount /mnt/efi-second && sudo rmdir /mnt/efi-second
```

### Снимки системы (Snapper)
```bash
sudo partprobe
sudo snapper -c root create-config /
sudo chmod 750 /.snapshots

# Таймеры снимков
sudo systemctl enable --now snapper-timeline.timer
sudo systemctl enable --now snapper-cleanup.timer
# Слежение за снимками для GRUB
sudo systemctl enable --now grub-btrfs.path

# Первый снимок + обновление меню GRUB
sudo snapper -c root create -d "System Ready"
sudo grub-mkconfig -o /boot/grub/grub.cfg
sudo reboot
```

---

## 5. Кэш загрузок — Btrfs RAID0

```bash
sudo mkfs.btrfs -d raid0 -m raid1 -f -L torent /dev/nvme1n1p3 /dev/nvme0n1p3
sudo mkdir -p /mnt/torent
lsblk -f | grep torent   # взять UUID
sudo nano /etc/fstab
# UUID=<UUID> /mnt/torent  btrfs  defaults,noatime  0  0

sudo mount /mnt/torent
sudo btrfs subvolume create /mnt/torent/downloads
sudo chattr +C /mnt/torent/downloads   # отключить CoW (критично для больших файлов)
lsattr -d /mnt/torent/downloads        # проверка: должен быть флаг ----C---
```

---

## 6. ZFS RAIDZ2 — основное хранилище

### Установка ZFS
```bash
sudo pacman-key --recv-keys F75D9D76
sudo pacman-key --lsign-key F75D9D76
sudo nano /etc/pacman.conf
# [archzfs]
# Server = https://archzfs.com/$repo/x86_64

sudo pacman -S linux-lts-headers zfs-dkms   # идёт компиляция, нагрузит CPU
sudo modprobe zfs
```

### Создание пула `tank`
```bash
# Имена дисков по ID (не /dev/sdX — они меняются!)
ls -l /dev/disk/by-id/ | grep -v part | grep ata

sudo zpool create -f -o ashift=12 \
 -O compression=zstd \
 -O xattr=sa \
 -O acltype=posixacl \
 -O atime=off \
 -O special_small_blocks=64K \
 tank \
 raidz2 \
   /dev/disk/by-id/DISK1_ID \
   /dev/disk/by-id/DISK2_ID \
   /dev/disk/by-id/DISK3_ID \
   /dev/disk/by-id/DISK4_ID \
   /dev/disk/by-id/DISK5_ID \
   /dev/disk/by-id/DISK6_ID \
 special mirror \
   /dev/nvme1n1p4 \
   /dev/nvme0n1p4
```

### Персистентность и автомунтирование
```bash
sudo zpool set cachefile=/etc/zfs/zpool.cache tank
sudo systemctl enable zfs-import-cache zfs-mount zfs.target

zpool status -v
zfs list

sudo zfs create tank/data
sudo chown -R <user>:<user> /tank/data
touch /tank/data/testfile && ls -l /tank/data/
```

### Тюнинг под SMB/базы (решение зависаний)
```bash
sudo zfs set sync=disabled tank/data            # убирает нагрузку на ZIL
sudo zfs set special_small_blocks=0 tank/data   # не насиловать SSD мелкими блоками
sudo zfs set compression=zstd tank/data
```

### «Упорный» импорт пула (retry-loop)
Если пул не поднимается с первого раза, служба ждёт 5 сек и пробует снова:
```bash
sudo nano /etc/systemd/system/zfs-force-import.service
```
```ini
[Unit]
Description=Force Import ZFS Pool Tank (Retry Loop)
After=modprobe@zfs.service
Requires=modprobe@zfs.service
After=network.target

[Service]
Type=simple
Restart=on-failure
RestartSec=5s
TimeoutStartSec=180
ExecStart=/bin/sh -c '/usr/bin/zpool list tank >/dev/null 2>&1 || /usr/bin/zpool import -f -d /dev/disk/by-id tank'
ExecStartPost=/usr/bin/zfs mount -a

[Install]
WantedBy=multi-user.target
```
```bash
sudo systemctl daemon-reload
sudo systemctl enable zfs-force-import.service
```

### Обслуживание
```bash
sudo zpool scrub tank    # ручная проверка целостности
# Авто-Scrub: таймер раз в месяц (1-го числа)
```
