#!/bin/bash
# Харнесс конфигов узла (node/apply.sh). Узел не нужен: pacman, systemctl и ss подменяются
# заглушками, конфиги раскладываются в временный ETC.
#
#   bash servers/skld00/tests/node-test.sh
#
# Секции: 1 первая установка (раскладка + включение + перезапуск) · 2 повторный прогон
# (ничего не меняется, юниты не дёргаются) · 3 смена одного конфига → перезапуск только его ·
# 4 провал приёмки: источник на 0.0.0.0 · 5 выключатель автоматики · 6 пакета нет → pacman.
set +e
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/.." && pwd)
. "$HERE/harness-lib.sh"

W=$(mktemp -d)
BIN="$W/bin"; mkdir -p "$BIN"
export W

say() { printf '\n--- %s\n' "$*"; }

# --- заглушки -----------------------------------------------------------------
cat > "$BIN/systemctl" <<'EOF'
#!/bin/bash
echo "SYSTEMCTL: $*" >> "$W/sc.log"
case "$1" in is-active) exit 0 ;; esac
exit 0
EOF
cat > "$BIN/pacman" <<'EOF'
#!/bin/bash
echo "PACMAN: $*" >> "$W/pc.log"
exit 0
EOF
cat > "$BIN/ss" <<'EOF'
#!/bin/bash
echo "SS: $*" >> "$W/ss.log"
cat "$W/ss.out" 2>/dev/null
exit 0
EOF
# «установленные» бинарники: имена пакетов совпадают с именами бинарников
for u in node_exporter-loc smartctl_exporter-loc zfs_exporter-loc vector-loc; do
    printf '#!/bin/sh\nexit 0\n' > "$BIN/$u"; chmod +x "$BIN/$u"
done
chmod +x "$BIN/systemctl" "$BIN/pacman" "$BIN/ss"
export PATH="$BIN:$PATH"

# нормальный ответ ss: три источника на адресе сегмента
cat > "$W/ss.ok" <<'EOF'
LISTEN 0 4096 172.26.50.1:9100 0.0.0.0:*
LISTEN 0 4096 172.26.50.1:9633 0.0.0.0:*
LISTEN 0 4096 172.26.50.1:9134 0.0.0.0:*
EOF
# плохой: один источник слушает всё
cat > "$W/ss.leak" <<'EOF'
LISTEN 0 4096 172.26.50.1:9100 0.0.0.0:*
LISTEN 0 4096 0.0.0.0:9633 0.0.0.0:*
LISTEN 0 4096 172.26.50.1:9134 0.0.0.0:*
EOF
cp "$W/ss.ok" "$W/ss.out"

say "1. первая установка: конфиги на месте, юниты включены и перезапущены"
ETC1="$W/etc1"
rm -f "$W/sc.log"
NODE_DIR="$SRC/node" SS="$BIN/ss" SYSTEMCTL="$BIN/systemctl" PACMAN="$BIN/pacman" \
  ETC="$ETC1" TEXTFILE_DIR="$W/textfile" OFF_FLAG="$W/off.flag" \
  bash "$SRC/node/apply.sh" > "$W/run1" 2>&1
rc1=$?
check "код возврата 0" "0" "$rc1"
check "конфиг node_exporter на месте" "yes" "$([ -f "$ETC1/conf.d/node_exporter-loc" ] && echo yes || echo no)"
check "конфиг smartctl на месте"     "yes" "$([ -f "$ETC1/conf.d/smartctl_exporter-loc" ] && echo yes || echo no)"
check "конфиг zfs на месте"          "yes" "$([ -f "$ETC1/conf.d/zfs_exporter-loc" ] && echo yes || echo no)"
check "конфиг vector на месте"       "yes" "$([ -f "$ETC1/vector-loc/vector.yaml" ] && echo yes || echo no)"
check "содержимое совпадает с репо" "same" "$(cmp -s "$SRC/node/vector/vector.yaml" "$ETC1/vector-loc/vector.yaml" && echo same || echo diff)"
has "включён node_exporter"  "SYSTEMCTL: enable --now node_exporter-loc"  "$W/sc.log"
has "включён smartctl"       "SYSTEMCTL: enable --now smartctl_exporter-loc" "$W/sc.log"
has "включён zfs"            "SYSTEMCTL: enable --now zfs_exporter-loc"   "$W/sc.log"
has "включён vector"         "SYSTEMCTL: enable --now vector-loc"         "$W/sc.log"
has "node перезапущен (конфиг новый)" "SYSTEMCTL: restart node_exporter-loc" "$W/sc.log"
has "приёмка прошла"         "приёмка: три источника слушают только 172.26.50.1" "$W/run1"
nothas "утечки в лог нет"    "источник виден из других сегментов" "$W/run1"

say "2. повторный прогон: файлы не переписываются, юниты не перезапускаются"
rm -f "$W/sc.log"
NODE_DIR="$SRC/node" SS="$BIN/ss" SYSTEMCTL="$BIN/systemctl" PACMAN="$BIN/pacman" \
  ETC="$ETC1" TEXTFILE_DIR="$W/textfile" OFF_FLAG="$W/off.flag" \
  bash "$SRC/node/apply.sh" > "$W/run2" 2>&1
check "код возврата 0" "0" "$?"
nothas "перезаписи конфигов нет" "конфиг обновлён" "$W/run2"
nothas "перезапусков нет"        "SYSTEMCTL: restart" "$W/sc.log"

say "3. изменился один конфиг → перезапускается только его юнит"
sed -i 's/9134/9135/' "$ETC1/conf.d/zfs_exporter-loc"     # намеренная порча: файл разошёлся с репо
rm -f "$W/sc.log"
NODE_DIR="$SRC/node" SS="$BIN/ss" SYSTEMCTL="$BIN/systemctl" PACMAN="$BIN/pacman" \
  ETC="$ETC1" TEXTFILE_DIR="$W/textfile" OFF_FLAG="$W/off.flag" \
  bash "$SRC/node/apply.sh" > "$W/run3" 2>&1
has    "конфиг zfs восстановлен"  "конфиг обновлён: $ETC1/conf.d/zfs_exporter-loc" "$W/run3"
has    "zfs перезапущен"          "SYSTEMCTL: restart zfs_exporter-loc" "$W/sc.log"
nothas "node_exporter не тронут"  "SYSTEMCTL: restart node_exporter-loc" "$W/sc.log"
nothas "vector не тронут"         "SYSTEMCTL: restart vector-loc" "$W/sc.log"

say "4. приёмка падает, если источник слушает 0.0.0.0"
cp "$W/ss.leak" "$W/ss.out"
NODE_DIR="$SRC/node" SS="$BIN/ss" SYSTEMCTL="$BIN/systemctl" PACMAN="$BIN/pacman" \
  ETC="$ETC1" TEXTFILE_DIR="$W/textfile" OFF_FLAG="$W/off.flag" \
  bash "$SRC/node/apply.sh" > "$W/run4" 2>&1
rc4=$?
check "код возврата не 0"      "1" "$rc4"
has   "сказано про ожидание"   "ОШИБКА: ждал три источника на 172.26.50.1" "$W/run4"
has   "названа причина"        "источник виден из других сегментов"        "$W/run4"
has   "провал назван"          "конфиги узла: провал"                     "$W/run4"
cp "$W/ss.ok" "$W/ss.out"

say "5. выключатель автоматики: только отчёт"
ETC5="$W/etc5"; : > "$W/off.flag"
NODE_DIR="$SRC/node" SS="$BIN/ss" SYSTEMCTL="$BIN/systemctl" PACMAN="$BIN/pacman" \
  ETC="$ETC5" TEXTFILE_DIR="$W/textfile" OFF_FLAG="$W/off.flag" \
  bash "$SRC/node/apply.sh" > "$W/run5" 2>&1
check "код возврата 0" "0" "$?"
has   "сказано про флаг"     "АВТОМАТИКА ОТКЛЮЧЕНА" "$W/run5"
nothas "файлы не разложены"  "конфиг обновлён"      "$W/run5"
check "каталога не появилось" "no" "$([ -f "$ETC5/conf.d/node_exporter-loc" ] && echo yes || echo no)"
rm -f "$W/off.flag"

say "6. пакета нет (бинарника нет) → ставится pacman'ом"
rm -f "$BIN/zfs_exporter-loc" "$W/pc.log"
NODE_DIR="$SRC/node" SS="$BIN/ss" SYSTEMCTL="$BIN/systemctl" PACMAN="$BIN/pacman" \
  ETC="$W/etc6" TEXTFILE_DIR="$W/textfile" OFF_FLAG="$W/off.flag" \
  bash "$SRC/node/apply.sh" > "$W/run6" 2>&1
has "вызвана установка zfs_exporter-loc" "PACMAN: -S --noconfirm --needed zfs_exporter-loc" "$W/pc.log"
has "сказано, что ставит"                "пакета нет — ставлю zfs_exporter-loc" "$W/run6"
printf '#!/bin/sh\nexit 0\n' > "$BIN/zfs_exporter-loc"; chmod +x "$BIN/zfs_exporter-loc"

summary
