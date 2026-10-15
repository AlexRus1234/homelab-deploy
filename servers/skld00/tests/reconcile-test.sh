#!/bin/bash
# Харнесс хостового контура (reconcile.sh): разбор деклараций, карта uid, чувствительность хешей,
# живое применение скаляров, пересоздание с откатом. Узел не нужен: `incus-loc`, `zfs` и даже `chown`
# подменяются заглушками, состояние живёт в файлах временного каталога, ничего настоящего не мутируется.
#
#   bash servers/skld00/tests/reconcile-test.sh
#
# Секции: 1 синтаксис и «инстанса нет» · 2 разбор декларации · 3 карта uid · 4 чувствительность
# хешей (включая «правили только комментарии») · 5 скаляры разошлись → config set ·
# 6 состав изменился → пересоздание · 7 пересоздание вживую (порядок команд и статус) · 8 отчёт.
set +e
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/.." && pwd)

W=$(mktemp -d)
BIN="$W/bin"; mkdir -p "$BIN"
REPO="$W/repo"; mkdir -p "$REPO/servers/skld00/services"
S="$W/state"; mkdir -p "$S/state"
export W S

cp "$SRC/lib.sh" "$SRC/reconcile.sh" "$REPO/servers/skld00/"
cp "$SRC/services/vl1.yaml" "$REPO/servers/skld00/services/"
R="$REPO/servers/skld00/reconcile.sh"
SERV="$REPO/servers/skld00/services/vl1.yaml"

# --- заглушки -----------------------------------------------------------------
cat > "$BIN/incus-loc" <<'EOF'
#!/bin/bash
echo "INCUS: $*" >> "$W/log"
case "$1" in
  info) [ -f "$INCUS_EXISTS" ] && exit 0 || exit 1 ;;
  list) if [ "$3" = "-c" ]; then echo RUNNING; else echo "$2"; fi; exit 0 ;;
  config) if [ "$2" = get ]; then
            case "$4" in
              volatile.idmap.next) echo '[{"Isuid":true,"Isgid":false,"Hostid":100000,"Nsid":0,"Maprange":65536},{"Isuid":false,"Isgid":true,"Hostid":100000,"Nsid":0,"Maprange":65536}]' ;;
              user.managed-by)     echo "homelab-deploy/skld00" ;;
              *)                   [ -f "$INCUS_OLDFILE" ] && cat "$INCUS_OLDFILE" ;;
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
  snapshot) echo "INCUS: snapshot $2 $3" >> "$W/log"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
cat > "$BIN/zfs" <<'EOF'
#!/bin/bash
echo "ZFS: $*" >> "$W/log"
case "$2" in
  -o) echo "${@: -1}" ;;                       # zfs list -H -o name <ds> → датасет «есть»
  *)  case "$1" in
        get) echo "${@: -1}" ;;                # mountpoint → сам датасет
        snapshot) echo "$2" >> "$W/zsnaps" ;;
        rollback) exit 0 ;;
        *) exit 0 ;;
      esac ;;
esac
exit 0
EOF
cat > "$BIN/chown" <<'EOF'
#!/bin/bash
echo "CHOWN: $*" >> "$W/log"     # заглушка: контур зовёт chown, но root в харнессе не нужен
exit 0
EOF
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"
export REPO_DIR="$REPO" STATE_DIR="$S/state" OFF_FLAG="$W/off.flag" DRY_RUN=0

hashfile() { # печатает оба хеша так же, как их считает контур: состав и скаляры отдельно
    bash -c ". '$REPO/servers/skld00/lib.sh'; printf 'состав=%s скаляры=%s' \"\$(proj_rest '$1' | hash16)\" \"\$(proj_scalars '$1' | hash16)\""
}
say() { printf '\n=== %s\n' "$*"; }
stage() { rm -f "$W/log" "$W/snaps" "$W/zsnaps"; }

say "1. синтаксис + «инстанса нет»: в отчёте — план создания"
bash -n "$R" && echo "    bash -n: ок"
touch "$W/off.flag"; rm -f "$W/exists"
bash "$R" 2>&1 | sed 's/^/    /'

say "2. разбор декларации: ключи, скаляры и состав"
bash -c "
  . '$REPO/servers/skld00/lib.sh'
  echo '    user.package       = '\$(declared '$SERV' user.package)
  echo '    user.data_dataset  = '\$(declared '$SERV' user.data_dataset)
  echo '    user.update_policy = ['\$(declared '$SERV' user.update_policy)']'
  echo '    --- скалярные ключи (применяются живьём):'
  proj_scalars '$SERV' | sed 's/^/        /'
  echo '    --- в проекции состава строк со скалярами: '\$(proj_rest '$SERV' | grep -c 'limits\.cpu\|user\.healthcheck')
  echo '    --- в проекции состава строк с raw.idmap: '\$(proj_rest '$SERV' | grep -c 'raw.idmap')
"

say "3. карта uid: хостовая сторона = Hostid + uid − Nsid"
bash -c ". '$REPO/servers/skld00/lib.sh'; for u in 478 479 0; do printf '    uid внутри %-4s → хостовый %s\n' \"\$u\" \"\$(host_owner vl1 \$u)\"; done"

say "4. чувствительность хешей (состав и скаляры считаются отдельно)"
echo "    исходный:            $(hashfile "$SERV")"
sed 's/limits.memory: 2GiB/limits.memory: 3GiB/' "$SERV" > "$W/scalar.yaml"
echo "    правили скаляр:      $(hashfile "$W/scalar.yaml")   ← меняются только скаляры"
sed 's|source: /tank/vl-data|source: /tank/vl-data-2|' "$SERV" > "$W/device.yaml"
echo "    правили устройство:  $(hashfile "$W/device.yaml")   ← меняется только состав"
sed 's|Address=172\.21\.6\.101/24|Address=172.21.6.111/24|' "$SERV" > "$W/userdata.yaml"
echo "    правили user-data:   $(hashfile "$W/userdata.yaml")   ← тоже только состав"
{ echo "# новый комментарий в шапке декларации"; echo ""; sed 's/^  limits\.cpu/  # про ядра\n  limits.cpu/' "$SERV"; } > "$W/comment.yaml"
echo "    только комментарии:  $(hashfile "$W/comment.yaml")   ← обязан совпасть с исходным"

say "5. инстанс есть, скаляры разошлись → в отчёте config set"
export INCUS_EXISTS="$W/exists"; touch "$INCUS_EXISTS"
printf '1GiB\n' > "$W/old"; export INCUS_OLDFILE="$W/old"
bash -c ". '$REPO/servers/skld00/lib.sh'; printf '%s %s\n' \"\$(proj_rest '$SERV' | hash16)\" 0000000000000000" > "$S/state/applied/vl1"
stage; bash "$R" 2>&1 | grep -E "config set|владелец|ничего" | head -8 | sed 's/^/    /'

say "6. инстанс есть, состав изменился → пересоздание (в отчёте — план)"
bash -c ". '$REPO/servers/skld00/lib.sh'; printf '%s %s\n' 1111111111111111 \"\$(proj_scalars '$SERV' | hash16)\"" > "$S/state/applied/vl1"
stage; bash "$R" 2>&1 | grep -E "состав|пересоздание|сделал бы: zfs|rename" | head -6 | sed 's/^/    /'

say "7. пересоздание вживую (заглушки, без root): снапшот → stop → rename → create → проба"
rm -f "$W/off.flag"; stage
bash "$R" 2>&1 | tail -6 | sed 's/^/    /'
echo "    --- порядок вызовов:"; grep -E "ZFS: |INCUS: (stop|rename|create|start|delete|snapshot|config|exec)|CHOWN: " "$W/log" | sed 's/^/        /' | head -16
echo "    --- стоянка (rename, а не delete — старый инстанс остаётся как есть):"; grep -E "INCUS: rename" "$W/log" | sed 's/^/        /'

say "8. файл отчёта (/var/lib/lxc-update/status)"
sed 's/^/    /' "$S/state/status" 2>/dev/null

sudo -n rm -rf "$W" 2>/dev/null || rm -rf "$W"
