#!/bin/bash
# Ночной контур skld00: обновление пакетов внутри инстансов и уборка снапшотов/стоянок.
#
# Запускается systemd-таймером (окно 02:00–03:00, случайный сдвиг — lxc-update.timer)
# или руками:
#   update.sh                 # обновить все сервисы с политикой inplace и убрать старое
#   update.sh --gc-only       # только уборка
#   update.sh --one vl1       # только один сервис (уборка не идёт)
#   update.sh --dry-run       # только план (то же делает флаг /etc/lxc-automation.off)
#
# Что считается успешным обновлением (по порядку):
#   снапшот инстанса + снапшот датасета → флаг незавершённого обновления ВНУТРИ инстанса →
#   `zypper dup` → restart → маркер загрузки ОБНОВИЛСЯ → состояние systemd → проба сервиса
#   с повторами. Провал на любом шаге → откат: `incus snapshot restore` + `zfs rollback`
#   + старт + проба снова. Флаг снимается только после успешной пробы: флаг, найденный на
#   старте (прошлый прогон умер), уводит сервис сразу в ветку откатa, а не «продолжает как
#   будто всё нормально».
#
# Уборка (GC) — только НАШИ снапшоты и стоянки, и только когда живость доказана:
#   * старше user.rollback_window (базово 24h) и не входят в N=3 самых свежих;
#   * сервис запущен и проба user.healthcheck проходит ПРЯМО СЕЙЧАС (три попытки с паузами);
#   * иначе по этому сервису уборки нет вовсе — в отчёт пишется, почему.
# Серия успешных проб внутри инстанса (/var/lib/lxc-health.streak) в отчёт попадает как справка,
# но уборку не запирает: она сбрасывается перезапуском, а перезапуск делает как раз обновление.
# Сервисы с политикой recreate ночной контур не трогает: они обновляются пересозданием
# (reconcile.sh --recreate <имя>), об этом пишется строка в отчёт.

set -uo pipefail
. "$(dirname "$0")/lib.sh"

N_KEEP=${N_KEEP:-3}            # сколько наших снапшотов держим на сервис
LOCK=${LOCK:-$STATE_DIR/.lock} # тот же замок, что у reconcile.sh: одновременных прогонов нет
METRICS=${METRICS:-/var/lib/node_exporter/textfile_collector/lxc.prom}
DUP_TIMEOUT=${DUP_TIMEOUT:-1800}
MARKER_WAIT=${MARKER_WAIT:-180}   # сколько ждём обновления маркера загрузки после перезапуска
PENDING=/var/lib/lxc-update.pending      # внутри инстанса
OKDIR="$STATE_DIR/update-ok"             # время последнего успешного обновления по сервису
RBDIR="$STATE_DIR/rollback-total"        # счётчик откатов по сервису
N_DEL=0

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; }

MODE=update; ONE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --gc-only) MODE=gc ;;
        --one)     shift; ONE=${1:-}; [ -n "$ONE" ] || { echo "--one требует имя сервиса" >&2; exit 2; } ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
    esac
    shift
done

mkdir -p "$STATE_DIR" "$OKDIR" "$RBDIR" 2>/dev/null || true

# Замок: обновление и применение деклараций меняют одни и те же инстансы, поэтому идут
# по очереди. Ждём до 5 минут, потом отказываемся (лучше пропустить ночь, чем столкнуться).
exec 9>"$LOCK" || { log "ОШИБКА: не могу открыть замок $LOCK"; exit 1; }
if ! flock -w 300 9; then
    log "ОШИБКА: $LOCK занят — идёт другой прогон контура, в этот раз пропускаю"
    exit 1
fi

log "=== update: режим $MODE${ONE:+, сервис $ONE}"
check_off_flag

# --- вспомогательное ---------------------------------------------------------

# Серия успешных проб внутри инстанса (её пишет lxc-healthcheck).
svc_streak() { incus-loc exec "$1" -- cat /var/lib/lxc-health.streak 2>/dev/null | tr -dc '0-9'; }

# Проба сервиса: тот же запускатель, что у reconcile.sh (повторы на стороне хоста).
probe() { # инстанс, команда пробы
    local inst="$1" hc="$2"
    [ -n "$hc" ] || return 0
    incus-loc exec "$inst" -- /usr/local/sbin/lxc-healthcheck --command "$hc" --tries 60 --delay 2 >/dev/null 2>&1
}

# Ждём, чтобы маркер загрузки был СВЕЖИМ (mtime ≥ эталона) — доказательство, что инстанс
# действительно перезагрузился, а не «просто RUNNING».
wait_marker() { # инстанс, маркер, эталон (epoch), лимит секунд
    local inst="$1" marker="$2" ref="$3" limit="${4:-180}" i m
    [ -n "$marker" ] || return 0
    for i in $(seq 1 $(( limit / 2 ))); do
        m=$(incus-loc exec "$inst" -- stat -c %Y "$marker" 2>/dev/null | tr -dc '0-9')
        if [ -n "$m" ] && [ "$m" -ge "$ref" ]; then return 0; fi
        sleep 2
    done
    return 1
}

# Наши снапшоты инстанса (только свои префиксы), по возрастанию метки в имени.
instance_snaps() { incus-loc snapshot list "$1" --format csv 2>/dev/null | awk -F, '$1 ~ /^(pre|update)-/{print $1}' | sort; }

# Наши снапшоты датасета, по возрастанию возраста (свежие — в хвосте).
dataset_snaps() { zfs list -H -t snapshot -o name "$1" 2>/dev/null | grep -E "@(pre|update|recreate|removed)-" | sort; }

# --- откат -------------------------------------------------------------------

rollback_one() { # имя, датасет, маркер, проба, метка снапшота (пусто = взять свежайший)
    local name="$1" ds="$2" marker="$3" hc="$4" stamp="${5:-}" out ref
    log "$name: ОТКАТ к последнему известному хорошему состоянию"
    if [ "$DRY_RUN" = 1 ]; then
        log "сделал бы: stop → incus snapshot restore ${stamp:-<свежайший pre-*>} → zfs rollback → start → проба"
        return 0
    fi
    if [ -z "$stamp" ]; then
        stamp=$(incus-loc snapshot list "$name" --format csv 2>/dev/null | awk -F, '$1 ~ /^pre-/{print $1}' | sort | tail -1)
        if [ -n "$stamp" ]; then
            log "$name: метки у флага нет — беру свежайший снапшот инстанса $stamp"
        else
            log "$name: ВНИМАНИЕ: снапшотов инстанса нет — откатывать нечем, поднимаю как есть"
        fi
    fi
    ref=$(date +%s)
    incus-loc stop "$name" >/dev/null 2>&1
    if [ -n "$stamp" ]; then
        if ! out=$(incus-loc snapshot restore "$name" "$stamp" 2>&1); then
            log "$name: ОШИБКА restore $stamp: $(printf '%s' "$out" | tail -1)"
        fi
        # Успешный restore ПОТРЕБЛЯЕТ снапшот инстанса — это его штатное поведение.
    fi
    if [ -n "$ds" ] && zfs list -H -t snapshot -o name "$ds" 2>/dev/null | grep -qx "${ds}@${stamp}"; then
        if ! zfs rollback -r "${ds}@${stamp}" 2>/dev/null; then
            log "$name: ОШИБКА zfs rollback ${ds}@${stamp} — данные остались от неудачного обновления"
        else
            log "$name: данные откатаны к ${ds}@${stamp}"
        fi
    fi
    incus-loc start "$name" >/dev/null 2>&1
    if wait_marker "$name" "$marker" "$ref" "$MARKER_WAIT" && probe "$name" "$hc"; then
        incus-loc exec "$name" -- rm -f "$PENDING" >/dev/null 2>&1 || true
        rbn=$(( $(cat "$RBDIR/$name" 2>/dev/null || echo 0) + 1 )); printf '%s\n' "$rbn" > "$RBDIR/$name" 2>/dev/null || true
        log "$name: откат успешен — сервис работает на прежнем состоянии (снапшот ${stamp:-—})"
        record "$name" "update" "провал" "обновление не прошло, откат выполнен (${stamp:-без снапшота})"
    else
        log "$name: ОШИБКА ОТКАТА: сервис не поднялся на прежнем состоянии — нужен человек"
        log "$name: флаг $PENDING оставлен внутри, чтобы следующий прогон снова пошёл в откат"
        record "$name" "update" "провал" "ОТКАТ НЕ ПОМОГ — нужен человек (флаг оставлен)"
        FAIL=1
    fi
    return 0
}

# --- обновление одного сервиса ----------------------------------------------

update_one() { # имя, файл декларации
    local name="$1" f="$2" ds hc marker policy ts ref rc out state
    policy=$(declared "$f" user.update_policy)
    ds=$(declared "$f" user.data_dataset)
    hc=$(declared "$f" user.healthcheck)
    marker=$(declared "$f" user.boot_marker)

    if [ "$policy" != "inplace" ]; then
        log "$name: политика '${policy:-не задана}' — ночной контур обновляет только inplace"
        record "$name" "update" "пропуск" "политика ${policy:-не задана}: обновляется пересозданием"
        return 0
    fi

    ts=$(date +%Y%m%d-%H%M%S)

    # Прошлый прогон умер, не сняв флаг → сервис обновлялся, но проверку не прошёл.
    if incus-loc exec "$name" -- test -f "$PENDING" >/dev/null 2>&1; then
        log "$name: найден флаг незавершённого обновления ($PENDING) — сразу в откат"
        rollback_one "$name" "$ds" "$marker" "$hc" ""
        return 0
    fi

    if [ "$DRY_RUN" = 1 ]; then
        log "сделал бы: incus-loc snapshot create $name pre-$ts; zfs snapshot ${ds:-—}@pre-$ts;"
        log "           флаг внутри → zypper dup → restart → свежий маркер → systemd → проба;"
        log "           провал → snapshot restore + zfs rollback + start + проба"
        return 0
    fi

    ref=$(date +%s)

    if ! out=$(incus-loc snapshot create "$name" "pre-$ts" 2>&1); then
        log "$name: ОШИБКА снапшота инстанса: $(printf '%s' "$out" | tail -1)"
        record "$name" "update" "провал" "снапшот инстанса"; FAIL=1; return 1
    fi
    if [ -n "$ds" ] && zfs list -H -o name "$ds" >/dev/null 2>&1; then
        if ! zfs snapshot "${ds}@pre-$ts"; then
            log "$name: ОШИБКА снапшота данных $ds"
            record "$name" "update" "провал" "снапшот данных"; FAIL=1; return 1
        fi
        log "$name: снапшоты pre-$ts (инстанс + ${ds})"
    else
        log "$name: снапшот инстанса pre-$ts (датасета в декларации нет)"
    fi

    incus-loc exec "$name" -- touch "$PENDING" >/dev/null 2>&1 || true

    out=$(incus-loc exec "$name" -- timeout "$DUP_TIMEOUT" zypper --non-interactive dup 2>&1); rc=$?
    case "$rc" in
        0)               log "$name: zypper dup — ok" ;;
        100|101|102|103) log "$name: zypper dup — информационный код $rc (предложено обновление/перезагрузка), считаю успехом" ;;
        *)               log "$name: zypper dup — ОШИБКА (код $rc): $(printf '%s' "$out" | tail -1)"
                         rollback_one "$name" "$ds" "$marker" "$hc" "pre-$ts"; return 0 ;;
    esac

    incus-loc restart "$name" >/dev/null 2>&1
    if ! wait_marker "$name" "$marker" "$ref" "$MARKER_WAIT"; then
        log "$name: маркер загрузки не обновился за ${MARKER_WAIT}s — считаю обновление неудачным"
        rollback_one "$name" "$ds" "$marker" "$hc" "pre-$ts"; return 0
    fi
    state=$(incus-loc exec "$name" -- systemctl is-system-running 2>/dev/null || true)
    case "$state" in
        running)  log "$name: systemd — running" ;;
        degraded) log "$name: ВНИМАНИЕ: systemd degraded (есть упавшие юниты)" ;;
        *)        log "$name: ВНИМАНИЕ: systemd сообщает '$state'" ;;
    esac
    if ! probe "$name" "$hc"; then
        log "$name: проба сервиса после обновления не прошла"
        rollback_one "$name" "$ds" "$marker" "$hc" "pre-$ts"; return 0
    fi

    incus-loc exec "$name" -- rm -f "$PENDING" >/dev/null 2>&1 || true
    date +%s > "$OKDIR/$name" 2>/dev/null || true
    log "$name: обновление прошло, проба зелёная (снапшоты pre-$ts живут до уборки)"
    record "$name" "update" "ok" "zypper dup и проба прошли; снапшоты pre-$ts"
    return 0
}

# --- уборка ------------------------------------------------------------------

gc_one() { # имя, файл декларации
    local name="$1" f="$2" ds win state streak hc alive=0 i nm age total
    ds=$(declared "$f" user.data_dataset)
    hc=$(declared "$f" user.healthcheck)
    win=$(window_seconds "$(declared "$f" user.rollback_window)")
    state=$(incus-loc list "$name" -c s --format csv 2>/dev/null | head -1)
    streak=$(svc_streak "$name"); streak=${streak:-0}

    # Живость доказываем ЗДЕСЬ и СЕЙЧАС, а не исторической серией проб: серия сбрасывается
    # перезапуском, а перезапуск — ровно то, что делает ночное обновление. Гейт по серии
    # (≥ 3) запирал уборку навсегда: в 02:18 серия после перезапуска маленькая, и ни один
    # снапшот не снимался. Проба идёт трижды с паузами; её успех заодно растит серию внутри
    # инстанса (она осталась в отчёте как справка, но уборку больше не запирает).
    if [ "$state" = "RUNNING" ]; then
        if [ -n "$hc" ]; then
            incus-loc exec "$name" -- /usr/local/sbin/lxc-healthcheck --command "$hc" --tries 3 --delay 2 >/dev/null 2>&1 && alive=1
        else
            alive=1
        fi
    fi
    if [ "$alive" != 1 ]; then
        log "уборка $name: не чищу — живость не доказана (состояние ${state:-?}, проба не прошла; серия проб $streak)"
        record "$name" "gc" "пропуск" "живость не доказана: ${state:-?}, проба не прошла (серия $streak)"
        return 0
    fi
    log "уборка $name: живость доказана пробой (состояние RUNNING, серия проб $streak) — можно чистить"

    # Снапшоты инстанса: держим N_KEEP самых свежих, остальное снимаем по возрасту.
    local -a snaps=()
    while IFS= read -r nm; do [ -n "$nm" ] && snaps+=("$nm"); done < <(instance_snaps "$name")
    total=${#snaps[@]}
    for (( i=0; i<total; i++ )); do
        nm=${snaps[$i]}
        if [ $(( total - i )) -le "$N_KEEP" ]; then
            log "уборка $name: держу свежий снапшот инстанса $nm (входит в N=$N_KEEP)"
            continue
        fi
        age=$(age_of_stamp "$nm") || { log "уборка $name: у $nm нет метки времени — не трогаю"; continue; }
        if [ "$age" -lt "$win" ]; then
            log "уборка $name: держу $nm (возраст ${age}s < окна ${win}s)"
            continue
        fi
        if [ "$DRY_RUN" = 1 ]; then
            log "сделал бы: incus-loc snapshot delete $name $nm (возраст ${age}s)"
            continue
        fi
        if incus-loc snapshot delete "$name" "$nm" >/dev/null 2>&1; then
            log "уборка $name: снят снапшот инстанса $nm (возраст ${age}s)"
            N_DEL=$((N_DEL + 1))
        else
            log "уборка $name: не смог снять снапшот инстанса $nm"; FAIL=1
        fi
    done

    # Снапшоты датасета: то же правило, но свои префиксы и свой счётчик N_KEEP.
    if [ -n "$ds" ] && zfs list -H -o name "$ds" >/dev/null 2>&1; then
        local -a dsnaps=()
        while IFS= read -r nm; do [ -n "$nm" ] && dsnaps+=("$nm"); done < <(dataset_snaps "$ds")
        total=${#dsnaps[@]}
        for (( i=0; i<total; i++ )); do
            nm=${dsnaps[$i]}
            if [ $(( total - i )) -le "$N_KEEP" ]; then
                log "уборка $name: держу свежий снапшот данных $nm"
                continue
            fi
            age=$(age_of_stamp "$nm") || continue
            if [ "$age" -lt "$win" ]; then
                log "уборка $name: держу $nm (возраст ${age}s < окна ${win}s)"
                continue
            fi
            if [ "$DRY_RUN" = 1 ]; then
                log "сделал бы: zfs destroy $nm (возраст ${age}s)"
                continue
            fi
            if zfs destroy "$nm" 2>/dev/null; then
                log "уборка $name: снят снапшот данных $nm (возраст ${age}s)"
                N_DEL=$((N_DEL + 1))
            else
                log "уборка $name: не смог снять $nm"; FAIL=1
            fi
        done
    fi

    # Стоянки прошлых пересозданий: та же живость, что выше, плюс возраст по метке в имени.
    while IFS= read -r nm; do
        [ -n "$nm" ] || continue
        age=$(age_of_stamp "$nm") || continue
        if [ "$age" -lt "$win" ]; then
            log "уборка: стоянку $nm держу (возраст ${age}s < окна ${win}s)"
            continue
        fi
        if [ "$DRY_RUN" = 1 ]; then
            log "сделал бы: incus-loc delete $nm --force (стоянка, возраст ${age}s)"
            continue
        fi
        if incus-loc delete "$nm" --force >/dev/null 2>&1; then
            log "уборка: снята стоянка $nm (возраст ${age}s)"
            N_DEL=$((N_DEL + 1))
        else
            log "уборка: не смог снять стоянку $nm"; FAIL=1
        fi
    done < <(incus-loc list -c n --format csv 2>/dev/null | grep -E "^${name}-pre-[0-9]{8}-[0-9]{6}$" | sort)

    return 0
}

# --- метрики для node_exporter ----------------------------------------------
# Пишем атомарно (файл + mv): коллектор не должен прочитать половину.
metrics_write() {
    local tmp="$METRICS.$$" name f hc streak ok rb state health
    mkdir -p "$(dirname "$METRICS")" 2>/dev/null || true
    {
        for f in "$SUB"/services/*.yaml; do
            [ -e "$f" ] || continue
            name=$(basename "$f" .yaml)
            state=$(incus-loc list "$name" -c s --format csv 2>/dev/null | head -1)
            streak=$(svc_streak "$name"); streak=${streak:-0}
            hc=$(declared "$f" user.healthcheck)
            ok=$(cat "$OKDIR/$name" 2>/dev/null || echo 0)
            rb=$(cat "$RBDIR/$name" 2>/dev/null || echo 0)
            if [ "$state" = "RUNNING" ] && { [ -z "$hc" ] || incus-loc exec "$name" -- /usr/local/sbin/lxc-healthcheck --command "$hc" --tries 1 --delay 1 >/dev/null 2>&1; }; then health=1; else health=0; fi
            printf 'lxc_instance_health{instance="%s"} %s\n' "$name" "$health"
            printf 'lxc_health_streak{instance="%s"} %s\n' "$name" "$streak"
            printf 'lxc_last_update_success_timestamp{instance="%s"} %s\n' "$name" "$ok"
            printf 'lxc_rollback_total{instance="%s"} %s\n' "$name" "$rb"
        done
        printf 'lxc_snapshots_deleted_total %s\n' "$N_DEL"
    } > "$tmp" 2>/dev/null && mv "$tmp" "$METRICS" 2>/dev/null || rm -f "$tmp"
}

# --- прогон ------------------------------------------------------------------

shopt -s nullglob
files=("$SUB"/services/*.yaml)
if [ ${#files[@]} -eq 0 ]; then
    log "деклараций нет (services/*.yaml) — делать нечего"
    exit 0
fi

if [ -n "$ONE" ]; then
    f="$SUB/services/$ONE.yaml"
    if [ ! -e "$f" ]; then log "ОШИБКА: нет декларации $f"; exit 2; fi
    files=("$f")
fi

if [ "$MODE" = "update" ]; then
    for f in "${files[@]}"; do
        name=$(basename "$f" .yaml)
        if ! incus-loc info "$name" >/dev/null 2>&1; then
            log "$name: инстанса нет — обновлять нечего (создаётся декларацией)"
            continue
        fi
        marker=$(incus-loc config get "$name" user.managed-by 2>/dev/null | tr -d '\r')
        if [ "$marker" != "$MANAGED_BY" ]; then
            log "$name: маркера контура нет ('$marker') — не трогаю"
            record "$name" "update" "пропуск" "нет маркера $MANAGED_BY"
            continue
        fi
        update_one "$name" "$f"
    done
fi

if [ "$MODE" = "gc" ] || { [ "$MODE" = "update" ] && [ -z "$ONE" ]; }; then
    for f in "${files[@]}"; do
        name=$(basename "$f" .yaml)
        if ! incus-loc info "$name" >/dev/null 2>&1; then continue; fi
        marker=$(incus-loc config get "$name" user.managed-by 2>/dev/null | tr -d '\r')
        [ "$marker" = "$MANAGED_BY" ] || continue
        gc_one "$name" "$f"
    done
fi

metrics_write
if [ "$FAIL" = 0 ]; then
    log "=== update завершён без ошибок; убрано объектов: $N_DEL"
else
    log "=== update завершён С ОШИБКАМИ — смотри отчёт; убрано объектов: $N_DEL"
fi
log "=== отчёт: $STATE_DIR/status, метрики: $METRICS"
exit "$FAIL"
