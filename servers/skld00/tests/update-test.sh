#!/bin/bash
# Харнесс ночного контура (update.sh): обновление с откатом и уборка снапшотов/стоянок.
#
# Ничего не мутирует по-настоящему: incus-loc и zfs подменяются заглушками, состояние — в файлах
# временного каталога. Запускать на любой машине с bash (узел не нужен):
#
#   bash servers/skld00/tests/update-test.sh
#
# Секции: A пробный прогон · B успешное обновление · C1 провал dup · C2 провал пробы ·
# C3 перезапуска не было · D флаг прошлого прогона · E уборка (N=3, окно, смешанные префиксы,
# лежащий и нездоровый) · F выключатель автоматики.
set +e
HERE=$(cd "$(dirname "$0")" && pwd)          # servers/skld00/tests
SRC=$(cd "$HERE/.." && pwd)                  # servers/skld00

W=$(mktemp -d)
BIN="$W/bin"; mkdir -p "$BIN"
REPO="$W/repo"; mkdir -p "$REPO/servers/skld00/services"
S="$W/state"; mkdir -p "$S"
export W S

cp "$SRC/lib.sh" "$REPO/servers/skld00/lib.sh"
cat "$SRC/lib.sh" "$SRC/update.sh" > "$REPO/servers/skld00/update.sh"
U="$REPO/servers/skld00/update.sh"

# --- декларации-фикстуры -----------------------------------------------------
mk_decl() { # имя, датасет (пусто — без данных)
    local n="$1" ds="$2"
    {
        echo "name: $n"
        echo "config:"
        echo "  user.managed-by: homelab-deploy/skld00"
        echo "  user.package: victorialogs-loc"
        echo "  user.update_policy: inplace"
        echo "  user.rollback_window: 24h"
        echo "  user.boot_marker: /run/lxc-boot-ok"
        echo "  user.healthcheck: \"true\""
        [ -n "$ds" ] && echo "  user.data_dataset: $ds"
    } > "$REPO/servers/skld00/services/$n.yaml"
}
mk_decl upd ""
mk_decl good tank/g-data
mk_decl sick tank/s-data
mk_decl halt ""

# --- заглушки -----------------------------------------------------------------
cat > "$BIN/incus-loc" <<'EOF'
#!/bin/bash
echo "INCUS: $*" >> "$W/log"
case "$1" in
  info) [ -f "$S/exists-$2" ] && exit 0 || exit 1 ;;
  list)
    if [ "$2" = "-c" ]; then   # без имени — перечисляем имена (скан стоянок)
      for f in "$S"/exists-* "$S"/parked-*; do [ -e "$f" ] && basename "$f" | sed -e 's/^exists-//' -e 's/^parked-//'; done
      exit 0
    fi
    cat "$S/state-$2" 2>/dev/null || echo STOPPED; exit 0 ;;
  config) if [ "$2" = get ] && [ "$4" = user.managed-by ]; then cat "$S/marker-$3" 2>/dev/null; fi; exit 0 ;;
  exec)
    inst=$2; shift 3
    case "$1" in
      test) [ -f "$S/pending-$inst" ] && exit 0 || exit 1 ;;
      touch) touch "$S/pending-$inst" ;;
      rm) rm -f "$S/pending-$inst" ;;
      stat) if [ -n "${STALE_MARKER:-}" ]; then echo $(( $(date +%s) - 100000 )); else date +%s; fi ;;
      id) echo 478 ;;
      cat) case "$2" in *streak) cat "$S/streak-$inst" 2>/dev/null || echo 0 ;; esac ;;
      timeout|zypper) exit "${DUP_RC:-0}" ;;
      systemctl) echo running ;;
      */lxc-healthcheck) [ "$inst" = sick ] && exit 1
                         n=$(cat "$S/probe-n" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$S/probe-n"
                         [ "$n" -le "${PROBE_FAILS:-0}" ] && exit 1 || exit 0 ;;
    esac
    exit 0 ;;
  snapshot)
    sub=$2; inst=$3; snap=$4
    case "$sub" in
      create) echo "$snap" >> "$S/snaps-$inst" ;;
      list) [ -f "$S/snaps-$inst" ] && awk '{print $1",2026-10-14 00:00:00"}' "$S/snaps-$inst" ;;
      delete|restore) grep -vx "$snap" "$S/snaps-$inst" > "$S/.t" 2>/dev/null && mv "$S/.t" "$S/snaps-$inst" ;;
    esac
    exit 0 ;;
  delete) rm -f "$S/exists-$2" "$S/parked-$2"; exit 0 ;;
esac
exit 0
EOF
cat > "$BIN/zfs" <<'EOF'
#!/bin/bash
echo "ZFS: $*" >> "$W/log"
last=""; for a in "$@"; do case "$a" in -*) ;; *) last=$a ;; esac; done
ds="${last%%@*}"
zf="$S/zsnaps-$(printf '%s' "$ds" | tr '/' '_')"
case "$1" in
  list)
    case "$*" in *"-t snapshot"*) cat "$zf" 2>/dev/null ;; *) echo "$last" ;; esac
    exit 0 ;;
  get) echo "$W/ds"; exit 0 ;;
  snapshot) echo "$2" >> "$zf"; exit 0 ;;
  rollback) exit 0 ;;
  destroy) grep -vx "$2" "$zf" > "$S/.tz" 2>/dev/null && mv "$S/.tz" "$zf" 2>/dev/null; exit 0 ;;
esac
exit 0
EOF
chmod +x "$BIN/incus-loc" "$BIN/zfs"
export PATH="$BIN:$PATH"
export REPO_DIR="$REPO" STATE_DIR="$S/state" OFF_FLAG="$W/off.flag" METRICS="$S/lxc.prom"

for n in upd good sick halt; do touch "$S/exists-$n"; echo homelab-deploy/skld00 > "$S/marker-$n"; done
touch "$S/parked-good-pre-20261001-010101" "$S/parked-good-pre-20261013-150000"   # стоянки: старая и свежая
echo 5 > "$S/streak-good"; echo 1 > "$S/streak-sick"; echo 0 > "$S/streak-upd"; echo 9 > "$S/streak-halt"
echo RUNNING > "$S/state-good"; echo RUNNING > "$S/state-sick"; echo RUNNING > "$S/state-upd"; echo STOPPED > "$S/state-halt"

say()   { printf '\n=== %s\n' "$*"; }
stage() { rm -f "$W/log"; echo 0 > "$S/probe-n"; }
mut()   { grep -cE "INCUS: (snapshot create|snapshot delete|snapshot restore|restart|stop|start|delete [a-z])|ZFS: (snapshot|rollback|destroy)" "$W/log" 2>/dev/null || echo 0; }

say "A. пробный прогон (--dry-run): только план, ни одной мутирующей команды"
stage; mkdir -p "$S/state"
bash "$U" --dry-run 2>&1 | sed 's/^/    /'
echo "--- мутирующих вызовов: $(mut)"

say "B. обновление проходит: снапшот → флаг → dup → restart → свежий маркер → проба"
stage; DUP_RC=0 PROBE_FAILS=0 bash "$U" --one upd 2>&1 | sed 's/^/    /'
echo "--- последовательность вызовов:"; grep -oE "INCUS: (info|snapshot create|exec upd -- timeout|restart|exec upd -- rm|exec upd -- touch)|ZFS: (list|snapshot)" "$W/log" | sed 's/^/    /'
echo "--- последняя строка отчёта:"; tail -1 "$S/state/status" | sed 's/^/    /'
echo "--- флаг внутри инстанса: $([ -f "$S/pending-upd" ] && echo ОСТАЛСЯ || echo снят)"

say "C1. dup упал → откат (stop → restore → rollback → start → проба)"
stage; rm -f "$S/pending-upd"; DUP_RC=1 PROBE_FAILS=0 bash "$U" --one upd 2>&1 | sed 's/^/    /'
echo "--- откатные команды:"; grep -E "INCUS: (stop|snapshot restore|start)|ZFS: rollback" "$W/log" | sed 's/^/    /'
echo "--- последняя строка отчёта:"; tail -1 "$S/state/status" | sed 's/^/    /'

say "C2. dup прошёл, а проба после обновления упала → откат (вторая проба зелёная)"
stage; rm -f "$S/pending-upd"; DUP_RC=0 PROBE_FAILS=1 bash "$U" --one upd 2>&1 | sed 's/^/    /'
echo "--- откатные команды:"; grep -E "INCUS: (stop|snapshot restore|start)|ZFS: rollback" "$W/log" | sed 's/^/    /'
echo "--- последняя строка отчёта:"; tail -1 "$S/state/status" | sed 's/^/    /'

say "C3. маркер загрузки не обновился → откат (перезапуска как будто не было)"
stage; rm -f "$S/pending-upd"; DUP_RC=0 PROBE_FAILS=0 STALE_MARKER=1 MARKER_WAIT=4 bash "$U" --one upd 2>&1 | sed 's/^/    /' | head -8
echo "--- последняя строка отчёта:"; tail -1 "$S/state/status" | sed 's/^/    /'

say "D. флаг прошлого прогона на старте → сразу откат, zypper не вызывается"
stage; rm -f "$S/pending-upd"; touch "$S/pending-upd"; DUP_RC=0 PROBE_FAILS=0 bash "$U" --one upd 2>&1 | sed 's/^/    /'
echo "--- вызовов zypper: $(grep -c timeout "$W/log")"
echo "--- последняя строка отчёта:"; tail -1 "$S/state/status" | sed 's/^/    /'

say "E. уборка: живой чистится (N=3, окно 24h + стоянки), лежащий и нездоровый — нет"
# good: снапшоты с РАЗНЫМИ префиксами (pre-/update-/recreate-) — «свежесть» считается по метке
# внутри имени, а не по имени целиком; sick: проба падает; halt: STOPPED
: > "$S/snaps-good"
for t in update-20261009-010101 pre-20261010-010101 pre-20261011-010101 pre-20261012-010101 pre-20261014-010101; do echo "$t" >> "$S/snaps-good"; done
: > "$S/zsnaps-tank_g-data"
for t in recreate-20261010-010101 pre-20261011-010101 recreate-20261012-010101 pre-20261013-010101 pre-20261014-010101; do echo "tank/g-data@$t" >> "$S/zsnaps-tank_g-data"; done
: > "$S/snaps-sick"; echo "pre-20261010-010101" >> "$S/snaps-sick"
: > "$S/zsnaps-tank_s-data"
for t in 20261010-010101 20261011-010101 20261012-010101 20261013-010101 20261013-150000; do echo "tank/s-data@pre-$t" >> "$S/zsnaps-tank_s-data"; done
: > "$S/snaps-halt"; echo "pre-20261010-010101" >> "$S/snaps-halt"
stage; bash "$U" --gc-only 2>&1 | sed 's/^/    /'
echo "--- осталось у good (инстанс):"; sort "$S/snaps-good" | sed 's/^/    /'
echo "--- осталось у good (данные):"; sort "$S/zsnaps-tank_g-data" | sed 's/^/    /'
echo "--- у sick (проба не проходит, не чистим):"; sort "$S/snaps-sick" | sed 's/^/    /'
echo "--- у halt (STOPPED, не чистим):"; sort "$S/snaps-halt" | sed 's/^/    /'
echo "--- метрики:"; sed 's/^/    /' "$S/lxc.prom"
echo "--- что легло в отчёт по уборке:"; grep "gc" "$S/state/status" | sed 's/^/    /'

say "E2. второй прогон уборки: снимать уже нечего → last_run=0, накопительный не растёт"
stage; bash "$U" --gc-only >/dev/null 2>&1
grep -E "deleted" "$S/lxc.prom" | sed 's/^/    /'
echo "--- отчёт по уборке во втором прогоне:"; grep "gc" "$S/state/status" | tail -4 | sed 's/^/    /'

say "F. выключатель автоматики: только отчёт + строки «пропуск» в отчёте"
stage; touch "$W/off.flag"
bash "$U" 2>&1 | sed 's/^/    /' | head -6
echo "--- мутирующих вызовов: $(mut)"
echo "--- что легло в отчёт:"; grep "автоматика выключена" "$S/state/status" | sed 's/^/    /'

sudo -n rm -rf "$W" 2>/dev/null || rm -rf "$W"
