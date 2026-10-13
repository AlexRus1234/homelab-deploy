# `services/` — декларации инстансов Incus на skld00

Один файл на сервис: `<имя>.yaml`. Имя файла = имя инстанса (`vl1.yaml` → инстанс `vl1`).
Файл — это **нативный YAML инстанса Incus** (тот же формат, что принимает
`incus launch <образ> <имя> < файл.yaml`) плюс политика в `user.*`-ключах и провижининг
в `cloud-init.user-data`. Обоснование схемы целиком — `lxc-build/актуальная схема.md`.

Эталон сейчас один — **`vl1.yaml`** (VictoriaLogs). Читать его как образец, здесь — только правила.

## Ключи `user.*`, которые читает хостовый контур

| Ключ | Смысл |
| :--- | :--- |
| `user.role` | роль сервиса (человекочитаемо, для отчётов) |
| `user.package` | имя пакета из личного rpm-md (`-loc`-суффикс — у наших сборок) |
| `user.update_policy` | `inplace` (данные сохраняем, меняются версии пакетов) или `recreate` |
| `user.rollback_window` | сколько живут снапшоты после обновления (базово `24h`) |
| `user.boot_marker` | файл-доказательство, что инстанс прошёл загрузку (`/run/lxc-boot-ok`) |
| `user.healthcheck` | одна строка пробы: ненулевой код = инстанс нездоров |
| `user.data_dataset` | датасет хоста с данными (`tank/vl-data`) |
| `user.data_mountpoint` | куда он монтируется внутри (`/var/lib/victorialogs-loc`) |
| `user.service_uid` | uid сервиса внутри; он же владелец датасета на хосте |

Скалярные ключи `config:` контур применяет живьём (`incus config set`). Всё остальное — состав
(`devices`, `raw.idmap`, `cloud-init.user-data`) — живьём не меняется: правка требует recreate,
и контур об этом сообщает, а не правит молча.

## Данные: датасет хоста, а не том внутри пула Incus

Тома внутри пула (`tank/incus/volumes/...`) под данные БД не создаём: **у zfs-драйвера нет ключа
`source`** (проверено по списку ключей тома: `block.*`, `initial.*`, `security.*`, `size`, `zfs.*`),
то есть подключить существующий датасет томом Incus нельзя, а складывать БД в пул образов —
смешивать разные вещи. Поэтому:

- датасет создаёт владелец, заранее и с нужными свойствами:

```sh
# VictoriaMetrics — метрики: мелкие случайные записи, малый блок
sudo zfs create -o recordsize=16K -o special_small_blocks=0 tank/vm-data

# VictoriaLogs — логи: записи крупнее, блок больше
sudo zfs create -o recordsize=128K -o special_small_blocks=0 tank/vl-data
```

- в декларацию он попадает устройством:

```yaml
devices:
  data:
    type: disk
    source: /tank/vl-data            # путь датасета на хосте
    path: /var/lib/victorialogs-loc  # точка монтирования внутри инстанса
```

- владельцем корня датасета должен быть uid сервиса (`479` у `victorialogs-loc`), иначе
  unprivileged-инстанс видит его как `nobody` и не может писать. Отсюда пара в декларации:

```yaml
  raw.idmap: |
    both 479 479
```

  Альтернатива — `shift: "true"` на устройстве и владелец `100479` на хосте (shifting overlay).
  Выбран первый вариант: на диске обычный `479` (`ls` понятен, `zfs send`/`syncoid` дружелюбны),
  и он не зависит от idmapped-mount на ZFS.

- снапшоты и откат данных контур делает по `zfs snapshot tank/vl-data@...`: датасет снаружи
  инстанса, поэтому переживает recreate.

## Отладочный этап: первый запуск руками, автоматика выключена

Пока на узле есть файл-выключатель `/etc/lxc-automation.off`, `reconcile.sh` **ничего не меняет** —
только печатает, что сделал бы. Владелец снимает флаг, когда захочет включить автоматику целиком.

Ручной прогон (ровно то, что потом сделает контур; `sudo` — потому что Incus и ZFS рутовые):

```sh
# 0. данные: датасет существует и принадлежит uid сервиса
zfs list tank/vl-data
sudo chown 479:479 /tank/vl-data

# 1. автоматика выключена, чтобы не вмешалась в показ
sudo touch /etc/lxc-automation.off

# 2. создание по декларации
sudo incus-loc launch leap16-base vl1 < /opt/appdata/git-repo/servers/skld00/services/vl1.yaml

# 3. наблюдение: cloud-init ставит пакет и поднимает юнит
sudo incus-loc exec vl1 -- cloud-init status --wait
sudo incus-loc exec vl1 -- journalctl -u victorialogs-loc -n 30 --no-pager

# 4. health-gate — то же, что проверяет контур
sudo incus-loc exec vl1 -- test -f /run/lxc-boot-ok && echo "загрузка пройдена"
sudo incus-loc exec vl1 -- /usr/local/sbin/lxc-healthcheck \
  --command "$(sudo incus-loc config get vl1 user.healthcheck)"

# 5. снаружи
curl -fsS "http://$(sudo incus-loc list vl1 -c4 --format csv | cut -d' ' -f1):9428/health"

# 6. переделать
sudo incus-loc delete vl1 --force
```

## Что делает автоматика после включения

| Ситуация | Действие |
| :--- | :--- |
| инстанса нет | `incus-loc launch leap16-base <имя> < декларация` → `cloud-init status --wait` → health-gate |
| инстанс есть, разошлись скаляры | `incus-loc config set` по каждому отличающемуся ключу |
| инстанс есть, изменился состав | ничего не делает, пишет «нужен recreate» (путь recreate — следующий шаг) |
| создан, но пробу не прошёл | пишет «провал» в статус и возвращает ненулевой код — сбой виден в логе хука |

Отчёт каждого прогона — строки в `/var/lib/lxc-update/status` (имя, действие, результат,
подробности, длительность). Что применено последним — `/var/lib/lxc-update/applied/<имя>`
(два хеша: состав и скаляры).

## Открытый пункт (следующий шаг)

Путь recreate: снапшот датасета и инстанса → пересоздание по изменённой декларации →
health-gate → откат при провале. Плюс ночной контур обновления пакетов (`zypper dup` со
снапшотом) и GC снапшотов по `rollback_window`/N=3.
