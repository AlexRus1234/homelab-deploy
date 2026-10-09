# 13 — Intermasq: Менеджер dnsmasq

> Intermasq — модульный менеджер конфигурации `dnsmasq` (Go + Vue 3, единый бинарник ~10 МБ), работает на роутере SHLZ00. Этот гайд — установка и эксплуатация в контуре homelab; исходный код и полная документация — отдельный репозиторий **`Intermasq`** (`~/proj/Repo/Intermasq`).

## Intermasq — концепция безопасности (Rootless)

- Служба запущена от выделенного непривилегированного пользователя `intermasq` (режим «systemd via sudo» из README проекта; лог старта подскажет выбранный режим: `[INIT] System: systemd (via sudo)`).
- Запись разрешена только в `/etc/intermasq/` и `/etc/dnsmasq.d/`.
- Повышение прав — только через `sudo -n` по sudoers-файлу `/etc/sudoers.d/intermasq`:
  ```sudoers
  intermasq ALL=(root) NOPASSWD: /usr/bin/systemctl is-active dnsmasq
  intermasq ALL=(root) NOPASSWD: /usr/bin/systemctl restart dnsmasq
  intermasq ALL=(root) NOPASSWD: /usr/bin/systemctl restart intermasq
  ```

---

## Возможности

**Управление статикой:** чтение всех `dhcp-host` из `/etc/dnsmasq.d/*.conf`, умные вкладки по файлам, редактирование в один клик, массовое удаление чекбоксами.

**Импорт:** вставка сырого текста (Excel/консоль) → Smart Regex распознаёт MAC/IP/Hostname → предпросмотр → батч-запись.

**Мониторинг:** индикатор «Онлайн» через ARP-кэш ядра (каждые 30с), список активных аренд DHCP, быстрый перенос аренды в статику.

**Безопасность:** кнопка «Откат» (`.bak` перед каждым изменением), Pre-flight Check (`dnsmasq --test` — нельзя «положить» DNS опечаткой), Live Backup в ZIP, JWT-авторизация, защита от Path Traversal.

---

## REST API (требуют `Authorization: Bearer <token>`, кроме `/status` и `/login`)

| Метод | Назначение |
| :--- | :--- |
| `GET /api/status` | Статус инициализации |
| `POST /api/login` | Авторизация |
| `GET /api/hosts` | Статические записи |
| `GET /api/leases` | Динамические аренды |
| `GET /api/arp` | Живые MAC |
| `POST /api/hosts` | Добавить/обновить запись |
| `POST /api/hosts/bulk` | Массовое добавление |
| `DELETE /api/hosts/:mac?file=/path` | Удалить запись |
| `POST /api/rollback` | Откат файла из `.bak` |
| `POST /api/reload` | Валидация + рестарт dnsmasq |
| `GET /api/backup` | Скачать ZIP конфигов |

---

## De-provisioning (умное удаление)
1. Остановить контейнер в Proxmox.
2. Скопировать MAC.
3. В интерфейсе плагина → «Очистка инфраструктуры» → вставить MAC → «Удалить всё».
4. Плагин удаляет HTTP/TLS маршруты в Caddy по ID и стирает запись в dnsmasq.
