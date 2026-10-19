# Конфиги узла skld00 (источники метрик и логи)

Всё, что живёт **на самом узле**, а не в инстансах: три экспортёра Prometheus и Vector.
Инстансы описаны рядом, в `../services/`, сети — в `../networks/`.

## Зачем именно так

- **Источники метрик не видны нигде, кроме нашего сегмента.** Экспортёры слушают адрес
  `172.26.50.1` — это адрес бриджа `observ0` на узле. Тот же сегмент держат инстансы на
  `eth2`, поэтому `172.26.50.100` (victoriametrics1) их видит, а LAN — нет. Ни один из трёх
  не слушает `0.0.0.0`: иначе источники были бы доступны из LAN, чего быть не должно.
- **Метрики контура приезжают через `node_exporter`.** `update.sh` пишет
  `/var/lib/node_exporter/textfile_collector/lxc.prom` (`lxc_instance_health`,
  `lxc_last_update_success_timestamp`, счётчики уборки). Достаточно `textfile.directory` в
  аргументах — отдельный экспортёр контуру не нужен. Коллектор `zfs` у `node_exporter`
  включён по умолчанию, флаг ему не нужен.
- **Логи уезжают сами**: Vector читает журнал узла и шлёт их в VictoriaLogs
  (`172.26.50.101:9428`) через ES-совместимый приём. Метрики, в отличие от логов,
  забирает victoriametrics1 (pull по статик-таргетам) — поэтому у Vector одна задача, а не две.

## Раскладка: файл в репо → путь на узле

| Файл здесь | Куда кладётся |
|---|---|
| `exporters/node_exporter/node_exporter.conf` | `/etc/conf.d/node_exporter-loc` |
| `exporters/smartctl_exporter/smartctl_exporter.conf` | `/etc/conf.d/smartctl_exporter-loc` |
| `exporters/zfs_exporter/zfs_exporter.conf` | `/etc/conf.d/zfs_exporter-loc` |
| `vector/vector.yaml` | `/etc/vector-loc/vector.yaml` |

`apply.sh` раскладывает их и перезапускает **только те юниты, чей конфиг менялся** (иначе новые
аргументы не вступят в силу). Пакеты он **не ставит** и enable-состояние юнитов **не меняет**:
установка и службы на узле — владельца; отсутствие бинарника или неактивный юнит дают провал
прогона с готовой командой. Запускается деплоем (`../sync-state.sh` — до инстансов) и вручную:

Если службы на узле живут под **своими** юнитами (не под юнитами пакета), они обязаны читать эти
же файлы: `ExecStart=/usr/bin/<имя> $<ИМЯ>_ARGS` плюс `EnvironmentFile=-/etc/conf.d/<имя>`. Иначе
конфиг разложится, но аргументы не применятся — это видно по приёмке ниже (источник окажется на
`*`, а не на `172.26.50.1`).

```sh
sudo /opt/appdata/git-repo/servers/skld00/node/apply.sh
```

## Приёмка (её же печатает apply.sh)

```sh
ss -ltnp | grep -E ':(9100|9633|9134)\b'                 # ждём 172.26.50.1:..., НЕ 0.0.0.0
curl -sf 172.26.50.1:9100/metrics | grep -m1 lxc_instance_health   # метрики контура здесь
curl -sf 172.26.50.1:9134/metrics | grep -m1 zfs_pool_              # пулы (нужен tank)
curl -sf 172.26.50.1:9633/metrics | grep -m1 smartctl_version       # диски узла
systemctl is-active node_exporter-loc smartctl_exporter-loc zfs_exporter-loc vector-loc
```

Со стороны получателей: в victoriametrics1 три таргета `health: "up"`
(`curl -s http://172.26.50.100:8428/api/v1/targets`), в VictoriaLogs — строки узла
(`curl -s 'http://172.26.50.101:9428/select/logsql/query?query=*&limit=3'`).

## Что здесь легко забыть

- **`smartctl_exporter` не стартует в контейнере и ВМ** — в юните
  `ConditionVirtualization=false`, потому что SMART берётся с железа. На узле это норма,
  а проверку старта надо делать на нём же.
- **`zfs_exporter-loc` требует пакет `zfs-utils`** (ходит в `zfs`/`zpool` через CLI, не
  линкуется с libzfs). На узле он есть — в зеркале ZFS нет, поэтому при установке
  из репо зависимость берётся из системы.
- **Vector пишет в VL и собственные логи.** Если это мешает, ограничить набор юнитов
  (`include_units`) в `vector/vector.yaml`.
- **`unit` в журнале не существует**: Vector отдаёт `SYSLOG_IDENTIFIER`, поэтому в конфиге
  стоит трансформация `normalize` — без неё стрим в VL получится только по хосту.
- **Получатели (VL и VM) слушают `0.0.0.0` — это осознанно** (решение владельца): дашборды
  открываются из LAN, а прячутся только источники.
