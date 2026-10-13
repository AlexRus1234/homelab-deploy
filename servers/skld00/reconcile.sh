#!/bin/bash
# Приведение инстансов Incus на skld00 к декларациям `services/*.yaml`.
#
# Вызывается из `sync-state.sh` (аргументы — старый и новый git-хеш) и вручную.
#
# Что делает сейчас:
#   * создаёт отсутствующий инстанс по декларации и проверяет результат
#     (маркер загрузки → состояние systemd → проба сервиса из user.healthcheck);
#   * применяет живьём скалярные ключи `config:` (limits.*, user.*) через `incus config set`;
#   * если менялся СОСТАВ (devices, raw.idmap, cloud-init.user-data) — ничего не трогает
#     и сообщает, что нужен recreate (путь recreate со снапшотом тома — следующий шаг).
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

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

record() { # имя, действие, результат, подробности
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    printf '%s\t%s\t%s\t%s\t%ss\n' "$1" "$2" "$3" "$4" \
        "$(( $(date +%s) - STARTED ))" >> "$STATE_DIR/status" 2>/dev/null || true
}

# --- проекции декларации -----------------------------------------------------
# Скалярные ключи блока `config:` (блок-скаляры — cloud-init.user-data, raw.idmap — пропускаем:
# их правка требует recreate, и они попадают в проекцию «состав»).
proj_scalars() {
    awk '
      /^config:[[:space:]]*$/ { c=1; next }
      c && /^[^[:space:]]/     { c=0 }
      c {
        match($0, /^[[:space:]]+/); ind=RLENGTH
        if (skip && ind <= skipind) skip=0
        if (skip) next
        if ($0 ~ /^[[:space:]]+[A-Za-z0-9._-]+:/) {
          line=$0; sub(/^[[:space:]]+/, "", line)
          key=line; sub(/:.*/, "", key)
          val=line; sub(/^[^:]*:[[:space:]]*/, "", val)
          sub(/[[:space:]]+#.*$/, "", val)      # хвостовой YAML-комментарий не часть значения
          if (val ~ /^[|>]/) { skip=1; skipind=ind; next }
          gsub(/"/, "", val); print key "=" val
        }
      }' "$1"
}

# Всё остальное: состав (devices, профиль, блок-скаляры с их содержимым).
proj_rest() {
    awk '
      /^config:[[:space:]]*$/ { c=1; print; next }
      c && /^[^[:space:]]/     { c=0 }
      c {
        match($0, /^[[:space:]]+/); ind=RLENGTH
        if (skip && ind <= skipind) skip=0
        if (skip) { print; next }
        if ($0 ~ /^[[:space:]]+[A-Za-z0-9._-]+:/) {
          line=$0; sub(/^[[:space:]]+/, "", line)
          val=line; sub(/^[^:]*:[[:space:]]*/, "", val)
          if (val ~ /^[|>]/) { skip=1; skipind=ind }
          next
        }
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
            log "НЕЗДОРОВ: проба сервиса не прошла"; return 1
        fi
    fi
    return 0
}

# --- окружение ---------------------------------------------------------------
log "=== reconcile: ${1:-нет} -> ${2:-нет}"
command -v incus-loc >/dev/null 2>&1 || { log "ОШИБКА: нет incus-loc — это не узел Incus"; exit 1; }

if [ -f "$OFF_FLAG" ]; then
    log "АВТОМАТИКА ОТКЛЮЧЕНА ($OFF_FLAG): только отчёт, ничего не меняю"
    DRY_RUN=1
fi
[ "$DRY_RUN" = 1 ] && log "режим: отчёт (dry-run)"

shopt -s nullglob
files=("$SUB"/services/*.yaml)
if [ ${#files[@]} -eq 0 ]; then
    log "деклараций нет (services/*.yaml) — делать нечего"
    exit 0
fi

mkdir -p "$STATE_DIR/applied" 2>/dev/null || true

for f in "${files[@]}"; do
    name=$(basename "$f" .yaml)
    ds=$(declared "$f" user.data_dataset)
    uid=$(declared "$f" user.service_uid)
    hc=$(declared "$f" user.healthcheck)
    marker=$(declared "$f" user.boot_marker)
    applied="$STATE_DIR/applied/$name"
    h_rest=$(proj_rest "$f" | hash16)
    h_scal=$(proj_scalars "$f" | hash16)
    log "--- $name (декларация: состав $h_rest, скаляры $h_scal)"

    # 1. данные: датасет существует и принадлежит uid сервиса
    if [ -n "$ds" ]; then
        if ! zfs list -H -o name "$ds" >/dev/null 2>&1; then
            log "ОШИБКА: нет датасета $ds — его создаёт владелец (см. services/README.md)"
            record "$name" "create" "провал" "нет датасета $ds"; FAIL=1; continue
        fi
        hostmp=$(zfs get -H -o value mountpoint "$ds")
        have=$(stat -c %u "$hostmp" 2>/dev/null || echo "?")
        if [ -n "$uid" ] && [ "$have" != "$uid" ]; then
            if [ "$DRY_RUN" = 1 ]; then
                log "сделал бы: chown $uid:$uid $hostmp (сейчас владелец $have)"
            else
                if chown "$uid:$uid" "$hostmp"; then
                    log "владелец $hostmp: $have -> $uid"
                else
                    log "ОШИБКА: не смог сменить владельца $hostmp"
                    record "$name" "create" "провал" "chown $hostmp"; FAIL=1; continue
                fi
            fi
        fi
    fi

    # 2. создание отсутствующего инстанса
    if ! incus-loc info "$name" >/dev/null 2>&1; then
        if [ "$DRY_RUN" = 1 ]; then
            log "сделал бы: incus-loc launch $BASE_ALIAS $name < $f"
            log "        затем: cloud-init status --wait и health-gate"
            continue
        fi
        log "инстанса нет — создаю из $BASE_ALIAS"
        if ! incus-loc launch "$BASE_ALIAS" "$name" < "$f"; then
            log "ОШИБКА: launch не удался"
            record "$name" "create" "провал" "launch"; FAIL=1; continue
        fi
        incus-loc exec "$name" -- cloud-init status --wait >/dev/null 2>&1 \
            || log "ВНИМАНИЕ: cloud-init завершился с ошибкой (решает проба сервиса)"
        if health_gate "$name" "$marker" "$hc"; then
            printf '%s %s\n' "$h_rest" "$h_scal" > "$applied"
            record "$name" "create" "ok" "инстанс создан из $BASE_ALIAS"
        else
            record "$name" "create" "провал" "health-gate"
            log "инстанс $name создан, но проверку не прошёл: разбираться (delete --force и прогон заново)"
            FAIL=1
        fi
        continue
    fi

    # 3. существующий инстанс: сравнение с последней применённой декларацией
    if [ ! -f "$applied" ]; then
        log "инстанс есть, записи о применённой декларации нет — считаю текущую применённой"
        [ "$DRY_RUN" = 1 ] || printf '%s %s\n' "$h_rest" "$h_scal" > "$applied"
        continue
    fi
    read -r a_rest a_scal < "$applied"
    if [ "$a_rest" = "$h_rest" ] && [ "$a_scal" = "$h_scal" ]; then
        log "изменений нет"
        continue
    fi
    if [ "$a_rest" != "$h_rest" ]; then
        log "ИЗМЕНИЛСЯ СОСТАВ (devices / raw.idmap / cloud-init.user-data) — нужен recreate;"
        log "сейчас не трогаю: путь recreate (снапшот тома -> пересоздание -> откат) — следующий шаг"
        record "$name" "apply" "нужен recreate" "изменился состав"
        continue
    fi

    # 4. изменились только скаляры — применяем живьём
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
