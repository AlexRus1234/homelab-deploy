# `services/` — декларации инстансов Incus на skld00

Один файл на сервис: `<имя>.yaml`. Имя файла = имя инстанса (`vm1.yaml` → инстанс `vm1`).
Файл — это **нативный YAML инстанса Incus** (тот же формат, что принимает
`incus launch <образ> <имя> < файл.yaml`) плюс политика в `user.*`-ключах и провижининг
в `cloud-init.user-data`. Подробное описание схемы и её обоснование —
`lxc-build/актуальная схема.md`.

## Пример (форма, к которой идём)

```yaml
name: vm1
description: "VictoriaMetrics single-node (данные — на датасете tank/vm-data)"
config:
  limits.cpu: "4"
  limits.memory: 4GiB
  user.role: victoriametrics
  user.update_policy: inplace          # inplace | recreate
  user.rollback_window: 24h            # сколько держим снапшоты после обновления
  user.healthcheck: "curl -fsS --max-time 5 http://127.0.0.1:8428/health && systemctl is-active --quiet victoriametrics-loc"
  cloud-init.user-data: |
    #cloud-config
    write_files:
      - path: /etc/pki/trust/anchors/homelan-root.crt
        permissions: '0644'
        content: |
          <корень домашнего CA — step-ca>
      - path: /etc/zypp/repos.d/zypper-sle-alexrus1234.repo
        permissions: '0644'
        content: |
          [zypper-sle-alexrus1234]
          name=zypper-sle-alexrus1234 (личный rpm-md, Хражевник)
          baseurl=https://khrazhevnik.panelka.yadr01.internal/repo/zypper-sle-alexrus1234
          enabled=1
          autorefresh=0
          type=rpm-md
          gpgcheck=0
    runcmd:
      - [ sh, -c, "set -e; update-ca-certificates; zypper --non-interactive refresh; zypper --non-interactive install -y --no-recommends victoriametrics-loc; systemctl enable --now victorialogs-loc 2>/dev/null || systemctl enable --now victoriametrics-loc" ]
devices:
  data:
    type: disk
    pool: default
    source: vm1-data
    path: /var/lib/victoriametrics-loc
```

## Что здесь важно

- **Данные — только томом** (`devices.data`), иначе `recreate` их теряет. Для БД объём
  берётся с датасета (`tank/vm-data`, `tank/vl-data`) с нужным uid-shifting — это отдельный
  шаг, команды ещё не зафиксированы (см. ниже).
- **`user.healthcheck`** — то, что исполняет хостовый контур и `lxc-healthcheck` внутри
  инстанса: одна строка, ненулевой код = инстанс нездоров.
- **`user.update_policy`** — `inplace` (данные и версии пакетов, БД) или `recreate`
  (меняется состав, состояние не нужно). Дефолт для новых сервисов — `recreate`.
- **`cloud-init.user-data`** отрабатывает один раз при создании: правка user-data
  существующего инстанса ничего не меняет, нужен `recreate`.
- Сети и имени хоста здесь нет: их держат профиль `default` на узле (bridge `incusbr0`)
  и шаблоны базового образа (`hostname`/`hosts`), а cloud-init в базе выключен по сети
  (`/etc/cloud/cloud.cfg.d/99-lxc.cfg`).

## Открытый пункт (шаг 2)

Тома данных и uid-shifting: как именно датасеты `tank/vm-data` / `tank/vl-data` отдаются
инстансам (`incus storage volume` + `security.shifted`, либо idmap) — решается вместе с
реализацией `reconcile.sh`. До этого декларации остаются перечислением.
