#!/bin/bash
# Приведение инстансов Incus на skld00 к декларациям `services/*.yaml`.
#
# Вызывается из `sync-state.sh` (аргументы — старый и новый git-хеш) и вручную.
#
# Что делает:
#   * данные: владельца датасета выставляет в ХОСТОВОЙ номер, соответствующий uid сервиса
#     внутри контейнера (у нас 100000+uid). Число не хардкодится, а считается из живой карты
#     инстанса — см. host_owner ниже;
#   * создаёт инстанс: create → start → ждёт cloud-init (он ставит пакет и включает юнит)
#     → читает ФАКТИЧЕСКИЙ uid сервиса из инстанса → выставляет владельца датасета
#     в хостовой номер (Hostid+uid из карты инстанса) → запускает юнит → health-gate;
#   * данные проверяет на каждом прогоне: если владелец разъехался — возвращает (самопочинка)
#     и перезапускает юнит, который из-за этого мог не подняться;
#   * применяет живьём скалярные ключи `config:` (limits.*, user.*) через `incus config set`;
#   * если менялся СОСТАВ (devices, raw.idmap, cloud-init.user-data) — ПЕРЕСОЗДАЁТ инстанс:
#     снапшот датасета → старый инстанс отставляется в сторону через rename (НЕ удаляется) →
#     create по новой декларации → проба; при провале — вернуть старый инстанс и zfs rollback.
#     Откат опирается на сам инстанс, а не на старую декларацию: она могла устареть
#     (сменилась база, версия пакета уехала), а работавший инстанс — нет.
#   * декларация исчезла из git → инстанс снимается (снапшот данных, данные остаются на
#     диске). Снимается только инстанс с маркером `user.managed-by` — чужие не трогаются.
#   * `reconcile.sh --recreate <имя>` — принудительная пересборка инстанса по текущей декларации.
#
# Почему uid читается, а не объявляется: наши `-loc`-пакеты создают пользователя через
# `sysusers.d` БЕЗ номера, и номер зависит от состояния /etc/passwd в контейнере. Замерено:
# запрошенный в декларации 479 был занят, sysusers выдал 478, и жёсткий чек уронил cloud-init.
# Номер, который выдала система, — единственный, от которого можно считать владельца данных.
#
# Отладочный этап: пока существует /etc/lxc-automation.off, автоматика ничего не меняет,
# а только печатает, что сделала бы. Владелец снимает флаг, когда захочет включить автоматику.
set -uo pipefail

REPO_DIR=${REPO_DIR:-/opt/appdata/git-repo}
SUB="$REPO_DIR/servers/skld00"
BASE_ALIAS=${BASE_ALIAS:-leap16-base}
OFF_FLAG=${OFF_FLAG:-/etc/lxc-automation.off}
STATE_DIR=${STATE_DIR:-/var/lib/lxc-update}
DRY_RUN=${DRY_RUN:-0}
STARTED=$(date +%s)
FAIL=0
DATA_CHANGED=0

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

record() { # имя, действие, результат, подробности
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    printf '%s\t%s\t%s\t%s\t%ss\n' "$1" "$2" "$3" "$4" \
        "$(( $(date +%s) - STARTED ))" >> "$STATE_DIR/status" 2>/dev/null || true
}

# --- карта uid ---------------------------------------------------------------
# Хостовая сторона uid сервиса: Hostid + (uid - Nsid) по записи uid из volatile.idmap.next.
# NOT volatile.idmap.base: там лежит 0 (сторона пространства имён), хостовая база живёт
# именно в volatile.idmap.next как Hostid (проверено на живом Incus: Hostid=100000 при uid 479
# даёт владельца 100479, и сервис внутри пишет в такой датасет без ошибок).
host_owner() {
    local inst="$1" uid="$2" map entry nsid hostid range
    map=$(incus-loc config get "$inst" volatile.idmap.next 2>/dev/null) || return 1
    [ -n "$map" ] || return 1
    while IFS= read -r entry; do
        case "$entry" in *'"Isuid":true'*) ;; *) continue ;; esac
        case "$entry" in *'"Isgid":true'*) continue ;; esac
        nsid=$(printf '%s' "$entry"    | sed -n 's/.*"Nsid":\([0-9-]*\).*/\1/p')
        hostid=$(printf '%s' "$entry"  | sed -n 's/.*"Hostid":\([0-9-]*\).*/\1/p')
        range=$(printf '%s' "$entry"   | sed -n 's/.*"Maprange":\([0-9-]*\).*/\1/p')
        [ -n "$nsid" ] && [ -n "$hostid" ] && [ -n "$range" ] || continue
        if [ "$uid" -ge "$nsid" ] && [ "$uid" -lt "$((nsid + range))" ]; then
            printf '%s\n' "$((hostid + uid - nsid))"
            return 0
        fi
    done < <(printf '%s\n' "$map" | sed 's/},{/\n/g')
    return 1
}

# Имя пользователя сервиса: ключ user.service_user, иначе имя пакета (наши -loc-пакеты
# создают пользователя ровно с именем пакета).
svc_user() {
    local s
    s=$(declared "$1" user.service_user)
    [ -n "$s" ] && printf '%s\n' "$s" || declared "$1" user.package
}

# Фактический uid внутри инстанса (пакет создаёт пользователя при установке).
svc_uid() { incus-loc exec "$1" -- id -u "$2" 2>/dev/null | tr -d '[:space:]' ; }

# Владелец данных на хосте. Идемпотентно: если уже правильно — не трогает.
data_prep() { # инстанс, датасет, uid сервиса
    local inst="$1" ds="$2" uid="$3" hostmp want have
    DATA_CHANGED=0
    [ -n "$ds" ] || return 0
    if ! zfs list -H -o name "$ds" >/dev/null 2>&1; then
        log "ОШИБКА: нет датасета $ds — его создаёт владелец (см. services/README.md)"
        return 1
    fi
    hostmp=$(zfs get -H -o value mountpoint "$ds")
    [ -n "$uid" ] || return 0
    want=$(host_owner "$inst" "$uid") \
        || { log "ОШИБКА: не смог вычислить хостового владельца для uid $uid по карте $inst"; return 1; }
    have=$(stat -c %u "$hostmp" 2>/dev/null || echo "?")
    if [ "$have" = "$want" ]; then
        log "данные: владелец $hostmp = $want (хостовая сторона uid $uid) — ок"
        return 0
    fi
    if [ "$DRY_RUN" = 1 ]; then
        log "сделал бы: chown $want:$want $hostmp (сейчас владелец $have)"
        return 0
    fi
    if chown "$want:$want" "$hostmp"; then
        log "данные: владелец $hostmp: $have -> $want (хостовая сторона uid $uid)"
        DATA_CHANGED=1
        return 0
    fi
    log "ОШИБКА: не смог сменить владельца $hostmp на $want"
    return 1
}

# --- проекции декларации -----------------------------------------------------
# Скалярные ключи блока `config:` (блок-скаляры — cloud-init.user-data, raw.idmap — пропускаем:
# их правка требует recreate, и они попадают в проекцию «состав»).
proj_scalars() {
    # Скалярные ключи config: — те, что контур применяет живьём. Блочные значения (| и >)
    # не скаляры: их пропускаем ГЛУБИНОЙ, а не одной переменной — внутри блока бывает
    # вложенный блок (`content: |` внутри `cloud-init.user-data: |`), и на нём старый
    # вариант сбрасывал пропуск, после чего `runcmd:` из user-data уезжал в скаляры
    # (контур пытался бы `config set vl1 runcmd ""` — Incus такое отвергает).
    awk '
      /^config:[[:space:]]*$/ { c=1; next }
      c && /^[^[:space:]]/     { c=0 }
      !c { next }
      NF == 0 { next }                        # пустая строка блок не закрывает (в YAML она его часть)
      { match($0, /^[[:space:]]*/); ind=RLENGTH }
      { while (top > 0 && ind <= stack[top]) top-- }
      top > 0 { next }
      /^[[:space:]]+[A-Za-z0-9._-]+:/ {
        line=$0; sub(/^[[:space:]]+/, "", line)
        key=line; sub(/:.*/, "", key)
        val=line; sub(/^[^:]*:[[:space:]]*/, "", val)
        sub(/[[:space:]]+#.*$/, "", val)      # хвостовой YAML-комментарий не часть значения
        if (val ~ /^[|>]/) { stack[++top]=ind; next }
        gsub(/"/, "", val); print key "=" val
      }' "$1"
}
proj_rest() {
    # Всё остальное в config: — состав (devices, блочные значения, raw.idmap). Блочные
    # значения целиком входят в состав: правка user-data = правка состава → recreate.
    awk '
      /^config:[[:space:]]*$/ { c=1; print; next }
      c && /^[^[:space:]]/     { c=0 }
      !c { print; next }
      NF == 0 { if (top > 0) print; next }    # пустая строка блок не закрывает, но входит в состав
      { match($0, /^[[:space:]]*/); ind=RLENGTH }
      { while (top > 0 && ind <= stack[top]) top-- }
      top > 0 { print; next }
      /^[[:space:]]+[A-Za-z0-9._-]+:/ {
        rest=$0; sub(/^[[:space:]]+/, "", rest)
        val=rest; sub(/^[^:]*:[[:space:]]*/, "", val)
        if (val ~ /^[|>]/) { stack[++top]=ind }
        next
      }
      { print }' "$1"
}

declared() { proj_scalars "$1" | awk -F= -v k="$2" '$1 == k { print substr($0, length(k) + 2); exit }'; }
hash16() { sha256sum | cut -c1-16; }

# --- проба живости -----------------------------------------------------------
health_gate() { # инстанс, маркер загрузки, команда пробы
    local inst="$1" marker="$2" hc="$3" i state
    if [ -n "$marker" ]; then
        for i in $(seq 1 60); do
            if incus-loc exec "$inst" -- test -f "$marker" >/dev/null 2>&1; then
                log "загрузка пройдена (маркер $marker на месте)"; break
            fi
            sleep 2
            if [ "$i" = 60 ]; then log "НЕЗДОРОВ: маркер $marker не появился за 120 с"; return 1; fi
        done
    fi
    state=$(incus-loc exec "$inst" -- systemctl is-system-running 2>/dev/null || true)
    case "$state" in
        running)  : ;;
        degraded) log "ВНИМАНИЕ: systemd degraded — есть упавшие юниты" ;;
        *)        log "ВНИМАНИЕ: systemd сообщает '$state'" ;;
    esac
    if [ -n "$hc" ]; then
        if incus-loc exec "$inst" -- /usr/local/sbin/lxc-healthcheck --command "$hc" --tries 60 --delay 2; then
            log "проба сервиса прошла"
        else
            log "НЕЗДОРОВ: проба сервиса не прошла"
            log "--- хвост cloud-init-output.log (последние 15 строк):"
            incus-loc exec "$inst" -- tail -15 /var/log/cloud-init-output.log 2>/dev/null | sed 's/^/    /' || true
            return 1
        fi
    fi
    return 0
}

# --- создание инстанса -------------------------------------------------------
# Полная последовательность: create → start → cloud-init (ставит пакет и включает юнит)
# → чтение ФАКТИЧЕСКОГО uid сервиса → chown датасета в хост-номер → systemctl start юнита → проба.
# Используется и первым созданием, и пересозданием. При провале кладёт причину в LAST_ERROR
# (её пишет в статус вызывающий) и возвращает 1.
LAST_ERROR=""
CREATED_UID=""
RECREATED_UID=""
create_instance() { # имя, файл-декларация, датасет, маркер, проба, юнит, пользователь
    local name="$1" f="$2" ds="$3" marker="$4" hc="$5" unit="$6" user="$7" uid out err
    LAST_ERROR=""
    if ! out=$(incus-loc create "$BASE_ALIAS" "$name" < "$f" 2>&1); then
        err=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -1)
        log "ОШИБКА: create не удался: $err"
        LAST_ERROR="create: $err"
        return 1
    fi
    if ! out=$(incus-loc start "$name" 2>&1); then
        err=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -1)
        log "ОШИБКА: start не удался: $err"
        LAST_ERROR="start: $err"
        log "    причину показывает: incus-loc info --show-log $name"
        return 1
    fi
    incus-loc exec "$name" -- cloud-init status --wait >/dev/null 2>&1 \
        || log "ВНИМАНИЕ: cloud-init завершился с ошибкой — смотри строки ниже"
    uid=$(svc_uid "$name" "$user")
    if [ -z "$uid" ]; then
        log "ОШИБКА: в инстансе нет пользователя $user — значит пакет не установился"
        log "--- хвост cloud-init-output.log:"
        incus-loc exec "$name" -- tail -15 /var/log/cloud-init-output.log 2>/dev/null | sed 's/^/    /' || true
        LAST_ERROR="нет пользователя $user"
        return 1
    fi
    log "uid сервиса в инстансе: $uid"
    if ! data_prep "$name" "$ds" "$uid"; then
        LAST_ERROR="данные: $ds"
        return 1
    fi
    if ! out=$(incus-loc exec "$name" -- systemctl start "$unit" 2>&1); then
        err=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -1)
        log "ВНИМАНИЕ: не удалось запустить $unit: $err (решает проба ниже)"
    fi
    if health_gate "$name" "$marker" "$hc"; then
        CREATED_UID="$uid"
        return 0
    fi
    LAST_ERROR="health-gate"
    return 1
}

# --- пересоздание по изменённой декларации -----------------------------------
# Данные: снапшот датасета. Инстанс: НЕ удаляется, а отставляется в сторону (rename) —
# так откат не зависит ни от git, ни от склада, ни от применимости старой декларации.
recreate_instance() { # имя, файл-декларация, датасет, маркер, проба, юнит, пользователь, старый-хеш
    local name="$1" f="$2" ds="$3" marker="$4" hc="$5" unit="$6" user="$7" old="$8"
    local ts old_name hostmp uid
    ts=$(date +%Y%m%d-%H%M%S)
    old_name="${name}-pre-${ts}"
    LAST_ERROR=""

    if [ -n "$ds" ] && zfs list -H -o name "$ds" >/dev/null 2>&1; then
        hostmp=$(zfs get -H -o value mountpoint "$ds")
        if zfs snapshot "${ds}@recreate-${ts}"; then
            log "данные: снапшот ${ds}@recreate-${ts}"
        else
            log "ОШИБКА: не смог снять снапшот ${ds}@recreate-${ts} — пересоздание отменено"
            LAST_ERROR="снапшот данных"; return 1
        fi
    fi

    if ! out=$(incus-loc stop "$name" 2>&1); then
        log "ОШИБКА: не удалось остановить $name: $(printf '%s' "$out" | tail -1)"
        LAST_ERROR="stop перед пересозданием"; return 1
    fi
    if ! out=$(incus-loc rename "$name" "$old_name" 2>&1); then
        log "ОШИБКА: не удалось отставить инстанс в сторону ($old_name): $(printf '%s' "$out" | tail -1)"
        incus-loc start "$name" >/dev/null 2>&1 || true
        LAST_ERROR="rename перед пересозданием"; return 1
    fi
    log "старый инстанс отставлен как $old_name (вернём при провале, удалит GC)"

    if create_instance "$name" "$f" "$ds" "$marker" "$hc" "$unit" "$user"; then
        log "пересоздание прошло (uid $CREATED_UID); старый $old_name ждёт GC"
        RECREATED_UID="$CREATED_UID"
        return 0
    fi

    # --- откат: снести новый, вернуть старый, откатить данные ---
    log "ПРОВАЛ пересоздания ($LAST_ERROR) — откат к $old_name"
    incus-loc delete "$name" --force >/dev/null 2>&1 || true
    if ! incus-loc rename "$old_name" "$name" >/dev/null 2>&1; then
        log "ОШИБКА ОТКАТА: не удалось вернуть $old_name на место — разбираться руками"
        LAST_ERROR="откат: rename обратно"; return 1
    fi
    if [ -n "$ds" ] && zfs list -H -t snapshot -o name "$ds" 2>/dev/null | grep -qx "${ds}@recreate-${ts}"; then
        if zfs rollback "${ds}@recreate-${ts}"; then
            log "данные откатаны к ${ds}@recreate-${ts}"
        else
            log "ОШИБКА ОТКАТА: zfs rollback ${ds}@recreate-${ts} не удался"
            LAST_ERROR="откат: zfs rollback"; return 1
        fi
    fi
    if incus-loc start "$name" >/dev/null 2>&1 && health_gate "$name" "$marker" "$hc"; then
        log "откат успешен: $name работает на прежнем состоянии"
        LAST_ERROR="откат выполнен (пересоздание провалено)"
        return 1
    fi
    log "ОШИБКА ОТКАТА: $name не поднялся на прежнем состоянии — нужен человек"
    LAST_ERROR="откат не помог — нужен человек"
    return 1
}

# --- снятие инстансов, чьи декларации удалены из git -------------------------
# Правило узла (то же, что у агента на ВМ): декларация исчезла из git → инстанс на узле
# снимается. Отличия от ВМ: снимаем только инстанс с нашим маркером (user.managed-by) —
# у Incus инстансы лежат в одном пространстве имён, и без маркера легко снести чужое;
# и ПЕРЕД снятием делаем снапшот датасета: данные остаются на диске, сам датасет не удаляем.
MANAGED_BY="homelab-deploy/skld00"
remove_orphans() { # старый-хеш, новый-хеш
    local old="${1:-}" new="${2:-}" deleted f name marker ds out
    if [ -n "$RECREATE_ONLY" ]; then
        return 0          # режим --recreate: снятием не занимаемся
    fi
    if [ -z "$old" ] || [ -z "$new" ]; then
        log "снятие: git-хеши не переданы (ручной прогон) — декларации не пересматриваю"
        return 0
    fi
    if ! deleted=$(git -C "$REPO_DIR" diff --name-only --diff-filter=D "$old" "$new" -- servers/skld00/services/ 2>/dev/null); then
        log "снятие: git diff не сработал (нет репозитория?) — пропускаю"
        return 0
    fi
    [ -n "$deleted" ] || return 0
    while IFS= read -r f; do
        case "$f" in servers/skld00/services/*.yaml) ;; *) continue ;; esac
        name=$(basename "$f" .yaml)
        [ "$name" = "README" ] && continue
        if ! incus-loc info "$name" >/dev/null 2>&1; then
            log "снятие: декларация $f удалена, инстанса $name нет — нечего снимать"
            continue
        fi
        marker=$(incus-loc config get "$name" user.managed-by 2>/dev/null | tr -d '\r' || true)
        if [ "$marker" != "$MANAGED_BY" ]; then
            log "снятие: $name есть, но маркера контура нет (user.managed-by='$marker') — НЕ трогаю"
            record "$name" "delete" "пропуск" "нет маркера $MANAGED_BY"
            continue
        fi
        ds=$(incus-loc config get "$name" user.data_dataset 2>/dev/null | tr -d '\r' || true)
        if [ "$DRY_RUN" = 1 ]; then
            log "сделал бы: снапшот ${ds:-—} → stop → delete $name (декларация $f удалена из git; данные остались бы на диске)"
            continue
        fi
        if [ -n "$ds" ] && zfs list -H -o name "$ds" >/dev/null 2>&1; then
            if zfs snapshot "${ds}@removed-$(date +%Y%m%d-%H%M%S)"; then
                log "данные: снапшот ${ds}@removed-… (страховка перед снятием; сам датасет не трогаю)"
            else
                log "ВНИМАНИЕ: снапшот $ds не снялся — снимаю инстанс всё равно, данные остаются на диске"
            fi
        fi
        incus-loc stop "$name" >/dev/null 2>&1 || true
        if out=$(incus-loc delete "$name" 2>&1); then
            log "инстанс $name снят (декларация $f удалена из git); данные остались в ${ds:-—}"
            record "$name" "delete" "ok" "декларация удалена из git: инстанс снят, данные остались в ${ds:-—}"
        else
            log "ОШИБКА: не удалось снять $name: $(printf '%s' "$out" | tail -1)"
            record "$name" "delete" "провал" "$(printf '%s' "$out" | tail -1)"
            FAIL=1
        fi
    done <<< "$deleted"
}

# --- окружение ---------------------------------------------------------------
RECREATE_ONLY=""
if [ "${1:-}" = "--recreate" ]; then
    RECREATE_ONLY="${2:-}"
    [ -n "$RECREATE_ONLY" ] || { echo "использование: reconcile.sh --recreate <имя>" >&2; exit 2; }
    log "=== reconcile: принудительное пересоздание $RECREATE_ONLY"
fi
log "=== reconcile: ${1:-нет} -> ${2:-нет}"
command -v incus-loc >/dev/null 2>&1 || { log "ОШИБКА: нет incus-loc — это не узел Incus"; exit 1; }

if [ -f "$OFF_FLAG" ]; then
    log "АВТОМАТИКА ОТКЛЮЧЕНА ($OFF_FLAG): только отчёт, ничего не меняю"
    DRY_RUN=1
fi
[ "$DRY_RUN" = 1 ] && log "режим: отчёт (dry-run)"

shopt -s nullglob
remove_orphans "${1:-}" "${2:-}"        # декларации, удалённые из git → снять инстансы
files=("$SUB"/services/*.yaml)
if [ ${#files[@]} -eq 0 ]; then
    log "деклараций нет (services/*.yaml) — применять нечего"
    exit 0
fi

mkdir -p "$STATE_DIR/applied" 2>/dev/null || true

for f in "${files[@]}"; do
    name=$(basename "$f" .yaml)
    if [ -n "$RECREATE_ONLY" ] && [ "$name" != "$RECREATE_ONLY" ]; then
        continue          # режим --recreate --name: остальные декларации не трогаем
    fi
    pkg=$(declared "$f" user.package)
    user=$(svc_user "$f")
    unit="${pkg}.service"
    ds=$(declared "$f" user.data_dataset)
    uid=""
    hc=$(declared "$f" user.healthcheck)
    marker=$(declared "$f" user.boot_marker)
    applied="$STATE_DIR/applied/$name"
    h_rest=$(proj_rest "$f" | hash16)
    h_scal=$(proj_scalars "$f" | hash16)
    log "--- $name (пакет $pkg, пользователь $user; декларация: состав $h_rest, скаляры $h_scal)"

    # ---------------------------------------------------------------- создание
    if ! incus-loc info "$name" >/dev/null 2>&1; then
        if [ "$DRY_RUN" = 1 ]; then
            log "сделал бы: create $BASE_ALIAS $name → start → cloud-init → uid → chown $ds → systemctl start $unit → health-gate"
            continue
        fi
        # create, а не launch: карта uid выделяется ПРИ СОЗДАНИИ, и без неё нельзя вычислить
        # хостового владельца данных (а сменить владельца нужно до первого запуска сервиса)
        if create_instance "$name" "$f" "$ds" "$marker" "$hc" "$unit" "$user"; then
            printf '%s %s\n' "$h_rest" "$h_scal" > "$applied"
            record "$name" "create" "ok" "инстанс создан из $BASE_ALIAS, uid $CREATED_UID"
        else
            record "$name" "create" "провал" "$LAST_ERROR"
            log "инстанс $name не поднялся: разбираться (для чистой попытки: incus-loc delete $name --force)"
            FAIL=1
        fi
        continue
    fi

    # ------------------------------------------------------- уже существует
    # данные проверяем на каждом прогоне: владелец мог разъехаться (пересоздание,
    # переезд, смена карты) — это самопочинка, а не разовая настройка.
    # uid читаем у факта; не прочитался (пакет снят) — данные не трогаем, решает проба
    uid=$(svc_uid "$name" "$user")
    if [ -n "$uid" ]; then
        data_prep "$name" "$ds" "$uid" || { record "$name" "apply" "провал" "данные: $ds"; FAIL=1; }
        if [ "$DATA_CHANGED" = 1 ] && [ "$DRY_RUN" = 0 ]; then
            log "владелец данных изменился — перезапускаю $unit (сервис мог не подняться из-за прав)"
            incus-loc exec "$name" -- systemctl try-restart "$unit" >/dev/null 2>&1 \
                || log "ВНИМАНИЕ: не удалось перезапустить $unit"
        fi
    else
        log "ВНИМАНИЕ: в инстансе нет пользователя $user — владельца данных не проверяю"
    fi

    # принудительное пересоздание (`reconcile.sh --recreate <имя>`): хеши не сравниваем,
    # сразу пересобираем — владелец просит пересобрать с нуля на текущей декларации
    if [ -n "$RECREATE_ONLY" ]; then
        log "принудительное пересоздание по запросу владельца"
        if [ "$DRY_RUN" = 1 ]; then
            log "сделал бы: снапшот данных, rename в сторону, пересоздание по текущей декларации"
            continue
        fi
        if recreate_instance "$name" "$f" "$ds" "$marker" "$hc" "$unit" "$user" "${1:-}"; then
            printf '%s %s\n' "$h_rest" "$h_scal" > "$applied"
            record "$name" "recreate" "ok" "пересоздан по запросу (--recreate), uid $RECREATED_UID"
        else
            record "$name" "recreate" "провал" "$LAST_ERROR"
            FAIL=1
        fi
        continue
    fi

    # записи может не быть, если предыдущее создание упало (инстанс остался жить) —
    # тогда «раз инстанс есть, значит всё хорошо» доверять нельзя: проверяем пробой
    if [ ! -f "$applied" ]; then
        log "инстанс есть, записи о применённой декларации нет — проверяю, что он живой"
        if [ "$DRY_RUN" = 1 ]; then
            log "сделал бы: health-gate и запись применённой декларации"
            continue
        fi
        if health_gate "$name" "$marker" "$hc"; then
            printf '%s %s\n' "$h_rest" "$h_scal" > "$applied"
            record "$name" "adopt" "ok" "инстанс существовал без записи, проба прошла"
        else
            record "$name" "adopt" "провал" "инстанс есть, но пробу не прошёл"
            log "инстанс $name остался от неудачного создания и пробу не проходит:"
            log "    разбираться внутри (cloud-init status --long, journalctl -u <юнит>) либо снести: incus-loc delete $name --force"
            FAIL=1
        fi
        continue
    fi
    read -r a_rest a_scal < "$applied"
    if [ "$a_rest" = "$h_rest" ] && [ "$a_scal" = "$h_scal" ]; then
        log "изменений нет"
        continue
    fi
    if [ "$a_rest" != "$h_rest" ]; then
        log "ИЗМЕНИЛСЯ СОСТАВ (devices / raw.idmap / cloud-init.user-data) — пересоздаю инстанс"
        if [ "$DRY_RUN" = 1 ]; then
            log "сделал бы: zfs snapshot $ds@recreate-<дата>; stop + rename $name → $name-pre-<дата>;"
            log "        create по новой декларации → проба; при провале — вернуть $name-pre-<дата> и zfs rollback"
            continue
        fi
        if recreate_instance "$name" "$f" "$ds" "$marker" "$hc" "$unit" "$user" "${1:-}"; then
            printf '%s %s\n' "$h_rest" "$h_scal" > "$applied"
            record "$name" "recreate" "ok" "пересоздан по новой декларации, uid $RECREATED_UID"
        else
            record "$name" "recreate" "провал" "$LAST_ERROR"
            FAIL=1
        fi
        continue
    fi

    # изменились только скаляры — применяем живьём
    changed=0
    while IFS='=' read -r k v; do
        [ -n "$k" ] || continue
        cur=$(incus-loc config get "$name" "$k" 2>/dev/null || true)
        [ "$cur" = "$v" ] && continue
        if [ "$DRY_RUN" = 1 ]; then
            log "сделал бы: incus-loc config set $name $k '$v' (сейчас '$cur')"
        else
            if incus-loc config set "$name" "$k" "$v"; then
                log "применено: $k = $v (было '$cur')"; changed=1
            else
                log "ОШИБКА: не смог применить $k"; FAIL=1
            fi
        fi
    done < <(proj_scalars "$f")
    if [ "$DRY_RUN" = 0 ]; then
        printf '%s %s\n' "$h_rest" "$h_scal" > "$applied"
        record "$name" "apply" "ok" "скалярные ключи применены живьём (изменений: $changed)"
    fi
done

log "=== reconcile завершён"
exit "$FAIL"
