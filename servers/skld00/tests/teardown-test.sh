#!/bin/bash
# Харнесс ручных режимов контура: `reconcile.sh --down` (снять всё объявленное) и `--up`
# (поднять из деклараций). Это тот самый путь «в одну команду», которым пользуется владелец
# для демонстрации и для чистой пересборки: данные не трогаются, поэтому пара снять/поднять
# возвращает систему в то же состояние.
#
# Узел не нужен: `incus-loc`, `zfs` и `chown` — заглушки.
#
#   bash servers/skld00/tests/teardown-test.sh
#
# Секции: 0 --down в dry-run (только план) · A снятие: инстансы, наши стоянки, сеть последней,
# данные на месте · B --up после снятия: сеть и оба инстанса снова созданы · C сеть занята
# кем-то ещё → провал и ненулевой код.
set +e
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/.." && pwd)
. "$HERE/harness-lib.sh"

W=$(mktemp -d)
BIN="$W/bin"; mkdir -p "$BIN"
REPO="$W/repo"; mkdir -p "$REPO/servers/skld00/services" "$REPO/servers/skld00/networks"
S="$W/state"; mkdir -p "$S/state/applied" "$S/net"
export W S

cp "$SRC/lib.sh" "$SRC/reconcile.sh" "$REPO/servers/skld00/"
R="$REPO/servers/skld00/reconcile.sh"

# --- фикстуры -----------------------------------------------------------------
mk_net() { # имя
    {
        echo "name: $1"
        echo "description: \"Приватная сеть узла (тест)\""
        echo "type: bridge"
        echo ""
        echo "config:"
        echo "  ipv4.address: 172.26.50.1/24"
        echo "  ipv4.dhcp: \"false\""
        echo "  ipv4.nat: \"false\""
        echo "  ipv6.address: \"none\""
    } > "$REPO/servers/skld00/networks/$1.yaml"
}
mk_service() { # имя, датасет
    {
        echo "name: $1"
        echo "description: \"Сервис (тест)\""
        echo "config:"
        echo "  limits.cpu: \"2\""
        echo "  user.managed-by: homelab-deploy/skld00"
        echo "  user.package: victorialogs-loc"
        echo "  user.update_policy: inplace"
        echo "  user.data_dataset: $2"
        echo "  user.data_mountpoint: /var/lib/$1"
        echo "  user.boot_marker: /run/lxc-boot-ok"
        echo "  user.healthcheck: \"true\""
        echo ""
        echo "devices:"
        echo "  eth0:"
        echo "    type: nic"
        echo "    nictype: macvlan"
        echo "    parent: enp7s0"
        echo "  eth2:"
        echo "    type: nic"
        echo "    network: observ0"
        echo "    name: eth2"
        echo "  data:"
        echo "    type: disk"
        echo "    source: /$2"
        echo "    path: /var/lib/$1"
    } > "$REPO/servers/skld00/services/$1.yaml"
}

mk_net observ0
mk_service victorialogs1 tank/vl-data
mk_service victoriametrics1 tank/vm-data
mk_service unmarked tank/unmarked-data      # объявлен, но инстанс без нашего маркера

# состояние узла: два наших инстанса, «одноимённый, но чужой», стоянки, наша сеть
for n in victorialogs1 victoriametrics1; do touch "$S/exists-$n"; echo homelab-deploy/skld00 > "$S/marker-$n"; done
touch "$S/exists-zz-foreign"                                    # без маркера — не наш
touch "$S/exists-unmarked"                                      # объявлен, но маркера нет: трогать нельзя
st=$(stamp_ago 100000)                                          # метка стоянки — от «сейчас», не датой
touch "$S/exists-victorialogs1-pre-$st"; echo homelab-deploy/skld00 > "$S/marker-victorialogs1-pre-$st"
touch "$S/exists-zz-pre-$st"                                    # стоянка без маркера — не наша
echo "ipv4.address=172.26.50.1/24" > "$S/net/observ0"
echo "user.managed-by=homelab-deploy/skld00" >> "$S/net/observ0"

# --- заглушки -----------------------------------------------------------------
cat > "$BIN/incus-loc" <<'EOF'
#!/bin/bash
echo "INCUS: $*" >> "$W/log"
case "$1" in
  info)   [ -f "$S/exists-$2" ] && exit 0 || exit 1 ;;
  create) touch "$S/exists-$3"; exit 0 ;;
  start|stop|rename) exit 0 ;;
  delete) rm -f "$S/exists-$2"; exit 0 ;;
  list)   for f in "$S"/exists-*; do [ -e "$f" ] && basename "$f" | sed 's/^exists-//'; done; exit 0 ;;
  config) if [ "$2" = get ]; then
            case "$4" in
              user.managed-by)   cat "$S/marker-$3" 2>/dev/null ;;
              volatile.idmap.next) echo '[{"Isuid":true,"Isgid":false,"Hostid":100000,"Nsid":0,"Maprange":65536}]' ;;
              *) echo "" ;;
            esac
          fi; exit 0 ;;
  exec)   inst=$2; shift 3
          case "$1" in
            id) echo 478 ;;
            test) exit 0 ;;
            systemctl) [ "$2" = is-system-running ] && echo running; exit 0 ;;
            cloud-init) exit 0 ;;
            */lxc-healthcheck) exit 0 ;;
            *) exit 0 ;;
          esac ;;
  network)
    case "$2" in
      show)   [ -f "$S/net/$3" ] && { echo "name: $3"; echo "config:"; sed 's/^/  /' "$S/net/$3"; exit 0; } || exit 1 ;;
      create) n=$3; shift 3; : > "$S/net/$n"
              for a in "$@"; do case "$a" in --*) continue ;; *) echo "$a" >> "$S/net/$n" ;; esac; done
              exit 0 ;;
      get)    n=$3; k=$4; [ -f "$S/net/$n" ] || exit 1; sed -n "s/^$k=//p" "$S/net/$n" | tail -1; exit 0 ;;
      set)    n=$3; k=$4; v=$5
              [ -f "$S/net/$n" ] || exit 1
              grep -v "^$k=" "$S/net/$n" > "$S/net/.t" 2>/dev/null; mv "$S/net/.t" "$S/net/$n" 2>/dev/null
              echo "$k=$v" >> "$S/net/$n"; exit 0 ;;
      list)   for f in "$S"/net/*; do [ -e "$f" ] && basename "$f"; done; exit 0 ;;
      delete) [ -n "${NET_DELETE_FAIL:-}" ] && exit 1; rm -f "$S/net/$3"; exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
EOF
cat > "$BIN/zfs" <<'EOF'
#!/bin/bash
echo "ZFS: $*" >> "$W/log"
last=${!#}
case "$1" in
  list) [ "${2:-}" = "-t" ] && exit 0; echo "$last"; exit 0 ;;
  get)  echo "/$(basename "$last")"; exit 0 ;;
  *)    exit 0 ;;
esac
EOF
cat > "$BIN/chown" <<'EOF'
#!/bin/bash
echo "CHOWN: $*" >> "$W/log"     # заглушка: root в харнессе не нужен
exit 0
EOF
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"
export REPO_DIR="$REPO" STATE_DIR="$S/state" OFF_FLAG="$W/off.flag" DRY_RUN=0

say()   { printf '\n=== %s\n' "$*"; }
stage() { : > "$W/log"; }
mut()   { grep -cE "INCUS: (create|delete|stop|rename)|ZFS: snapshot" "$W/log" 2>/dev/null | tr -d ' '; }
lineof() { grep -n -- "$1" "$W/log" 2>/dev/null | head -1 | cut -d: -f1; }

say "0. --down в dry-run: только план, ноль мутаций"
stage
DRY_RUN=1 bash "$R" --down > "$W/out" 2>&1; echo "    --- код: $?"
grep -E "сделал бы|режим" "$W/out" | sed 's/^/    /' | head -6
has   "0: в плане — снятие инстанса"       "сделал бы: incus-loc stop victorialogs1; incus-loc delete victorialogs1" "$W/out"
has   "0: в плане — снятие стоянки"        "incus-loc delete victorialogs1-pre-$st --force"    "$W/out"
has   "0: в плане — снятие сети"           "incus-loc network delete observ0"                    "$W/out"
check "0: мутаций ноль" "0" "$(mut)"

say "0б. аргументы от sync-state (два git-хеша) — обычный проход, а не ошибка ключа"
stage
bash "$R" 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 > "$W/out" 2>&1; echo "    --- код: $?"
grep -E "reconcile:|использование" "$W/out" | sed 's/^/    /' | head -3
nothas "0б: ключ не отвергнут"           "неизвестный ключ" "$W/out"
nothas "0б: ничего не снято"             "INCUS: delete"    "$W/log"
has    "0б: в выводе видны оба хеша"     "1111111"          "$W/out"

say "A. --down: инстансы и наши объекты сняты, сеть последней, данные на месте"
stage
bash "$R" --down > "$W/out" 2>&1; echo "    --- код: $?"
grep -E "снятие|снапшот|данные" "$W/out" | sed 's/^/    /' | head -12
echo "    --- осталось инстансов: $(ls "$S" | grep -c '^exists-' | tr -d ' ') (ожидаем 3: наши сняты, чужие и без маркера остались)"
has   "A: victorialogs1 остановлен и снят"        "INCUS: stop victorialogs1"        "$W/log"
has   "A: victorialogs1 удалён"                   "INCUS: delete victorialogs1"      "$W/log"
has   "A: victoriametrics1 удалён"                   "INCUS: delete victoriametrics1"      "$W/log"
has   "A: страховочный снапшот данных victorialogs1" "ZFS: snapshot tank/vl-data@removed-" "$W/log"
has   "A: страховочный снапшот данных victoriametrics1" "ZFS: snapshot tank/vm-data@removed-" "$W/log"
nothas "A: датасеты не удаляются"        "ZFS: destroy"           "$W/log"
check "A: сеть снята ПОСЛЕ инстансов" "да" \
    "$([ "$(lineof 'INCUS: delete victorialogs1')" -lt "$(lineof 'INCUS: network delete observ0')" ] && echo да || echo нет)"
nothas "A: чужой инстанс не тронут"      "INCUS: delete zz-foreign" "$W/log"
nothas "A: инстанс без маркера не тронут" "INCUS: delete unmarked"  "$W/log"
has   "A: наша стоянка снята"            "INCUS: delete victorialogs1-pre-$st --force" "$W/log"
nothas "A: чужая стоянка не тронута"     "INCUS: delete zz-pre-$st" "$W/log"
nothas "A: чужая сеть не тронута"        "INCUS: network delete foreign" "$W/log"
check "A: в отчёте down ok у victorialogs1"        "ok" "$(status_field victorialogs1 down 3 "$S/state/status")"
check "A: в отчёте пропуск у инстанса без маркера" "пропуск" "$(status_field unmarked down 3 "$S/state/status")"

say "B. --up после снятия: сеть и оба инстанса созданы заново"
stage
bash "$R" --up > "$W/out" 2>&1; echo "    --- код: $?"
grep -E "сеть|create|создан|uid" "$W/out" | sed 's/^/    /' | head -10
echo "    --- инстансов теперь: $(ls "$S" | grep -c '^exists-' | tr -d ' ')"
has   "B: сеть создана заново"           "INCUS: network create observ0" "$W/log"
has   "B: victorialogs1 создан"                    "INCUS: create leap16-base victorialogs1" "$W/log"
has   "B: victoriametrics1 создан"                    "INCUS: create leap16-base victoriametrics1" "$W/log"
check "B: в отчёте create ok у victorialogs1"      "ok" "$(status_field victorialogs1 create 3 "$S/state/status")"
check "B: в отчёте create ok у victoriametrics1"      "ok" "$(status_field victoriametrics1 create 3 "$S/state/status")"
check "B: в отчёте network ok"           "ok" "$(status_field observ0 network 3 "$S/state/status")"

say "C. сеть занята кем-то ещё → удаление не проходит, код ненулевой"
stage
NET_DELETE_FAIL=1 bash "$R" --down > "$W/out" 2>&1; echo "    --- код (ожидаю 1): $?"
grep -E "ОШИБКА|подключён" "$W/out" | sed 's/^/    /' | head -3
check "C: в отчёте провал у сети" "провал" "$(status_field observ0 down 3 "$S/state/status")"

summary; rc=$?
sudo -n rm -rf "$W" 2>/dev/null || rm -rf "$W"
exit "$rc"
