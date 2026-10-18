#!/bin/bash
# Харнесс деплой-пути: вынесенные файлы декларации (content_file) и переименование декларации.
#
#   bash servers/skld00/tests/deploy-test.sh
#
# Секции: 1 content_file входит в состав (правка вынесенного файла меняет хеш состава) ·
# 2 декларация без content_file хешируется байт в байт как раньше · 3 пропавший файл —
# громкий провал, а не тихий пропуск · 4 переименование декларации = снять старый + создать новый.
set +e
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/.." && pwd)
. "$HERE/harness-lib.sh"

W=$(mktemp -d)
BIN="$W/bin"; mkdir -p "$BIN"
REPO="$W/repo"
mkdir -p "$REPO/servers/skld00/services"
cp "$SRC/lib.sh" "$SRC/reconcile.sh" "$REPO/servers/skld00/"
cp "$SRC/services/victoriametrics1.yaml" "$REPO/servers/skld00/services/"
cp -a "$SRC/services/victoriametrics1" "$REPO/servers/skld00/services/"
cp "$SRC/services/victorialogs1.yaml" "$REPO/servers/skld00/services/"
export W REPO

say() { printf '\n--- %s\n' "$*"; }

# --- заглушки -----------------------------------------------------------------
cat > "$BIN/incus-loc" <<'EOF'
#!/bin/bash
echo "INCUS: $*" >> "$W/log"
case "$1" in
  info) [ -f "$W/exists-$2" ] && exit 0 || exit 1 ;;
  list) if [ "$3" = "-c" ]; then echo RUNNING; else echo "$2"; fi; exit 0 ;;
  config) [ "$2" = get ] && { case "$4" in
              user.managed-by) echo "homelab-deploy/skld00" ;;
              user.data_dataset) echo "tank/x-data" ;;
              volatile.idmap.next) echo '[{"Isuid":true,"Isgid":false,"Hostid":100000,"Nsid":0,"Maprange":65536}]' ;;
          esac; }; exit 0 ;;
  exec) case "$3 $4" in
          *id*) echo 478 ;;
          *) exit 0 ;;
        esac ;;
  *) exit 0 ;;
esac
EOF
cat > "$BIN/zfs" <<'EOF'
#!/bin/bash
echo "ZFS: $*" >> "$W/log"
case "$2" in -o) echo "${@: -1}" ;; esac
exit 0
EOF
chmod +x "$BIN/incus-loc" "$BIN/zfs"
export PATH="$BIN:$PATH"

comp() { # декларация → хеш состава
    bash -c ". '$SRC/lib.sh'; f=\$(decl_file \"$1\") || exit 1; proj_rest \"\$f\" | hash16"
}

say "1. content_file входит в состав: правка вынесенного файла меняет хеш"
DECL="$REPO/servers/skld00/services/victoriametrics1.yaml"
h1=$(comp "$DECL")
echo "    исходный хеш состава: $h1"
has "в декларации есть ссылка на файл" "content_file: victoriametrics1/scrape.yml" "$DECL"
grep -q '^      - path: /etc/victoriametrics-loc/scrape.yml' "$DECL" \
    && echo "  ok    ссылка стоит на месте (path → content_file)" \
    || { echo "  FAIL  ссылка не найдена"; FAILS=$((FAILS+1)); }
echo "# правка (проверка сходимости)" >> "$REPO/servers/skld00/services/victoriametrics1/scrape.yml"
h2=$(comp "$DECL")
differs "хеш состава изменился после правки файла" "$h1" "$h2"
has "развёрнутый файл содержит новый текст" "# правка (проверка сходимости)" \
    "$(bash -c ". '$SRC/lib.sh'; decl_file '$DECL'")"
nothas "в развёрнутом файле нет content_file" "content_file:" \
    "$(bash -c ". '$SRC/lib.sh'; decl_file '$DECL'")"

say "2. декларация без content_file: хеш тот же, что у файла как есть"
VL="$REPO/servers/skld00/services/victorialogs1.yaml"
hv1=$(comp "$VL")
hv2=$(bash -c ". '$SRC/lib.sh'; proj_rest '$VL' | hash16")
check "путь не подменяется" "$VL" "$(bash -c ". '$SRC/lib.sh'; decl_file '$VL'")"
check "хеш совпадает с прямым подсчётом" "$hv2" "$hv1"

say "3. пропавший вынесенный файл: провал, а не тихий пропуск"
rm -f "$REPO/servers/skld00/services/victoriametrics1/scrape.yml"
if bash -c ". '$SRC/lib.sh'; decl_file '$DECL'" > "$W/decl.out" 2>&1; then
    echo "  FAIL  decl_file вернул успех на пропавшем файле"; FAILS=$((FAILS+1)); CHECKS=$((CHECKS+1))
else
    echo "  ok    decl_file вернул провал"; CHECKS=$((CHECKS+1))
fi
has "сказано, чего не хватило" "не развернул content_file" "$W/decl.out"

say "4. переименование декларации: старый инстанс снимается, новый создаётся"
# настоящий git-репозиторий: переезд должен читаться как delete + add (rename detection выключен)
G="$W/gitrepo"; mkdir -p "$G/servers/skld00/services"
cp "$SRC/lib.sh" "$SRC/reconcile.sh" "$G/servers/skld00/"
cp "$SRC/services/victorialogs1.yaml" "$G/servers/skld00/services/legacy1.yaml"
sed -i 's/^name: .*/name: legacy1/' "$G/servers/skld00/services/legacy1.yaml"
git -C "$G" init -q -b main
git -C "$G" -c user.email=t@t -c user.name=t add -A
git -C "$G" -c user.email=t@t -c user.name=t commit -qm "до переименования"
OLD=$(git -C "$G" rev-parse HEAD)
git -C "$G" mv servers/skld00/services/legacy1.yaml servers/skld00/services/victorialogs1.yaml
sed -i 's/^name: .*/name: victorialogs1/' "$G/servers/skld00/services/victorialogs1.yaml"
git -C "$G" -c user.email=t@t -c user.name=t add -A
git -C "$G" -c user.email=t@t -c user.name=t commit -qm "переименование"
NEW=$(git -C "$G" rev-parse HEAD)
touch "$W/exists-legacy1"                       # старый инстанс жив
S="$W/state5"; mkdir -p "$S/state"
REPO_DIR="$G" SUB="$G/servers/skld00" REPO_DIR_T="x" STATE_DIR="$S/state" \
  OFF_FLAG="$W/off.flag" MANAGED_BY="homelab-deploy/skld00" DRY_RUN=1 BASE_ALIAS="leap16-base" \
  bash "$G/servers/skld00/reconcile.sh" "$OLD" "$NEW" > "$W/run5" 2>&1
echo "    (план: $(grep -c 'сделал бы' "$W/run5") строк)"
has "старый инстанс снимается" "delete legacy1" "$W/run5"
has "новый инстанс создаётся"  "create leap16-base victorialogs1" "$W/run5"
has "снятие объяснено как удаление декларации" "декларация" "$W/run5"

summary
