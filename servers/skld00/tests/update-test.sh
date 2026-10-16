#!/bin/bash
# Харнесс ночного контура (update.sh): обновление с откатом и уборка снапшотов/стоянок.
#
# Ничего не мутирует по-настоящему: incus-loc и zfs подменяются заглушками, состояние — в файлах
# временного каталога. Запускать на любой машине с bash (узел и root не нужны):
#
#   bash servers/skld00/tests/update-test.sh        # подробно, по секциям
#
# Возвращает ненулевой код при первом же расхождении (см. harness-lib.sh) — на этом стоит
# проверка перед пушем (.githooks/pre-push).
#
# Секции: A пробный прогон · B успешное обновление · C1 провал dup · C2 провал пробы ·
# C3 перезапуска не было · D флаг прошлого прогона · E уборка (N=3, окно, смешанные префиксы,
# лежащий и нездоровый) · E2 повторная уборка · F выключатель автоматики.
set +e
HERE=$(cd "$(dirname "$0")" && pwd)          # servers/skld00/tests
SRC=$(cd "$HERE/.." && pwd)                  # servers/skld00
. "$HERE/harness-lib.sh"

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
touch "$S/parked-good-pre-20261001-010101" "$S/parked-good-pre-20261013-150000" "$S/parked-good-pre-20261016-050000"   # стоянки: две старше окна, одна свежая
echo 5 > "$S/streak-good"; echo 1 > "$S/streak-sick"; echo 0 > "$S/streak-upd"; echo 9 > "$S/streak-halt"
echo RUNNING > "$S/state-good"; echo RUNNING > "$S/state-sick"; echo RUNNING > "$S/state-upd"; echo STOPPED > "$S/state-halt"

say()   { printf '\n=== %s\n' "$*"; }
stage() { rm -f "$W/log"; echo 0 > "$S/probe-n"; }
mut()   { local n; n=$(grep -cE "INCUS: (snapshot create|snapshot delete|snapshot restore|restart|stop|start|delete [a-z])|ZFS: (snapshot|rollback|destroy)" "$W/log" 2>/dev/null); printf '%s\n' "${n:-0}"; }
lines() { sort "$1" | tr '\n' ' ' | sed 's/ *$//'; }   # содержимое файла одной строкой, для check
met()   { awk -v k="$1" '$1 == k { print $2 }' "$S/lxc.prom"; }
seq_of() { grep -oE "$1" "$W/log" 2>/dev/null | tr '\n' '|'; }

say "A. пробный прогон (--dry-run): только план, ни одной мутирующей команды"
stage; mkdir -p "$S/state"
bash "$U" --dry-run 2>&1 | sed 's/^/    /'
echo "--- мутирующих вызовов: $(mut)"
check "A: в пробном прогоне ноль мутирующих вызовов" "0" "$(mut)"
check "A: план печатается (есть строка «сделал бы»)" "да" "$(bash "$U" --dry-run 2>&1 | grep -qF 'сделал бы' && echo да || echo нет)"

say "B. обновление проходит: снапшот → флаг → dup → restart → свежий маркер → проба"
stage; DUP_RC=0 PROBE_FAILS=0 bash "$U" --one upd 2>&1 | sed 's/^/    /'
echo "--- последовательность вызовов:"; grep -oE "INCUS: (info|snapshot create|exec upd -- timeout|restart|exec upd -- rm|exec upd -- touch)|ZFS: (list|snapshot)" "$W/log" | sed 's/^/    /'
echo "--- последняя строка отчёта:"; tail -1 "$S/state/status" | sed 's/^/    /'
echo "--- флаг внутри инстанса: $([ -f "$S/pending-upd" ] && echo ОСТАЛСЯ || echo снят)"
check "B: порядок команд обновления" \
    "INCUS: snapshot create|INCUS: exec upd -- touch|INCUS: exec upd -- timeout|INCUS: restart|INCUS: exec upd -- rm|" \
    "$(seq_of 'INCUS: (snapshot create|exec upd -- touch|exec upd -- timeout|restart|exec upd -- rm)')"
check "B: в отчёте update ok" "ok" "$(status_field upd update 3 "$S/state/status")"
check "B: флаг незавершённого обновления снят" "нет" "$([ -f "$S/pending-upd" ] && echo да || echo нет)"

say "C1. dup упал → откат (stop → restore → rollback → start → проба)"
stage; rm -f "$S/pending-upd"; DUP_RC=1 PROBE_FAILS=0 bash "$U" --one upd 2>&1 | sed 's/^/    /'
echo "--- откатные команды:"; grep -E "INCUS: (stop|snapshot restore|start)|ZFS: rollback" "$W/log" | sed 's/^/    /'
echo "--- последняя строка отчёта:"; tail -1 "$S/state/status" | sed 's/^/    /'
check "C1: откат выполнен по порядку" "INCUS: stop upd|INCUS: snapshot restore upd|INCUS: start upd|" \
    "$(seq_of 'INCUS: (stop upd|snapshot restore upd|start upd)')"
nothas "C1: перезапуска не было (dup упал до него)" "INCUS: restart" "$W/log"
check "C1: в отчёте провал с откатом" "провал" "$(status_field upd update 3 "$S/state/status")"
has  "C1: в подробностях — откат выполнен" "откат выполнен (pre-" "$S/state/status"

say "C2. dup прошёл, а проба после обновления упала → откат (вторая проба зелёная)"
stage; rm -f "$S/pending-upd"; DUP_RC=0 PROBE_FAILS=1 bash "$U" --one upd 2>&1 | sed 's/^/    /'
echo "--- откатные команды:"; grep -E "INCUS: (stop|snapshot restore|start)|ZFS: rollback" "$W/log" | sed 's/^/    /'
echo "--- последняя строка отчёта:"; tail -1 "$S/state/status" | sed 's/^/    /'
has  "C2: обновление дошло до перезапуска" "INCUS: restart" "$W/log"
check "C2: откат выполнен по порядку" "INCUS: stop upd|INCUS: snapshot restore upd|INCUS: start upd|" \
    "$(seq_of 'INCUS: (stop upd|snapshot restore upd|start upd)')"
check "C2: в отчёте провал" "провал" "$(status_field upd update 3 "$S/state/status")"

say "C3. маркер загрузки не обновился → откат (перезапуска как будто не было)"
stage; rm -f "$S/pending-upd"
DUP_RC=0 PROBE_FAILS=0 STALE_MARKER=1 MARKER_WAIT=4 bash "$U" --one upd > "$W/out" 2>&1; rc=$?
sed 's/^/    /' "$W/out" | head -8
echo "--- последняя строка отчёта:"; tail -1 "$S/state/status" | sed 's/^/    /'
check "C3: прогон вернул ненулевой код (нужен человек)" "1" "$rc"
has  "C3: в отчёте «ОТКАТ НЕ ПОМОГ»" "ОТКАТ НЕ ПОМОГ" "$S/state/status"
check "C3: флаг оставлен внутри инстанса" "да" "$([ -f "$S/pending-upd" ] && echo да || echo нет)"

say "D. флаг прошлого прогона на старте → сразу откат, zypper не вызывается"
stage; rm -f "$S/pending-upd"; touch "$S/pending-upd"; DUP_RC=0 PROBE_FAILS=0 bash "$U" --one upd 2>&1 | sed 's/^/    /'
echo "--- вызовов zypper: $(grep -c timeout "$W/log")"
echo "--- последняя строка отчёта:"; tail -1 "$S/state/status" | sed 's/^/    /'
check "D: zypper не вызывался" "0" "$(grep -c timeout "$W/log")"
check "D: в отчёте провал с откатом" "провал" "$(status_field upd update 3 "$S/state/status")"

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
check "E: у живого сервиса остались три САМЫХ СВЕЖИХ снапшота инстанса" \
    "pre-20261011-010101 pre-20261012-010101 pre-20261014-010101" "$(lines "$S/snaps-good")"
check "E: и три самых свежих снапшота данных" \
    "tank/g-data@pre-20261013-010101 tank/g-data@pre-20261014-010101 tank/g-data@recreate-20261012-010101" "$(lines "$S/zsnaps-tank_g-data")"
check "E: у нездорового (проба падает) ничего не тронуто" "pre-20261010-010101" "$(lines "$S/snaps-sick")"
check "E: у лежащего (STOPPED) ничего не тронуто" "pre-20261010-010101" "$(lines "$S/snaps-halt")"
has    "E: стоянка старше окна снята" "INCUS: delete good-pre-20261001-010101" "$W/log"
has    "E: вторая стоянка старше окна снята" "INCUS: delete good-pre-20261013-150000" "$W/log"
nothas "E: свежая стоянка не тронута" "INCUS: delete good-pre-20261016-050000" "$W/log"
check "E: итог уборки в отчёте" "снято объектов: 6" "$(status_field good gc 4 "$S/state/status")"
check "E: метрика за этот прогон" "6" "$(met lxc_snapshots_deleted_last_run)"
check "E: накопительная метрика" "6" "$(met lxc_snapshots_deleted_total)"
has    "E: сервис без доказанной живости — со строкой «пропуск»" "живость не доказана" "$S/state/status"

say "E2. второй прогон уборки: снимать уже нечего → last_run=0, накопительный не растёт"
stage; bash "$U" --gc-only >/dev/null 2>&1
grep -E "deleted" "$S/lxc.prom" | sed 's/^/    /'
echo "--- отчёт по уборке во втором прогоне:"; grep "gc" "$S/state/status" | tail -4 | sed 's/^/    /'
check "E2: за прогон ноль снятых" "0" "$(met lxc_snapshots_deleted_last_run)"
check "E2: накопительный счётчик не изменился" "6" "$(met lxc_snapshots_deleted_total)"
check "E2: в отчёте «снимать нечего»" "снимать нечего (всё свежее окна или входит в N=3)" "$(status_field good gc 4 "$S/state/status")"

say "F. выключатель автоматики: только отчёт + строки «пропуск» в отчёте"
stage; touch "$W/off.flag"
bash "$U" 2>&1 | sed 's/^/    /' | head -6
echo "--- мутирующих вызовов: $(mut)"
echo "--- что легло в отчёт:"; grep "автоматика выключена" "$S/state/status" | sed 's/^/    /'
check "F: ноль мутирующих вызовов" "0" "$(mut)"
check "F: по строке «пропуск» на каждый сервис" "4" "$(grep -cF 'автоматика выключена' "$S/state/status")"

summary; rc=$?
sudo -n rm -rf "$W" 2>/dev/null || rm -rf "$W"
exit "$rc"
