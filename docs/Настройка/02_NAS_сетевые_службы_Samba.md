# 02 — NAS: Сетевые службы (Samba)

> Узел: **SKLD00**. Файловая шара SMB.
> Контекст: [SKLD00 — NAS](../Узлы/SKLD00_NAS.md)

---

## 1. Samba — файловый сервер `\\SKLD00\Share`

### Установка и пользователь
```bash
sudo pacman -S samba wsdd avahi
sudo smbpasswd -a <user>   # пароль для доступа к шаре
```

### Конфиг `/etc/samba/smb.conf`
```ini
[global]
  workgroup = WORKGROUP
  server string = SKLD00 File Server
  netbios name = SKLD00
  security = user
  map to guest = Bad User
  log file = /var/log/samba/%m.log
  max log size = 50
  logging = systemd
  server min protocol = SMB2

  # Оптимизации для Apple/ZFS/Windows
  vfs objects = catia fruit streams_xattr
  fruit:metadata = stream
  fruit:model = MacSamba
  fruit:posix_rename = yes
  fruit:veto_appledouble = no
  fruit:nfs_aces = no
  fruit:wipe_intentionally_left_blank_rfork = yes
  fruit:delete_empty_adfiles = yes

[Share]
  path = /tank/data
  read only = no
  browsable = yes
  valid users = <user>
  create mask = 0664
  directory mask = 0775
```

### Обнаружение для Linux/macOS (Avahi)
`/etc/avahi/services/samba.service`:
```xml
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
 <name replace-wildcards="yes">%h</name>
 <service>
   <type>_smb._tcp</type>
   <port>445</port>
 </service>
 <service>
   <type>_device-info._tcp</type>
   <port>0</port>
   <txt-record>model=RackMac</txt-record>
 </service>
</service-group>
```

### Права на ZFS
```bash
sudo chown -R <user>:<user> /tank/data
```

### Костыль «nas-kickstart» (Samba падает при медленном старте сети)
Служба ждёт 20 сек после загрузки и принудительно поднимает всё нужное:
```bash
sudo systemctl disable smb nmb wsdd avahi-daemon
sudo nano /etc/systemd/system/nas-kickstart.service
```
```ini
[Unit]
Description=Force start Samba and WSDD after boot
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c "sleep 20; systemctl start smb nmb wsdd avahi-daemon"

[Install]
WantedBy=multi-user.target
```
```bash
sudo systemctl enable nas-kickstart.service
sudo reboot
```

**Результат:** Windows видит сервер как `\\SKLD00`, шара всегда доступна после ребута.
