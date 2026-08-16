# 12 — VPN: Headscale + Caddy + VPS

> Доступ в домашнюю сеть из любой точки мира через свой DERP-релей и Split DNS для `.internal`.
> VPS: Headscale (порт 8085) + Caddy. Дом: роутер SHLZ00 (Tailscale-клиент, анонс `172.20.0.0/16`).

## На VPS — `/etc/hosts`
```
127.0.1.1   <hostname>.serv.host <hostname>
```

---

## Этап 1. Сеть и Firewall (VPS)

`/etc/nftables.conf`:
```nft
# В chain input добавить:
tcp dport { 80, 443 } accept     # Caddy
udp dport 3478 accept            # Headscale DERP (STUN)

# Полностью заменить chain forward (для Docker NAT):
chain forward {
    type filter hook forward priority 0; policy drop;
    ct state established,related accept
    iifname "docker0" accept
    oifname "docker0" accept
    iifname "br-*" accept
    oifname "br-*" accept
}
```
```bash
sudo nft -f /etc/nftables.conf
```

---

## Этап 2. Docker (VPS)
```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
sudo systemctl restart docker   # критично: пересоздаёт цепочки iptables поверх nftables
```

---

## Этап 3. Headscale (VPS, порт 8085)

```bash
sudo mkdir -p /opt/headscale/{config,data}
sudo chown -R $USER:$USER /opt/headscale
cd /opt/headscale
wget -O config/config.yaml https://raw.githubusercontent.com/juanfont/headscale/main/config-example.yaml
```

`config/config.yaml` (ключевое):
```yaml
server_url: https://vpn.alexrus1234.ru
listen_addr: 0.0.0.0:8080
metrics_listen_addr: 127.0.0.1:9090

dns:
  magic_dns: true
  base_domain: vds.alexrus1234.ru      # должен ОТЛИЧАТЬСЯ от server_url
  override_local_dns: true
  nameservers:
    global: [ 77.88.8.8, 77.88.8.1 ]
    split:
      internal: [ 172.20.0.1 ]          # .internal → домашний роутер

derp:
  server:
    enabled: true
    region_id: 999
    region_code: "my-derp"
    region_name: "My Headscale DERP"
    ipv4: "<ВНЕШНИЙ_IP_VPS>"            # внешний IP VPS
    stun_listen_addr: "0.0.0.0:3478"
```

`docker-compose.yml`:
```yaml
services:
  headscale:
    image: headscale/headscale:latest
    container_name: headscale
    volumes:
      - ./config:/etc/headscale
      - ./data:/var/lib/headscale
    ports:
      - "127.0.0.1:8085:8080"
      - "3478:3478/udp"
    dns: [ 77.88.8.8, 77.88.8.1 ]
    command: serve
    restart: unless-stopped
```
```bash
docker compose up -d
curl -v http://127.0.0.1:8085/health    # ok
docker exec headscale headscale users create <user>
```

---

## Этап 4. Caddy (VPS)
```bash
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update && sudo apt install caddy
```

`/etc/caddy/Caddyfile`:
```caddyfile
vpn.alexrus1234.ru {
    reverse_proxy 127.0.0.1:8085 {
        header_up X-Real-IP {remote}
        header_up X-Forwarded-For {remote}
        header_up X-Forwarded-Proto {scheme}
    }
}

homer.alexrus1234.ru {
    reverse_proxy https://homer.yadr00.internal {
        transport http { tls_insecure_skip_verify }
        header_up Host {upstream_hostport}
        header_up X-Real-IP {remote_host}
    }
}
```
```bash
sudo systemctl reload caddy
```

---

## Этап 5. Домашний роутер (Arch Linux)
```bash
echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-tailscale.conf
sudo sysctl -p /etc/sysctl.d/99-tailscale.conf

sudo pacman -S tailscale
sudo systemctl enable --now tailscaled

sudo tailscale up \
  --login-server https://vpn.alexrus1234.ru \
  --advertise-routes=172.20.0.0/16 \
  --accept-routes \
  --accept-dns=false
```

Регистрация (на VPS):
```bash
docker exec headscale headscale nodes register --user <user> --key mkey:КЛЮЧ_РОУТЕРА
```

---

## Этап 6. Связывание сетей (на VPS)

```bash
# Одобрить маршрут роутера
docker exec headscale headscale nodes list
docker exec headscale headscale nodes approve-routes -i ID_РОУТЕРА -r 172.20.0.0/16

# Подключить сам VPS к VPN
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --login-server https://vpn.alexrus1234.ru --accept-routes --accept-dns=false

# Split DNS на Debian (VPS)
sudo apt install systemd-resolved -y
sudo systemctl enable --now systemd-resolved
sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
sudo resolvectl dns tailscale0 172.20.0.1
sudo resolvectl domain tailscale0 internal
sudo resolvectl flush-caches

resolvectl query homer.yadr00.internal   # проверка
```

---

## Этап 7. Клиенты (Android/PC)
1. В приложении Tailscale: Change Server → `https://vpn.alexrus1234.ru` → Log in.
2. Скопировать ключ из браузера.
3. На VPS: `docker exec headscale headscale nodes register --user <user> --key mkey:КЛЮЧ_КЛИЕНТА`.

---

## VPS: базовая защита (ручная настройка)

Кратко (идемпотентный скрипт авто-настройки):
- **Пользователь + SSH** (порт рандомный `40000-65000`, `PasswordAuthentication no`, `PermitRootLogin no`, ключи ed25519).
- **Swap 2G**, ядро **BBR** + `rp_filter`, лимит journald `200M`.
- **Endlessh** (tarpit на 22 порт) + **nftables** (drop по умолчанию).
- **CrowdSec** + `crowdsec-firewall-bouncer-nftables` + коллекция `crowdsecurity/endlessh`.
