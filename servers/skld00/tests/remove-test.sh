#!/bin/bash
# Харнесс ветки снятия в reconcile.sh: декларация удалена из git → инстанс снимается (снапшот данных
# перед снятием, датасет остаётся), инстанс без маркера контура — не трогается, при выключенной
# автоматике — только план. Узел не нужен: `incus-loc`, `zfs` и `chown` — заглушки; git — настоящий,
# но во временном каталоге.
#
#   bash servers/skld00/tests/remove-test.sh
#
# Возвращает ненулевой код при первом расхождении (см. harness-lib.sh) — на этом стоит проверка
# перед пушем (.githooks/pre-push).
#
# Секции: 0 подготовка git · A снятие (x1 с маркером снимается, x2 без маркера нет, x3 не задет) ·
# B то же при выключенной автоматике · C декларации на месте → снимать нечего · D отчёт.
set +e
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/.." && pwd)
. "$HERE/harness-lib.sh"

W=$(mktemp -d)
BIN="$W/bin"; mkdir -p "$BIN"
REPO="$W/repo"; mkdir -p "$REPO/servers/skld00/services"
S="$W/state"; mkdir -p "$S/state"
export W S

cp "$SRC/lib.sh" "$SRC/reconcile.sh" "$REPO/servers/skld00/"
R="$REPO/servers/skld00/reconcile.sh"

# --- фикстуры-декларации ------------------------------------------------------
mk_decl() { # имя, маркер (да/нет)
    local n="$1" m="$2"
    {
        echo "name: $n"
        echo "config:"
        [ "$m" = да ] && echo "  user.managed-by: homelab-deploy/skld00"
        echo "  user.package: victorialogs-loc"
        echo "  user.update_policy: inplace"
        echo "  user.data_dataset: tank/$n-data"
        echo "  user.boot_marker: /run/lxc-boot-ok"
        echo "  user.healthcheck: \"true\""
    } > "$REPO/servers/skld00/services/$n.yaml"
}
mk_decl x1 да      # декларация уедет из git → инстанс должен быть снят
mk_decl x2 нет     # декларация тоже уедет, но маркера нет → контур обязан не трогать
mk_decl x3 да      # декларация остаётся на месте → не задевается вовсе

# --- заглушки -----------------------------------------------------------------
cat > "$BIN/incus-loc" <<'EOF'
#!/bin/bash
echo "INCUS: $*" >> "$W/log"
case "$1" in
  info) [ -f "$S/exists-$2" ] && exit 0 || exit 1 ;;
  list) [ "$3" = "-c" ] && echo RUNNING || echo "$2"; exit 0 ;;
  config) if [ "$2" = get ]; then
            case "$4" in
              user.managed-by)  cat "$S/marker-$3" 2>/dev/null ;;
              user.data_dataset) echo "tank/$3-data" ;;
              volatile.idmap.next) echo '[{"Isuid":true,"Isgid":false,"Hostid":100000,"Nsid":0,"Maprange":65536}]' ;;
              *) echo "" ;;
            esac
          fi; exit 0 ;;
  exec) inst=$2; shift 3
        case "$1" in
          id) echo 478 ;;
          test) exit 0 ;;
          systemctl) [ "$2" = is-system-running ] && echo running; exit 0 ;;
          */lxc-healthcheck) exit 0 ;;
          *) exit 0 ;;
        esac ;;
  delete) rm -f "$S/exists-$2"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
cat > "$BIN/zfs" <<'EOF'
#!/bin/bash
echo "ZFS: $*" >> "$W/log"
case "$1" in
  list) echo "${@: -1}" ;;
  get)  echo "${@: -1}" ;;
  *)    exit 0 ;;
esac
exit 0
EOF
cat > "$BIN/chown" <<'EOF'
#!/bin/bash
echo "CHOWN: $*" >> "$W/log"     # заглушка: root в харнессе не нужен
exit 0
EOF
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"
export REPO_DIR="$REPO" STATE_DIR="$S/state" OFF_FLAG="$W/off.flag" DRY_RUN=0

for n in x1 x2 x3; do touch "$S/exists-$n"; done
echo homelab-deploy/skld00 > "$S/marker-x1"      # у x2 маркера нет намеренно
echo homelab-deploy/skld00 > "$S/marker-x3"

say()      { printf '\n=== %s\n' "$*"; }
stage()    { rm -f "$W/log"; }
present()  { [ -e "$S/exists-$1" ] && echo да || echo нет; }   # «есть ли инстанс» для check
removals() { grep -cE 'INCUS: (stop|delete)' "$W/log" 2>/dev/null | tr -d ' '; }

say "0. готовим git: коммит с тремя декларациями → коммит, где x1 (с маркером) и x2 (без маркера) удалены, x3 оставлен"
git -C "$REPO" init -q
git -C "$REPO" -c user.email=t@t -c user.name=t add -A >/dev/null
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m "три декларации"
OLD=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" rm -q "servers/skld00/services/x1.yaml" "servers/skld00/services/x2.yaml"
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m "x1 и x2 удалены"
NEW=$(git -C "$REPO" rev-parse HEAD)
echo "    старая ревизия $(git -C "$REPO" rev-parse --short "$OLD"), новая $(git -C "$REPO" rev-parse --short "$NEW")"
echo "    удалены из git:"; git -C "$REPO" diff --name-only --diff-filter=D "$OLD" "$NEW" | sed 's/^/        /'
check "0: git показывает ровно две удалённые декларации" \
    "servers/skld00/services/x1.yaml servers/skld00/services/x2.yaml" \
    "$(git -C "$REPO" diff --name-only --diff-filter=D "$OLD" "$NEW" | tr '\n' ' ' | sed 's/ *$//')"

say "A. снятие: x1 с маркером снимается; x2 без маркера — НЕ трогается; x3 (декларация на месте) не задет"
stage; bash "$R" "$OLD" "$NEW" > "$W/out" 2>&1
grep -E "снятие|снят|данные|пропуск|ОШИБКА" "$W/out" | sed 's/^/    /'
echo "    --- вызовы контура:"; grep -E "ZFS: snapshot|INCUS: (stop|delete)" "$W/log" | sed 's/^/        /'
echo "    --- инстансы, которые остались:"; for f in "$S"/exists-*; do [ -e "$f" ] && basename "$f" | sed 's/^exists-/        /'; done
check "A: x1 (с маркером) снят"                     "нет" "$(present x1)"
check "A: x2 (без маркера) на месте"                "да"  "$(present x2)"
check "A: x3 (декларация на месте) не задет"        "да"  "$(present x3)"
has    "A: перед снятием снят снапшот данных"       "ZFS: snapshot tank/x1-data@removed-" "$W/log"
has    "A: инстанс x1 удалён"                       "INCUS: delete x1" "$W/log"
nothas "A: x2 не удалялся"                          "INCUS: delete x2" "$W/log"
nothas "A: x3 не удалялся"                          "INCUS: delete x3" "$W/log"
has    "A: причина пропуска x2 — отсутствие маркера" "маркера контура нет" "$W/out"
check  "A: в отчёте x1 — delete ok"     "ok"      "$(status_field x1 delete 3 "$S/state/status")"
check  "A: в отчёте x2 — delete пропуск" "пропуск" "$(status_field x2 delete 3 "$S/state/status")"

say "B. то же при выключенной автоматике: только план, инстансы на месте"
stage; touch "$W/off.flag"
touch "$S/exists-x1"     # возвращаем инстанс x1: раздел проверяет ПЛАН, а не результат раздела A
bash "$R" "$OLD" "$NEW" > "$W/out" 2>&1
grep -E "ОТКЛЮЧЕНА|сделал бы: снапшот|снятие" "$W/out" | sed 's/^/    /'
echo "    --- вызовов снятия: $(removals)"
echo "    --- инстансы:"; for f in "$S"/exists-*; do [ -e "$f" ] && basename "$f" | sed 's/^exists-/        /'; done
check "B: при выключенной автоматике ноль вызовов снятия" "0" "$(removals)"
has   "B: причина видна в выводе" "АВТОМАТИКА ОТКЛЮЧЕНА" "$W/out"
has   "B: план снятия напечатан"  "сделал бы: снапшот tank/x1-data" "$W/out"

say "C. декларации на месте (та же ревизия) → снимать нечего"
rm -f "$W/off.flag"; stage
bash "$R" "$NEW" "$NEW" > "$W/out" 2>&1
grep -E "снятие" "$W/out" | sed 's/^/    /' | head -3
echo "    --- вызовов снятия: $(removals)"
check "C: на той же ревизии ноль вызовов снятия" "0" "$(removals)"

say "D. отчёт (/var/lib/lxc-update/status)"
grep -E "delete" "$S/state/status" 2>/dev/null | sed 's/^/    /'
check "D: в отчёте обе формы — «ok» и «пропуск»" "2" \
    "$(awk -F'\t' '$2 == "delete" { print $3 }' "$S/state/status" | sort -u | wc -l | tr -d ' ')"

summary; rc=$?
sudo -n rm -rf "$W" 2>/dev/null || rm -rf "$W"
exit "$rc"
