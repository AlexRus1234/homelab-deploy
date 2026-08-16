# 05 — Роутер: NGFW (DNS, QoS, IPS)

> Узел: **SHLZ00**. Превращение роутера в NGFW: гибридный DNS, умный шейпинг, IDS/IPS.
> Контекст: [SHLZ00 — Роутер](../Узлы/SHLZ00_роутер.md)

## Этап 0. Страховка (Etckeeper)

Авто-бэкап конфигов в Git:
```bash
sudo pacman -S etckeeper
sudo etckeeper init
sudo git config --system user.email "root@router"
sudo git config --system user.name "Admin"
sudo etckeeper commit "base"
```

---

## Этап 1. Гибридный DNS («Сэндвич»)

Цепочка: **Клиент → AdGuard (53) → dnsmasq (5353) → Unbound (5335) → Интернет**

**Unbound (рекурсивный резолвер):**
```bash
sudo pacman -S unbound expat
# В /etc/unbound/unbound.conf поставить port: 5335
sudo systemctl enable --now unbound
```

**dnsmasq (DHCP + backend):**
```bash
# В /etc/dnsmasq.conf:
#   port=5353
#   server=127.0.0.1#5335
sudo systemctl restart dnsmasq
```

**AdGuard Home (frontend, блокировка рекламы):**
```bash
sudo pacman -S adguardhome
sudo systemctl enable --now adguardhome
# Браузер: http://IP-РОУТЕРА:3000
# Upstream → 127.0.0.1:5353
```

---

## Этап 2. Умный шейпинг (QoS)

Борьба с Bufferbloat и лагами.

**irqbalance (распределение нагрузки прерываний по CPU):**
```bash
sudo pacman -S irqbalance
sudo systemctl enable --now irqbalance
```

**Скрипт авто-шейпинга (Python + CAKE):** `/opt/smart-shaper.py`
- Пингует шлюз провайдера. Если пинг > 50 мс → снижает скорость на 10%. Если норма → повышает на 2% раз в 10 сек.
- Лимиты: `MAX_SPEED=900 Мбит`, `MIN_SPEED=50 Мбит`.
- Upload: CAKE на `enp6s0`; Download: через виртуальный `ifb0` (mirred redirect) + CAKE.
- Лог: `journalctl -u smart-shaper -f`

```bash
sudo chmod +x /opt/smart-shaper.py
sudo systemctl enable --now smart-shaper
```

---

## Этап 3. Внутренний контроль (Ops)

```bash
# ARP слежка (защита от спуфинга, только управляемый свитч)
sudo pacman -S arpwatch
sudo systemctl enable --now arpwatch@enp5s0

# Топология (какой порт свитча, только управляемый свитч)
sudo pacman -S lldpd
sudo systemctl enable --now lldpd

# Метрики для Grafana
sudo pacman -S prometheus-node-exporter
sudo systemctl enable --now prometheus-node-exporter
```

---

## Этап 4. Безопасность (IDS/IPS)

**RAM-диск для логов (сберечь SSD):**
```bash
# /etc/fstab: tmpfs /var/log/ids-ram tmpfs defaults,size=512M 0 0
sudo mount -a
```

**Docker (для Zeek и Suricata):**
```bash
sudo pacman -S docker docker-compose
sudo systemctl enable --now docker
# Контейнеры: ~/uCPE/zeek/ и ~/uCPE/suricata/
sudo docker compose up -d
```

**CrowdSec (IPS-банхаммер):**
```bash
yay -S crowdsec crowdsec-firewall-bouncer
sudo cscli collections install crowdsecurity/suricata   # парсер логов Suricata
sudo systemctl enable --now crowdsec crowdsec-firewall-bouncer
```

---

## Этап 5. Логистика (Vector)

Забор логов из RAM:
```bash
yay -S vector-bin
sudo chmod -R 755 /var/log/ids-ram
# Конфиг /etc/vector/vector.toml (json → blackhole/nas)
sudo systemctl enable --now vector
```

---

## Финал
```bash
sudo etckeeper commit "Complete NGFW Setup"
```

---

## Быстрые команды

| Задача | Команда |
| :--- | :--- |
| Работает ли шейпер? | `journalctl -u smart-shaper -f` |
| Текут ли данные? | `journalctl -u vector -f` |
| Кто забанен? | `sudo nft list ruleset \| grep crowdsec` |
| Соседи по кабелю | `lldpcli show neighbors` |
| Статус Docker | `sudo docker ps` |
| Откат конфига | `sudo etckeeper vcs checkout /etc/файл` |
