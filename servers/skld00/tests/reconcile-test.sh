#!/bin/bash
# Харнесс хостового контура (reconcile.sh): разбор деклараций, карта uid, чувствительность хешей,
# живое применение скаляров, пересоздание с откатом. Узел не нужен: `incus-loc`, `zfs` и даже `chown`
# подменяются заглушками, состояние живёт в файлах временного каталога, ничего настоящего не мутируется.
#
#   bash servers/skld00/tests/reconcile-test.sh
#
# Возвращает ненулевой код при первом расхождении (см. harness-lib.sh) — на этом стоит проверка
# перед пушем (.githooks/pre-push).
#
# Секции: 1 синтаксис и «инстанса нет» · 2 разбор декларации · 3 карта uid · 4 чувствительность
# хешей (включая «правили только комментарии») · 5 скаляры разошлись → config set ·
# 6 состав изменился → пересоздание · 7 пересоздание вживую (порядок команд и статус) · 8 отчёт.
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

# --- доступ к внутренностям контура (для проверок) ----------------------------
hcomp()   { bash -c ". '$REPO/servers/skld00/lib.sh'; proj_rest '$1' | hash16"; }
hscal()   { bash -c ". '$REPO/servers/skld00/lib.sh'; proj_scalars '$1' | hash16"; }
dcl()     { bash -c ". '$REPO/servers/skld00/lib.sh'; declared '$SERV' '$1'"; }
uidhost() { bash -c ". '$REPO/servers/skld00/lib.sh'; host_owner vl1 '$1'"; }
hashfile() { printf 'состав=%s скаляры=%s' "$(hcomp "$1")" "$(hscal "$1")"; }
seq_of()  { grep -oE "$1" "$W/log" 2>/dev/null | tr '\n' '|'; }
say()     { printf '\n=== %s\n' "$*"; }
stage()   { rm -f "$W/log" "$W/snaps" "$W/zsnaps"; }

say "1. синтаксис + «инстанса нет»: в отчёте — план создания"
bash -n "$R" && echo "    bash -n: ок"
check "1: синтаксис reconcile.sh пригоден" "0" "$(bash -n "$R" >/dev/null 2>&1; echo $?)"
touch "$W/off.flag"; rm -f "$W/exists"
bash "$R" > "$W/out" 2>&1
sed 's/^/    /' "$W/out"
has    "1: в плане — создание инстанса" "сделал бы: create leap16-base vl1" "$W/out"
nothas "1: в пробном прогоне инстанс не создаётся" "INCUS: create" "$W/log"

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
bash -c ". '$REPO/servers/skld00/lib.sh'; proj_scalars '$SERV'" > "$W/scalars"
bash -c ". '$REPO/servers/skld00/lib.sh'; proj_rest '$SERV'"    > "$W/rest"
check "2: пакет сервиса"            "victorialogs-loc"    "$(dcl user.package)"
check "2: датасет данных"           "tank/vl-data"        "$(dcl user.data_dataset)"
check "2: политика обновления"      "inplace"             "$(dcl user.update_policy)"
check "2: маркер контура"           "homelab-deploy/skld00" "$(dcl user.managed-by)"
check "2: скалярных ключей 11"      "11"                  "$(wc -l < "$W/scalars" | tr -d ' ')"
has   "2: healthcheck попадает в скаляры" "user.healthcheck=curl -fsS" "$W/scalars"
nothas "2: в составе нет скалярных ключей" "limits.cpu" "$W/rest"
nothas "2: в составе нет raw.idmap"        "raw.idmap"   "$W/rest"
has   "2: адрес линка — в составе"         "Address=172.21.6.101/24" "$W/rest"

say "3. карта uid: хостовая сторона = Hostid + uid − Nsid"
for u in 478 479 0; do printf '    uid внутри %-4s → хостовый %s\n' "$u" "$(uidhost "$u")"; done
check "3: uid 478 внутри → 100478 на хосте" "100478" "$(uidhost 478)"
check "3: uid 479 внутри → 100479 на хосте" "100479" "$(uidhost 479)"
check "3: uid 0 внутри → 100000 на хосте"   "100000" "$(uidhost 0)"

say "4. чувствительность хешей (состав и скаляры считаются отдельно)"
c0=$(hcomp "$SERV"); s0=$(hscal "$SERV")
printf '    исходный:            %s\n' "$(hashfile "$SERV")"
sed 's/limits.memory: 2GiB/limits.memory: 3GiB/' "$SERV" > "$W/scalar.yaml"
printf '    правили скаляр:      %s   ← меняются только скаляры\n' "$(hashfile "$W/scalar.yaml")"
sed 's|source: /tank/vl-data|source: /tank/vl-data-2|' "$SERV" > "$W/device.yaml"
printf '    правили устройство:  %s   ← меняется только состав\n' "$(hashfile "$W/device.yaml")"
sed 's|Address=172\.21\.6\.101/24|Address=172.21.6.111/24|' "$SERV" > "$W/userdata.yaml"
printf '    правили user-data:   %s   ← тоже только состав\n' "$(hashfile "$W/userdata.yaml")"
{ echo "# новый комментарий в шапке декларации"; echo ""; sed 's/^  limits\.cpu/  # про ядра\n  limits.cpu/' "$SERV"; } > "$W/comment.yaml"
printf '    только комментарии:  %s   ← обязан совпасть с исходным\n' "$(hashfile "$W/comment.yaml")"
check   "4: правка скаляра состав не меняет"        "$c0"      "$(hcomp "$W/scalar.yaml")"
differs "4: правка скаляра скаляры меняет"          "$s0"      "$(hscal "$W/scalar.yaml")"
differs "4: правка устройства состав меняет"        "$c0"      "$(hcomp "$W/device.yaml")"
check   "4: правка устройства скаляры не меняет"    "$s0"      "$(hscal "$W/device.yaml")"
differs "4: правка user-data состав меняет"         "$c0"      "$(hcomp "$W/userdata.yaml")"
check   "4: правка user-data скаляры не меняет"     "$s0"      "$(hscal "$W/userdata.yaml")"
check   "4: правка ТОЛЬКО комментариев состав не меняет"   "$c0" "$(hcomp "$W/comment.yaml")"
check   "4: правка ТОЛЬКО комментариев скаляры не меняет"  "$s0" "$(hscal "$W/comment.yaml")"

say "5. инстанс есть, скаляры разошлись → в отчёте config set"
export INCUS_EXISTS="$W/exists"; touch "$INCUS_EXISTS"
printf '1GiB\n' > "$W/old"; export INCUS_OLDFILE="$W/old"
printf '1 %s %s\n' "$(hcomp "$SERV")" 0000000000000000 > "$S/state/applied/vl1"
stage; bash "$R" > "$W/out" 2>&1
grep -E "config set|владелец|ничего" "$W/out" | head -8 | sed 's/^/    /'
has "5: план по лимитам"      "config set vl1 limits.cpu" "$W/out"
has "5: план по healthcheck"  "config set vl1 user.healthcheck" "$W/out"
nothas "5: пересоздания нет (меняли только скаляры)" "rename vl1" "$W/out"

say "5б. версия определения проекций сменилась → хеши пересчитываются, пересоздания НЕТ"
printf '%s %s\n' "$(hcomp "$SERV")" "$(hscal "$SERV")" > "$S/state/applied/vl1"    # старый формат: без версии
rm -f "$W/off.flag"      # ветка живая (не план), иначе проверяли бы только текст плана
stage; bash "$R" > "$W/out" 2>&1
grep -E "версия|пересоздан|config set" "$W/out" | head -4 | sed 's/^/    /'
echo "    --- запись состояния после прогона: $(cat "$S/state/applied/vl1")"
has    "5б: о смене версии сказано в выводе" "версия определения проекций сменилась" "$W/out"
has    "5б: в отчёте — «пересоздание не требовалось»" "пересоздание не требовалось" "$S/state/status"
nothas "5б: пересоздания не было" "INCUS: rename" "$W/log"
nothas "5б: скаляры не применялись (состояние принято как есть)" "INCUS: config set" "$W/log"
check  "5б: первое поле записи — версия проекции" "1" "$(cut -d' ' -f1 "$S/state/applied/vl1")"
check  "5б: запись состояния — из трёх полей" "3" "$(wc -w < "$S/state/applied/vl1" | tr -d ' ')"
touch "$W/off.flag"      # дальше разделы снова смотрят план

say "6. инстанс есть, состав изменился → пересоздание (в отчёте — план)"
printf '1 %s %s\n' 1111111111111111 "$(hscal "$SERV")" > "$S/state/applied/vl1"
stage; bash "$R" > "$W/out" 2>&1
grep -E "состав|пересоздание|сделал бы: zfs|rename" "$W/out" | head -6 | sed 's/^/    /'
has    "6: в плане — снапшот данных" "zfs snapshot tank/vl-data@recreate-" "$W/out"
has    "6: в плане — стоянка через rename" "rename vl1 → vl1-pre-" "$W/out"
nothas "6: в пробном прогоне ничего не делается" "ZFS: snapshot" "$W/log"

say "7. пересоздание вживую (заглушки, без root): снапшот → stop → rename → create → проба"
rm -f "$W/off.flag"; stage
bash "$R" > "$W/out" 2>&1
tail -6 "$W/out" | sed 's/^/    /'
echo "    --- порядок вызовов:"; grep -E "ZFS: |INCUS: (stop|rename|create|start|delete|snapshot|config|exec)|CHOWN: " "$W/log" | sed 's/^/        /' | head -16
echo "    --- стоянка (rename, а не delete — старый инстанс остаётся как есть):"; grep -E "INCUS: rename" "$W/log" | sed 's/^/        /'
check   "7: порядок пересоздания" "ZFS: snapshot|INCUS: stop vl1|INCUS: rename vl1|INCUS: create|INCUS: start vl1|" \
        "$(seq_of 'ZFS: snapshot|INCUS: (stop vl1|rename vl1|create|start vl1)')"
nothas  "7: новый инстанс не удаляется (успешный путь)" "INCUS: delete" "$W/log"
has     "7: владелец данных выставлен хостовой стороной uid" "CHOWN: 100478:100478 tank/vl-data" "$W/log"
check   "7: в отчёте recreate ok" "ok" "$(status_field vl1 recreate 3 "$S/state/status")"
check   "7: состояние записано с версией проекции" "1" "$(cut -d' ' -f1 "$S/state/applied/vl1")"

say "8. файл отчёта (/var/lib/lxc-update/status)"
sed 's/^/    /' "$S/state/status" 2>/dev/null
has "8: отчёт содержит строку пересоздания" "пересоздан по новой декларации" "$S/state/status"

summary; rc=$?
sudo -n rm -rf "$W" 2>/dev/null || rm -rf "$W"
exit "$rc"
