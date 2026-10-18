#!/bin/bash
# Харнесс ветки сетей в reconcile.sh: декларации networks/*.yaml → живое состояние Incus.
# Узел не нужен: `incus-loc` (и сетевые подкоманды в нём) — заглушка, git настоящий, но во
# временном каталоге.
#
#   bash servers/skld00/tests/networks-test.sh
#
# Проверяется главное свойство ветки: сеть приводится ДО инстансов, поэтому декларация с
# устройством на несуществующей сети не доходит до пересоздания — прогон останавливается
# на предпосылке с внятной строкой.
#
# Секции: 0 план в dry-run · A создание сети с объявленными ключами и маркером · B сеть уже
# совпадает → ничего · C ключ разъехался → точечный network set · D сеть не объявлена →
# precheck и инстансы не трогаем · E наша сеть без декларации → не удаляем · F создание
# упало → провал и инстансы не трогаются.
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
mk_net() { # имя [переопределение ключа в состоянии]
    {
        echo "name: $1"
        echo "description: \"Тестовая приватная сеть\""
        echo "type: bridge"
        echo ""
        echo "config:"
        echo "  ipv4.address: 172.26.50.1/24     # адрес узла в сегменте"
        echo "  ipv4.dhcp: \"false\""
        echo "  ipv4.nat: \"false\""
        echo "  ipv6.address: \"none\""
    } > "$REPO/servers/skld00/networks/$1.yaml"
}
set_net_state() { # имя, содержимое состояния (key=value строки)
    local n="$1"; shift
    : > "$S/net/$n"
    local kv
    for kv in "$@"; do echo "$kv" >> "$S/net/$n"; done
}
mk_service() { # имя [сеть]
    local n="$1" net="$2"
    {
        echo "name: $n"
        echo "description: \"Тестовый сервис\""
        echo "config:"
        echo "  limits.cpu: \"1\""
        echo "  user.managed-by: homelab-deploy/skld00"
        echo "  user.package: victorialogs-loc"
        echo "  user.update_policy: inplace"
        echo "  user.healthcheck: \"true\""
        echo ""
        echo "devices:"
        echo "  eth0:"
        echo "    type: nic"
        echo "    nictype: macvlan"
        echo "    parent: enp7s0"
        [ -n "$net" ] && { echo "  eth2:"; echo "    type: nic"; echo "    network: $net"; echo "    name: eth2"; }
    } > "$REPO/servers/skld00/services/$n.yaml"
}
applied_for() { # файл-декларация, путь-applied — запись контура для него (формат тот же)
    bash -c ". '$SRC/lib.sh' >/dev/null 2>&1
             printf '%s %s %s\n' \"\$PROJECTION_VERSION\" \"\$(proj_rest '$1' | hash16)\" \"\$(proj_scalars '$1' | hash16)\"" > "$2"
}

# --- заглушка incus-loc -------------------------------------------------------
cat > "$BIN/incus-loc" <<'EOF'
#!/bin/bash
echo "INCUS: $*" >> "$W/log"
case "$1" in
  network)
    case "$2" in
      show)  [ -f "$S/net/$3" ] && { echo "name: $3"; echo "config:"; sed 's/^/  /' "$S/net/$3"; exit 0; } || exit 1 ;;
      create) n=$3; shift 3
              [ -n "${NET_CREATE_FAIL:-}" ] && exit 1
              : > "$S/net/$n"
              for a in "$@"; do case "$a" in --*) continue ;; *) echo "$a" >> "$S/net/$n" ;; esac; done
              exit 0 ;;
      get)    n=$3; k=$4
              [ -f "$S/net/$n" ] || exit 1
              sed -n "s/^$k=//p" "$S/net/$n" | tail -1; exit 0 ;;
      set)    n=$3; k=$4; v=$5
              [ -f "$S/net/$n" ] || exit 1
              grep -v "^$k=" "$S/net/$n" > "$S/net/.tmp" 2>/dev/null; mv "$S/net/.tmp" "$S/net/$n" 2>/dev/null
              echo "$k=$v" >> "$S/net/$n"; exit 0 ;;
      list)   for f in "$S"/net/*; do [ -e "$f" ] && basename "$f"; done; exit 0 ;;
      delete) exit 0 ;;
    esac ;;
  info)   [ -f "$S/exists-$2" ] && exit 0 || exit 1 ;;
  config) if [ "$2" = get ]; then
            case "$4" in
              user.managed-by)   cat "$S/marker-$3" 2>/dev/null ;;
              user.data_dataset) echo "" ;;
              volatile.idmap.next) echo '[{"Isuid":true,"Isgid":false,"Hostid":100000,"Nsid":0,"Maprange":65536}]' ;;
              *) echo "" ;;
            esac
          fi; exit 0 ;;
  exec)   inst=$2; shift 3
          case "$1" in
            id) echo 478 ;;
            test) exit 0 ;;
            systemctl) [ "$2" = is-system-running ] && echo running; exit 0 ;;
            *) exit 0 ;;
          esac ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$BIN/incus-loc"
export PATH="$BIN:$PATH"
export REPO_DIR="$REPO" STATE_DIR="$S/state" OFF_FLAG="$W/off.flag" DRY_RUN=0

say()   { printf '\n=== %s\n' "$*"; }
stage() { rm -f "$W/log"; : > "$W/log"; }
nets()  { grep -oE 'INCUS: network (create|set|delete) [^ ]+' "$W/log" 2>/dev/null | sed 's/INCUS: //'; }
insts() { grep -cE 'INCUS: (create|rename|delete|snapshot) ' "$W/log" 2>/dev/null | tr -d ' '; }

mk_net svc-net
mk_service svc-net svc-net
touch "$S/exists-svc-net"; echo homelab-deploy/skld00 > "$S/marker-svc-net"
applied_for "$REPO/servers/skld00/services/svc-net.yaml" "$S/state/applied/svc-net"

say "0. декларации нет в Incus → в отчёте план (dry-run), ни одной мутации"
stage
DRY_RUN=1 bash "$R" > "$W/out" 2>&1; echo "    --- код: $?"
grep -E "сделал бы: incus-loc network create|предпосылка|сеть " "$W/out" | sed 's/^/    /' | head -4
has    "0: в плане — создание сети с объявленными ключами" "network create svc-net --type bridge" "$W/out"
has    "0: в плане — DHCP выключен" "ipv4.dhcp=false" "$W/out"
has    "0: в плане — маркер контура" "user.managed-by=homelab-deploy/skld00" "$W/out"
has    "0: предпосылка не блокирует (сеть объявлена и будет создана)" "будет создана при применении" "$W/out"
check  "0: мутаций ноль" "0" "$(insts)"

say "A. сети нет, автоматика включена → создаётся с объявленными ключами и маркером"
stage
bash "$R" > "$W/out" 2>&1; echo "    --- код: $?"
echo "    --- вызовы сетей:"; nets | sed 's/^/        /'
echo "    --- состояние сети: $(sed 's/^/    /' "$S/net/svc-net" | tr '\n' ' ')"
has    "A: сеть создана" "network create svc-net" "$W/log"
has    "A: передан ipv4.dhcp=false" "ipv4.dhcp=false" "$W/log"
has    "A: передан ipv4.nat=false" "ipv4.nat=false" "$W/log"
has    "A: передан ipv6.address=none" "ipv6.address=none" "$W/log"
has    "A: маркер контура поставлен при создании" "user.managed-by=homelab-deploy/skld00" "$W/log"
check  "A: в отчёте network ok" "ok" "$(status_field svc-net network 3 "$S/state/status")"
echo "    --- инстансные мутации (для отладки):"; grep -nE 'INCUS: (create|rename|delete|snapshot) ' "$W/log" | sed 's/^/        /' || echo "        нет"
check  "A: инстансы не трогались" "0" "$(insts)"

say "B. сеть есть и совпадает → ни create, ни set"
stage
bash "$R" > "$W/out" 2>&1
grep -E "сеть svc-net" "$W/out" | sed 's/^/    /' | head -3
check  "B: изменений нет" "0" "$(nets | grep -c . | tr -d ' ')"
has    "B: в выводе — «изменений нет»" "сеть svc-net: изменений нет" "$W/out"

say "C. ключ разъехался (в Incus nat=true, объявлено false) → точечный set"
set_net_state svc-net "ipv4.address=172.26.50.1/24" "ipv4.dhcp=false" "ipv4.nat=true" "ipv6.address=none" "user.managed-by=homelab-deploy/skld00"
stage
bash "$R" > "$W/out" 2>&1
grep -E "сеть svc-net: применено" "$W/out" | sed 's/^/    /'
check  "C: применён ровно один ключ" "1" "$(nets | grep -c . | tr -d ' ')"
has    "C: применён именно nat" "network set svc-net ipv4.nat" "$W/log"
has    "C: в отчёте — «ключи сети приведены (изменений: 1)»" "ключи сети приведены (изменений: 1)" "$S/state/status"

say "D. инстанс ссылается на сеть, которой нет и которая не объявлена → precheck, инстансы не трогаем"
mk_service bad bad-net     # декларации networks/bad-net.yaml нет
rm -f "$S/net/bad-net"
stage
bash "$R" > "$W/out" 2>&1; echo "    --- код (ожидаю 1): $?"
grep -E "ОШИБКА|не трогаю" "$W/out" | sed 's/^/    /'
has    "D: назван сервис и сеть" "bad.yaml ссылается на сеть bad-net" "$W/out"
check  "D: в отчёте precheck провал" "провал" "$(status_field bad precheck 3 "$S/state/status")"
has    "D: сказано, что инстансы не трогаем" "инстансы не трогаю" "$W/out"
check  "D: мутаций инстансов ноль" "0" "$(insts)"
rm -f "$REPO/servers/skld00/services/bad.yaml"

say "E. наша сеть без декларации в git → в отчёт, но НЕ удаляем"
mk_net ghost-net; set_net_state ghost-net "ipv4.address=172.26.51.1/24" "user.managed-by=homelab-deploy/skld00"
rm -f "$REPO/servers/skld00/networks/ghost-net.yaml"
set_net_state foreign-net "ipv4.address=10.9.9.1/24"     # чужая: без маркера
stage
bash "$R" > "$W/out" 2>&1
grep -E "ghost-net|foreign-net" "$W/out" | sed 's/^/    /' | head -3
has    "E: наша сеть без декларации названа в выводе" "сеть ghost-net: маркер контура есть, декларации в git нет" "$W/out"
check  "E: в отчёте — пропуск" "пропуск" "$(status_field ghost-net network 3 "$S/state/status")"
nothas "E: удаления сети не было" "INCUS: network delete" "$W/log"
nothas "E: чужую сеть не меняли" "INCUS: network set foreign-net" "$W/log"
nothas "E: чужую сеть не удаляли" "INCUS: network delete foreign-net" "$W/log"
rm -rf "$S/net/ghost-net"

say "F. создание сети упало → провал, инстансы не трогаем"
rm -f "$S/net/svc-net"
stage
NET_CREATE_FAIL=1 bash "$R" > "$W/out" 2>&1; echo "    --- код (ожидаю 1): $?"
grep -E "ОШИБКА|не трогаю" "$W/out" | sed 's/^/    /' | head -3
check  "F: в отчёте network провал" "провал" "$(status_field svc-net network 3 "$S/state/status")"
has    "F: инстансы не трогались" "инстансы не трогаю" "$W/out"
check  "F: мутаций инстансов ноль" "0" "$(insts)"

summary; rc=$?
sudo -n rm -rf "$W" 2>/dev/null || rm -rf "$W"
exit "$rc"
