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

# Общие части контура — окружение (REPO_DIR/SUB/STATE_DIR/OFF_FLAG/DRY_RUN), отчёт
# (`log`/`record`), разбор деклараций (`proj_scalars`/`proj_rest`/`declared`), метки времени
# и маппинг uid (`host_owner`/`svc_user`/`svc_uid`) — живут в ./lib.sh: их же использует
# ночной контур update.sh, дублировать не нужно.
. "$(dirname "$0")/lib.sh"

DATA_CHANGED=0

# --- окружение ---------------------------------------------------------------

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
# `proj_scalars` (скаляры config: — применяются живьём) и `proj_rest` (состав: devices и
# блочные значения, правка которых требует пересоздания) живут в ./lib.sh: там же разбор
# ключей (`declared`), хеш (`hash16`) и метка возраста снапшотов. Здесь их нет специально —
# одна реализация на весь контур.

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
MODE="up"                       # up — привести всё объявленное к жизни; down — снять его вручную
# Разбор аргументов: sync-state передаёт два git-хеша (старый и новый) — это обычный проход,
# а не ключ, поэтому «всё, что не начинается с дефиса» принимаем молча.
case "${1:-}" in
    --recreate)
        RECREATE_ONLY="${2:-}"
        [ -n "$RECREATE_ONLY" ] || { echo "использование: reconcile.sh --recreate <имя>" >&2; exit 2; }
        log "=== reconcile: принудительное пересоздание $RECREATE_ONLY"
        ;;
    --up)   MODE="up" ;;
    --down) MODE="down" ;;
    "")     ;;
    -*)     echo "неизвестный ключ: $1" >&2
            echo "использование: reconcile.sh [--up | --down | --recreate <имя>] [<старый-хеш> <новый-хеш>]" >&2
            exit 2 ;;
    *)      ;;                  # <старый-хеш> от sync-state — обычный проход
esac
log "=== reconcile: ${1:-нет} -> ${2:-нет}"
command -v incus-loc >/dev/null 2>&1 || { log "ОШИБКА: нет incus-loc — это не узел Incus"; exit 1; }

if [ -f "$OFF_FLAG" ]; then
    log "АВТОМАТИКА ОТКЛЮЧЕНА ($OFF_FLAG): только отчёт, ничего не меняю"
    DRY_RUN=1
fi
[ "$DRY_RUN" = 1 ] && log "режим: отчёт (dry-run)"

shopt -s nullglob
# --- сети (бриджи) ------------------------------------------------------------
# Сеть — такой же объект контура, как инстанс, и объявляется так же: файлом в `networks/`.
# Порядок принципиален: сети приводятся ДО инстансов. Иначе декларация с устройством на
# несуществующей сети падает внутри пересоздания — уже отставив рабочую стоянку в сторону,
# то есть с простоем и откатом вместо внятной ошибки.
#
# Удаление сетей автоматически НЕ делаем: снос бриджа, к которому подключены живые инстансы,
# роняет их молча. Наша сеть без декларации — только строка в отчёте, снимается руками
# (`incus-loc network delete <имя>`).
NET_MISSING=0

reconcile_networks() { # декларации networks/*.yaml → живое состояние Incus
    local d="$SUB/networks" f name type desc key val cur n
    [ -d "$d" ] || return 0
    for f in "$d"/*.yaml; do
        [ -e "$f" ] || continue
        name=$(basename "$f" .yaml)
        type=$(declared "$f" type); type=${type:-bridge}
        desc=$(declared "$f" description)
        if ! incus-loc network show "$name" >/dev/null 2>&1; then
            local -a args=()
            while IFS= read -r kv; do [ -n "$kv" ] && args+=("$kv"); done < <(proj_scalars "$f")
            args+=("user.managed-by=$MANAGED_BY")
            if [ "$DRY_RUN" = 1 ]; then
                log "сделал бы: incus-loc network create $name --type $type ${desc:+--description '$desc'} ${args[*]}"
                continue
            fi
            if incus-loc network create "$name" --type "$type" ${desc:+--description "$desc"} "${args[@]}" >/dev/null 2>&1; then
                log "сеть: создана $name ($type, объявленных ключей $((${#args[@]} - 1)) + маркер)"
                record "$name" "network" "ok" "сеть создана: $type, ключей $((${#args[@]} - 1))"
            else
                log "ОШИБКА: не смог создать сеть $name"
                record "$name" "network" "провал" "создание сети $name"
                FAIL=1
            fi
            continue
        fi
        # сеть есть: приводим ОБЪЯВЛЕННЫЕ ключи, необъявленные не трогаем (чужие настройки — не наше дело)
        n=0
        while IFS= read -r kv; do
            [ -n "$kv" ] || continue
            key=${kv%%=*}; val=${kv#*=}
            cur=$(incus-loc network get "$name" "$key" 2>/dev/null || true)
            [ "$cur" = "$val" ] && continue
            if [ "$DRY_RUN" = 1 ]; then
                log "сделал бы: incus-loc network set $name $key '$val' (сейчас '$cur')"; n=$((n + 1)); continue
            fi
            if incus-loc network set "$name" "$key" "$val" >/dev/null 2>&1; then
                log "сеть $name: применено $key = $val (было '$cur')"; n=$((n + 1))
            else
                log "ОШИБКА: сеть $name: не смог применить $key"; FAIL=1
            fi
        done < <(proj_scalars "$f")
        cur=$(incus-loc network get "$name" user.managed-by 2>/dev/null || true)
        if [ "$cur" != "$MANAGED_BY" ] && [ "$DRY_RUN" = 0 ]; then
            incus-loc network set "$name" user.managed-by "$MANAGED_BY" >/dev/null 2>&1 \
                && log "сеть $name: поставлен маркер $MANAGED_BY"
        fi
        if [ "$DRY_RUN" = 0 ]; then
            if [ "$n" -gt 0 ]; then
                record "$name" "network" "ok" "ключи сети приведены (изменений: $n)"
            else
                log "сеть $name: изменений нет"
            fi
        fi
    done
    report_orphan_networks
}

report_orphan_networks() { # НАША сеть без декларации в git — только отчёт: удалять нельзя
    local n marker
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        marker=$(incus-loc network get "$n" user.managed-by 2>/dev/null || true)
        [ "$marker" = "$MANAGED_BY" ] || continue
        [ -f "$SUB/networks/$n.yaml" ] && continue
        log "сеть $n: маркер контура есть, декларации в git нет — НЕ удаляю (снять руками: incus-loc network delete $n)"
        record "$n" "network" "пропуск" "декларации нет: сеть не удаляется автоматически"
    done < <(incus-loc network list -c n --format csv 2>/dev/null)
}

net_preconditions() { # сети, на которые ссылаются декларации инстансов, обязаны существовать
    local f nets n bn
    for f in "$SUB"/services/*.yaml; do
        [ -e "$f" ] || continue
        bn=$(basename "$f" .yaml)
        nets=$(proj_rest "$f" | awk '
            /^[[:space:]]*network:[[:space:]]*/ {
                v=$0; sub(/^[[:space:]]*network:[[:space:]]*/, "", v)
                sub(/[[:space:]]+#.*$/, "", v); gsub(/"/, "", v)
                if (v != "") print v
            }')
        for n in $nets; do
            incus-loc network show "$n" >/dev/null 2>&1 && continue
            if [ "$DRY_RUN" = 1 ] && [ -f "$SUB/networks/$n.yaml" ]; then
                log "предпосылка: сети $n пока нет, но она объявлена в networks/ и будет создана при применении"
                continue
            fi
            log "ОШИБКА: $bn.yaml ссылается на сеть $n, которой нет (объяви её: networks/$n.yaml)"
            record "$bn" "precheck" "провал" "нет сети $n — объяви networks/$n.yaml"
            NET_MISSING=1
            FAIL=1
        done
    done
    return 0
}

# --- ручное снятие (--down) ---------------------------------------------------
# Демонстрационный и сервисный режим: снять ВСЁ объявленное — инстансы, наши стоянки и наши
# сети. Сеть уходит последней: пока к бриджу подключены инстансы, его не удалить.
# Данные не трогаются вообще (кроме страховочного снапшота датасета): датасеты остаются на
# месте, и следующее `--up` возвращает всё из деклараций. Трогаем только объекты с нашим
# маркером — чужой инстанс или чужая сеть останутся как есть.
teardown_instance() { # имя, датасет (может быть пустым)
    local n="$1" ds="$2" marker
    incus-loc info "$n" >/dev/null 2>&1 || { log "снятие $n: инстанса нет"; return 0; }
    marker=$(incus-loc config get "$n" user.managed-by 2>/dev/null || true)
    if [ "$marker" != "$MANAGED_BY" ]; then
        log "снятие $n: ПРОПУСК — нет маркера $MANAGED_BY"
        record "$n" "down" "пропуск" "нет маркера контура — не трогаю"
        return 0
    fi
    if [ "$DRY_RUN" = 1 ]; then
        log "сделал бы: incus-loc stop $n; incus-loc delete $n (данные ${ds:-—} остаются)"
        return 0
    fi
    if [ -n "$ds" ] && zfs list -H -o name "$ds" >/dev/null 2>&1; then
        if zfs snapshot "${ds}@removed-$(date +%Y%m%d-%H%M%S)" >/dev/null 2>&1; then
            log "данные: снапшот ${ds}@removed-… (страховка перед снятием; сам датасет не трогаю)"
        else
            log "ВНИМАНИЕ: снапшот $ds не снялся — снимаю инстанс всё равно, данные на диске"
        fi
    fi
    incus-loc stop "$n" >/dev/null 2>&1 || true
    if incus-loc delete "$n" >/dev/null 2>&1; then
        log "снятие: инстанс $n удалён (данные в ${ds:-—} остались)"
        record "$n" "down" "ok" "снят вручную (--down), данные остались в ${ds:-—}"
    else
        log "ОШИБКА: не удалось снять $n"
        record "$n" "down" "провал" "удаление $n вручную"
        FAIL=1
    fi
}

teardown_standbys() { # наши стоянки <имя>-pre-<дата>: их оставляет пересоздание
    local n marker
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        case "$n" in
            *-pre-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) ;;
            *) continue ;;
        esac
        marker=$(incus-loc config get "$n" user.managed-by 2>/dev/null || true)
        [ "$marker" = "$MANAGED_BY" ] || continue
        if [ "$DRY_RUN" = 1 ]; then log "сделал бы: incus-loc delete $n --force (стоянка)"; continue; fi
        if incus-loc delete "$n" --force >/dev/null 2>&1; then
            log "снятие: стоянка $n удалена"
            record "$n" "down" "ok" "стоянка снята вручную (--down)"
        else
            log "ОШИБКА: не смог снять стоянку $n"
            record "$n" "down" "провал" "стоянка $n"
            FAIL=1
        fi
    done < <(incus-loc list -c n --format csv 2>/dev/null)
}

teardown_network() { # имя: только наша сеть (по маркеру)
    local n="$1" marker
    incus-loc network show "$n" >/dev/null 2>&1 || { log "снятие сети $n: её нет"; return 0; }
    marker=$(incus-loc network get "$n" user.managed-by 2>/dev/null || true)
    if [ "$marker" != "$MANAGED_BY" ]; then
        log "снятие сети $n: ПРОПУСК — нет маркера $MANAGED_BY"
        record "$n" "down" "пропуск" "нет маркера контура — сеть не трогаю"
        return 0
    fi
    if [ "$DRY_RUN" = 1 ]; then log "сделал бы: incus-loc network delete $n"; return 0; fi
    if incus-loc network delete "$n" >/dev/null 2>&1; then
        log "снятие: сеть $n удалена"
        record "$n" "down" "ok" "сеть снята вручную (--down)"
    else
        log "ОШИБКА: не смог удалить сеть $n (подключён кто-то ещё?)"
        record "$n" "down" "провал" "удаление сети $n"
        FAIL=1
    fi
}

teardown_all() {
    local f name net
    log "режим --down: снимаю объявленное (инстансы, наши стоянки, наши сети); данные не трогаю"
    for f in "$SUB"/services/*.yaml; do
        [ -e "$f" ] || continue
        name=$(basename "$f" .yaml)
        teardown_instance "$name" "$(declared "$f" user.data_dataset)"
    done
    teardown_standbys
    for f in "$SUB"/networks/*.yaml; do
        [ -e "$f" ] || continue
        net=$(basename "$f" .yaml)
        teardown_network "$net"
    done
}

# --- применение --------------------------------------------------------------
if [ "$MODE" = "down" ]; then
    teardown_all
    log "=== reconcile завершён"
    exit "$FAIL"
fi

reconcile_networks        # сети — ДО инстансов (устройство на несуществующей сети роняет create)
net_preconditions
if [ "$NET_MISSING" = 1 ]; then
    log "инстансы не трогаю: у деклараций нет объявленной сети (см. строки precheck выше)"
    log "=== reconcile завершён"
    exit 1
fi

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
            applied_write "$applied" "$PROJECTION_VERSION" "$h_rest" "$h_scal"
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
            applied_write "$applied" "$PROJECTION_VERSION" "$h_rest" "$h_scal"
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
            applied_write "$applied" "$PROJECTION_VERSION" "$h_rest" "$h_scal"
            record "$name" "adopt" "ok" "инстанс существовал без записи, проба прошла"
        else
            record "$name" "adopt" "провал" "инстанс есть, но пробу не прошёл"
            log "инстанс $name остался от неудачного создания и пробу не проходит:"
            log "    разбираться внутри (cloud-init status --long, journalctl -u <юнит>) либо снести: incus-loc delete $name --force"
            FAIL=1
        fi
        continue
    fi
    # Смена версии определения проекций — это правка самого контура, а не декларации: сохранённые
    # хеши несравнимы, и пересоздавать сервис из-за неё нельзя. Принимаем текущее состояние как
    # применённое (запись в новом формате) и объявляем это в отчёте.
    a_ver=""; a_rest=""; a_scal=""
    read -r a_ver a_rest a_scal < <(applied_read "$applied")
    if [ -n "$a_rest" ] && [ "$a_ver" != "$PROJECTION_VERSION" ]; then
        log "версия определения проекций сменилась (в состоянии '${a_ver:--}', у контура $PROJECTION_VERSION) — хеши пересчитываю, пересоздание не требуется"
        if [ "$DRY_RUN" = 1 ]; then
            log "сделал бы: запись состояния в новом формате ($PROJECTION_VERSION $h_rest $h_scal), без пересоздания"
            continue
        fi
        applied_write "$applied" "$PROJECTION_VERSION" "$h_rest" "$h_scal"
        record "$name" "apply" "пропуск" "версия проекции сменилась (${a_ver:--} → $PROJECTION_VERSION): хеши пересчитаны, пересоздание не требовалось"
        continue
    fi
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
            applied_write "$applied" "$PROJECTION_VERSION" "$h_rest" "$h_scal"
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
        applied_write "$applied" "$PROJECTION_VERSION" "$h_rest" "$h_scal"
        record "$name" "apply" "ok" "скалярные ключи применены живьём (изменений: $changed)"
    fi
done

log "=== reconcile завершён"
exit "$FAIL"
