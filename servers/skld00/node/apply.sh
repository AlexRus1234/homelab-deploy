#!/bin/bash
# Конфиги узла skld00: три источника метрик (node/smartctl/zfs) и Vector для логов.
#
# Запускается деплоем (../sync-state.sh, до контура инстансов) и вручную:
#   sudo /opt/appdata/git-repo/servers/skld00/node/apply.sh
#
# Что НЕ делает: не ставит пакеты и не меняет enable-состояние юнитов — установка и службы на
# узле принадлежат владельцу. Наш шаг — файлы конфигов и перезапуск того юнита, чей конфиг
# изменился (иначе новые аргументы не вступят в силу). Нет бинарника или юнит не активен —
# провал прогона с готовой командой, а не молчаливое действие за владельца.
#
# Идемпотентно: файл кладётся только при расхождении, юнит перезапускается только тогда,
# когда его конфиг менялся.
#
# Окружение подменяемо (ETC, LISTEN_ADDR, SYSTEMCTL, SS, NODE_DIR) — на этом стоит
# tests/node-test.sh, который гоняет скрипт без узла.
set -uo pipefail

NODE_DIR=${NODE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
ETC=${ETC:-/etc}
TEXTFILE_DIR=${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}
LISTEN_ADDR=${LISTEN_ADDR:-172.26.50.1}   # адрес бриджа observ0: его видят только инстансы
PORTS="9100 9633 9134"                    # порты источников (для приёмки ниже)
SYSTEMCTL=${SYSTEMCTL:-systemctl}
SS=${SS:-ss}
OFF_FLAG=${OFF_FLAG:-/etc/lxc-automation.off}
DRY_RUN=${DRY_RUN:-0}
FAIL=0

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

# Выключатель у нас общий с остальной автоматикой: пока флаг на месте, ничего не меняем.
if [ -f "$OFF_FLAG" ]; then
    log "АВТОМАТИКА ОТКЛЮЧЕНА ($OFF_FLAG): только показываю, что сделал бы"
    DRY_RUN=1
fi

units=(node_exporter-loc smartctl_exporter-loc zfs_exporter-loc vector-loc)
srcs=(exporters/node_exporter/node_exporter.conf
      exporters/smartctl_exporter/smartctl_exporter.conf
      exporters/zfs_exporter/zfs_exporter.conf
      vector/vector.yaml)
dsts=("$ETC/conf.d/node_exporter-loc"
      "$ETC/conf.d/smartctl_exporter-loc"
      "$ETC/conf.d/zfs_exporter-loc"
      "$ETC/vector-loc/vector.yaml")

# --- пакеты: только проверка, доставки НЕТ ------------------------------------
# Пакеты ставит владелец узла (и сервисы могут быть уже установлены и запущены под своими
# юнитами) — автоустановка из репо здесь была бы самоуправством. Нет бинарника → провал
# прогона с готовой командой, а не повод что-то доставлять.
for u in "${units[@]}"; do
    command -v "$u" >/dev/null 2>&1 && continue
    log "ОШИБКА: нет бинарника $u — пакет ставит владелец узла: pacman -S --needed $u"
    FAIL=1
done

# --- файлы конфигов -----------------------------------------------------------
changed=()
for i in "${!units[@]}"; do
    u="${units[$i]}"; src="$NODE_DIR/${srcs[$i]}"; dst="${dsts[$i]}"
    if [ ! -f "$src" ]; then
        log "ОШИБКА: нет файла конфига $src"
        FAIL=1; continue
    fi
    if cmp -s "$src" "$dst"; then continue; fi
    if [ "$DRY_RUN" = 1 ]; then log "сделал бы: install -D -m0644 $src $dst"; continue; fi
    if install -D -m0644 "$src" "$dst"; then
        log "конфиг обновлён: $dst"
        changed+=("$u")
    else
        log "ОШИБКА: не разложил $dst"
        FAIL=1
    fi
done

# --- юниты: наш шаг — конфиг, а не состояние службы ----------------------------
# enable-состояние не меняем: службы на узле заведены владельцем (и уже могут работать под
# своими юнитами). Доводим конфиг и перезапускаем тот юнит, чей конфиг изменился — иначе
# новые аргументы не вступят в силу.
if [ "$DRY_RUN" != 1 ]; then
    install -d -m 0755 "$TEXTFILE_DIR" 2>/dev/null \
        || log "ВНИМАНИЕ: не создал $TEXTFILE_DIR (метрики контура пишет update.sh)"
fi
for i in "${!units[@]}"; do
    u="${units[$i]}"
    if [ "$DRY_RUN" = 1 ]; then log "сделал бы: $SYSTEMCTL restart $u (только если конфиг менялся)"; continue; fi
    if ! $SYSTEMCTL is-enabled --quiet "$u" 2>/dev/null; then
        log "ВНИМАНИЕ: юнит $u не включён — после перезагрузки служба не поднимется (включает владелец: systemctl enable $u)"
    fi
    case " ${changed[*]-} " in
        *" $u "*)
            if ! $SYSTEMCTL is-active --quiet "$u" 2>/dev/null; then
                log "ОШИБКА: юнит $u не активен — конфиг разложен, но применить его некому (запуск за владельцем: systemctl start $u)"
                FAIL=1
            elif $SYSTEMCTL restart "$u" >/dev/null 2>&1; then
                log "юнит перезапущен (конфиг изменился): $u"
            else
                log "ОШИБКА: $SYSTEMCTL restart $u"
                FAIL=1
            fi ;;
    esac
done

if [ "$DRY_RUN" = 1 ]; then
    log "отчёт: конфиги узла не применялись (режим отчёта)"
    exit "$FAIL"
fi

# --- приёмка ------------------------------------------------------------------
# Главное здесь — адрес: источник, слушающий 0.0.0.0 или чужой адрес, виден из других
# сегментов, и это ровно то, чего быть не должно.
listen=$($SS -H -ltn 2>/dev/null | awk '{print $4}' \
         | grep -E "^${LISTEN_ADDR//./\\.}:($(printf '%s' "$PORTS" | tr ' ' '|'))$" | sort -u)
got=$(printf '%s\n' "$listen" | grep -c .)
if [ "$got" = 3 ]; then
    log "приёмка: три источника слушают только $LISTEN_ADDR — $(printf '%s ' $listen)"
else
    log "ОШИБКА: ждал три источника на $LISTEN_ADDR (порты $PORTS), вижу:"
    $SS -H -ltn 2>/dev/null | awk '{print $4}' | grep -E ":(9100|9633|9134)$" | sort -u | sed 's/^/    /'
    log "    (0.0.0.0 или чужой адрес = источник виден из других сегментов)"
    FAIL=1
fi
for u in node_exporter-loc smartctl_exporter-loc zfs_exporter-loc vector-loc; do
    $SYSTEMCTL is-active --quiet "$u" || { log "ОШИБКА: $u не активен"; FAIL=1; }
done

if [ "$FAIL" = 0 ]; then
    log "конфиги узла: ок (метрики — в victoriametrics1, логи — в VictoriaLogs; см. README.md)"
else
    log "конфиги узла: провал — смотри строки выше"
fi
exit "$FAIL"
