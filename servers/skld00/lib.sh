#!/bin/bash
# Общие части хостового контура skld00: окружение, отчёт, разбор деклараций, маппинг uid.
#
# Подключается обеими частями контура:
#   * reconcile.sh — применение деклараций (создание, живые скаляры, пересоздание, снятие);
#   * update.sh    — ночное обновление пакетов внутри инстансов и уборка снапшотов/стоянок.
# Сам по себе не исполняется.
#
# Значения ниже берутся из окружения, если заданы (так их подменяют тесты и ручные прогоны),
# иначе — значения узла по умолчанию. Дублировать их в скриптах не нужно.

REPO_DIR=${REPO_DIR:-/opt/appdata/git-repo}
SUB=${SUB:-$REPO_DIR/servers/skld00}
BASE_ALIAS=${BASE_ALIAS:-leap16-base}
OFF_FLAG=${OFF_FLAG:-/etc/lxc-automation.off}
STATE_DIR=${STATE_DIR:-/var/lib/lxc-update}
DRY_RUN=${DRY_RUN:-0}
STARTED=${STARTED:-$(date +%s)}
FAIL=${FAIL:-0}

# Маркер принадлежности: без него контур инстанс не трогает и не снимает (инстансы Incus
# живут в одном пространстве имён, и без маркера легко задеть чужое).
MANAGED_BY=${MANAGED_BY:-homelab-deploy/skld00}

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

record() { # имя, действие, результат, подробности
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    printf '%s\t%s\t%s\t%s\t%ss\n' "$1" "$2" "$3" "$4" \
        "$(( $(date +%s) - STARTED ))" >> "$STATE_DIR/status" 2>/dev/null || true
}

# Проверка выключателя: пока на узле лежит флаг, автоматика ничего не меняет.
# Возвращает 0, если работать нельзя (и выставляет DRY_RUN).
check_off_flag() {
    if [ -f "$OFF_FLAG" ]; then
        log "АВТОМАТИКА ОТКЛЮЧЕНА ($OFF_FLAG): только отчёт, ничего не меняю"
        DRY_RUN=1
    fi
    [ "$DRY_RUN" = 1 ] && log "режим: отчёт (dry-run)"
    return 0
}

hash16() { sha256sum | cut -c1-16; }

# --- версия определения проекций ---------------------------------------------
# Поднимается ВРУЧНУЮ и только тогда, когда меняется само определение проекций — что попадает в
# «состав», а что в скаляры. Файл состояния несёт её первым полем, поэтому смена версии читается
# как «хеши пересчитаны», а не как «состав разошёлся»: контур принимает текущее состояние без
# пересоздания и пишет об этом в отчёт. Без версии правка проекции выглядела бы как правка
# декларации — и молча пересоздавала боевой сервис (так и вышло 14.10, когда комментарии
# исключили из состава).
PROJECTION_VERSION=${PROJECTION_VERSION:-1}

applied_read() { # файл состояния → «версия состав скаляры»; старый формат (два поля) → версия «-»
    # Прочерк, а не пустое поле: `read` съел бы ведущий пробел и сдвинул поля — версией стал бы хеш.
    [ -f "$1" ] || return 1
    awk '{ if (NF >= 3) { print $1, $2, $3 } else if (NF == 2) { print "-", $1, $2 } else { exit 1 } }' "$1"
}

applied_write() { # файл, версия, состав, скаляры
    printf '%s %s %s\n' "$2" "$3" "$4" > "$1"
}

# Сортировка объектов контура по метке времени ВНУТРИ имени, а не по имени целиком. У нас соседствуют
# префиксы pre-/update-/recreate-/removed-, и алфавитный порядок их перемешивает: «pre-<новая дата>»
# встаёт раньше «recreate-<старая дата>». Тогда «N самых свежих» считается неправильно — и уборка
# снимала бы свежий снапшот, оставляя старый. Метка фиксированной ширины, поэтому сортировка по ней и
# есть хронология. Объекты без метки (их не должно быть) уходят в начало как самые старые и не трогаются:
# возраст по ним не считается.
sort_by_stamp() {
    sed -e 's/^\(.*\([0-9]\{8\}-[0-9]\{6\}\).*\)$/\2\t\1/' \
        -e '/\t/!s/^/00000000-000000\t/' | sort | cut -f2-
}

# --- проекции декларации ------------------------------------------------------
# Скалярные ключи config: — те, что применяются живьём (`incus config set`). Блочные
# значения (| и >) не скаляры: их пропускаем ГЛУБИНОЙ, а не одной переменной — внутри
# блока бывает вложенный блок (`content: |` внутри `cloud-init.user-data: |`), и на нём
# пропуск сбрасывался, после чего `runcmd:` из user-data уезжал в скаляры (контур пытался
# бы `config set <имя> runcmd ""` — Incus такое отвергает).
proj_scalars() {
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

# Всё остальное — состав (devices, блочные значения, raw.idmap). Блочные значения входят
# в состав целиком: правка user-data = правка состава → recreate.
# Комментарии, пустые строки и ключ name: в состав НЕ входят: правка комментария — это не
# изменение инстанса, и пересоздавать его из-за неё нельзя (раньше входили → правка
# комментария в victoriametrics1.yaml тянула пересоздание боевого сервиса).
proj_rest() {
    awk '
      /^config:[[:space:]]*$/ { c=1; print; next }
      c && /^[^[:space:]]/     { c=0 }
      !c {
        if ($0 ~ /^[[:space:]]*#/) next   # комментарий
        if ($0 ~ /^[[:space:]]*$/) next   # пустая строка
        if ($0 ~ /^name:/)         next   # имя уже в имени инстанса
        print; next
      }
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
      { if ($0 ~ /^[[:space:]]*#/) next; print }' "$1"
}

declared() { proj_scalars "$1" | awk -F= -v k="$2" '$1 == k { print substr($0, length(k) + 2); exit }'; }

# --- вынесенные файлы декларации (content_file) --------------------------------
# Инлайн `content: |` не всегда удобен: конфиг живёт своей жизнью (например, scrape.yml у
# victoriametrics1). Тогда в write_files пишется ссылка на файл рядом с декларацией:
#     - path: /etc/victoriametrics-loc/scrape.yml
#       content_file: scrape.yml
# Разворот делается ДО проекций и ДО `incus create`, а не в момент установки: иначе правка
# вынесенного файла не меняла бы «состав», инстанс не пересоздавался бы, и конфиг на
# площадке молча расходился бы с гитом (сходимость на декларации, а не на вере).
# Декларация без content_file возвращается как есть, байт в байт: у неё хеши не меняются.
decl_file() { # путь декларации → путь к развёрнутому файлу (или к самой декларации)
    local f="$1" dir out errf rc
    grep -q '^[[:space:]]*content_file:' "$f" 2>/dev/null || { printf '%s\n' "$f"; return 0; }
    dir=$(dirname "$f")
    out=$(mktemp "${TMPDIR:-/tmp}/decl.XXXXXX") || return 1
    errf="$out.err"
    awk -v dir="$dir" '
      match($0, /^[[:space:]]*content_file:[[:space:]]*/) {
        p=$0; sub(/^[[:space:]]*content_file:[[:space:]]*/, "", p); sub(/[[:space:]]+#.*$/, "", p)
        ind=substr($0, 1, index($0, "content_file") - 1)
        file=dir "/" p
        if ((getline probe < file) < 0) { printf "нет файла %s\n", file > "/dev/stderr"; exit 3 }
        close(file)
        print ind "content: |"
        while ((getline line < file) > 0) {
            if (line == "") print ""; else print ind "  " line    # пустые строки — без хвостовых пробелов
        }
        close(file)
        next
      }
      { print }' "$f" > "$out" 2> "$errf"
    rc=$?
    if [ "$rc" != 0 ]; then
        log "ОШИБКА: не развернул content_file в $f: $(head -1 "$errf")"
        rm -f "$out" "$errf"
        return 1
    fi
    rm -f "$errf"
    printf '%s\n' "$out"
}

# --- карта uid ----------------------------------------------------------------
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

# Возраст по метке в имени: наши снапшоты и стоянки несут <YYYYmmdd-HHMMSS> в имени,
# поэтому возраст считается по имени, без обращения к API и без python.
# Принимает строку с меткой; печатает возраст в секундах или пусто, если метки нет.
age_of_stamp() {
    local s="$1" st
    st=$(printf '%s' "$s" | sed -n 's/.*\([0-9]\{8\}-[0-9]\{6\}\).*/\1/p')
    [ -n "$st" ] || return 1
    local then_epoch now_epoch
    then_epoch=$(date -d "${st:0:4}-${st:4:2}-${st:6:2} ${st:9:2}:${st:11:2}:${st:13:2}" +%s 2>/dev/null) || return 1
    now_epoch=$(date +%s)
    printf '%s\n' "$(( now_epoch - then_epoch ))"
}

# Окно отката из декларации (`24h`, `7d`, просто секунды) → секунды. По умолчанию 24h.
window_seconds() {
    local w="$1"
    case "$w" in
        "")      printf '86400\n' ;;
        *h)      printf '%s\n' "$(( ${w%h} * 3600 ))" ;;
        *d)      printf '%s\n' "$(( ${w%d} * 86400 ))" ;;
        *m)      printf '%s\n' "$(( ${w%m} * 60 ))" ;;
        *s)      printf '%s\n' "${w%s}" ;;
        *[0-9])  printf '%s\n' "$w" ;;
        *)       printf '86400\n' ;;
    esac
}
