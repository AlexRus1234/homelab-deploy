# 06 — PKI: Свой центр сертификации (Step-CA)

> Узел CA: **SHLZ00** (`172.20.0.1`). Выпуск валидных сертификатов для зоны `.internal` через ACME.
> Контекст: [SHLZ00 — Роутер](../Узлы/SHLZ00_роутер.md)

## Часть 1. Настройка сервера CA (Arch Linux)

### 1. Установка и пользователь
```bash
sudo pacman -S step-ca step-cli

sudo useradd --system --user-group --shell /usr/bin/nologin --home-dir /etc/step-ca step
sudo mkdir -p /etc/step-ca
```

### 2. Инициализация (генерация ключей)
```bash
step-cli ca init
```
Ответы:
- Deployment Type: `Standalone`
- Name: `My Local CA`
- DNS: `172.20.0.1`
- Address: `:9000` (с двоеточием в начале)
- Provisioner: `admin@localhost`
- Password: придумать и запомнить

Добавить поддержку ACME (для Caddy):
```bash
step-cli ca provisioner add acme --type ACME
```

### 3. Перенос файлов и исправление путей
```bash
sudo cp -r ~/.step/* /etc/step-ca/
sudo sed -i "s|$HOME/.step|/etc/step-ca|g" /etc/step-ca/config/ca.json
sudo sed -i "s|$HOME/.step|/etc/step-ca|g" /etc/step-ca/config/defaults.json

sudo sh -c 'echo "ВАШ_ПАРОЛЬ" > /etc/step-ca/password.txt'
sudo chown -R step:step /etc/step-ca
sudo chmod 600 /etc/step-ca/password.txt
```

### 4. Служба Systemd
`/etc/systemd/system/step-ca.service.d/override.conf`:
```ini
[Service]
User=step
Group=step
ExecStart=
ExecStart=/usr/bin/step-ca /etc/step-ca/config/ca.json --password-file /etc/step-ca/password.txt
WorkingDirectory=/etc/step-ca
```
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now step-ca
sudo systemctl status step-ca   # active (running)
```

### 5. Firewall (nftables)
В секцию `chain input` добавить `tcp dport 9000 accept`, применить `sudo nft -f /etc/nftables.conf`.

---

## Часть 2. Настройка клиентов (Caddy)

### 1. Корневой сертификат
```bash
# На CA: показать содержимое
cat /etc/step-ca/certs/root_ca.crt
# На сервере Caddy: вставить в /etc/caddy/root_ca.crt
```

### 2. Caddyfile (глобальные настройки)
```caddy
{
    acme_ca https://172.20.0.1:9000/acme/acme/directory
    acme_ca_root /etc/caddy/root_ca.crt
}

mysite.internal {
    reverse_proxy localhost:8080
}
```
```bash
sudo systemctl restart caddy
```

---

## Часть 3. Доверие в браузерах

Чтобы открывать `.internal` с «зелёным замочком», установить `root_ca.crt` на устройства:
- **Windows:** файл → Установить сертификат → Локальный компьютер → «Доверенные корневые центры сертификации».
- **Android:** Настройки → Безопасность → Установить сертификат CA.
- **Linux:** в `/etc/ca-certificates/trust-source/anchors/`, затем `update-ca-trust`.

---

## Часть 4. Сценарии эксплуатации

**Добавить новый сайт** — просто блок в Caddyfile, сертификат выпустится мгновенно.

**Подключить новое устройство** — открыть `https://172.20.0.1:9000/roots.pem`, скачать `roots.pem`, установить как корневой CA.

**Ручной выпуск сертификата (без Caddy):**
```bash
step-cli ca certificate "myservice.db" myservice.crt myservice.key \
  --ca-url=https://172.20.0.1:9000 \
  --root=root_ca.crt
```

**Проверка здоровья:**
```bash
curl -k https://172.20.0.1:9000/health
# {"status":"ok"}
```

> Главное правило: **Caddy всё делает сам.** Единственная задача — распространить `root_ca.crt` на устройства. Дальше CA работает как чёрный ящик.
