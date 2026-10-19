#!/bin/bash
# Харнесс конфигов узла (node/apply.sh). Узел не нужен: systemctl и ss подменяются заглушками,
# конфиги раскладываются во временный ETC.
#
#   bash servers/skld00/tests/node-test.sh
#
# Отдельно и явно проверяется то, чего скрипт делать НЕ должен: ставить пакеты (заглушка pacman
# оставляет след, а проверки след ищут) и менять enable-состояние юнитов.
#
# Секции: 1 первая установка (раскладка + перезапуск юнита со сменившимся конфигом) · 2 повторный
# прогон (ничего не меняется, юниты не дёргаются) · 3 смена одного конфига → перезапуск только
# его · 4 провал приёмки: источник слушает всё · 5 выключатель автоматики · 6 нет бинарника →
# провал и НИКАКОЙ установки · 7 юнит не активен → провал с адресной командой · 8 юнит не включён
# → предупреждение, но не провал.
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
case "$1" in
  is-active|is-enabled)
    u="${@: -1}"                    # имя юнита — последний аргумент (перед ним может быть --quiet)
    f="$W/inactive"; [ "$1" = is-enabled ] && f="$W/disabled"
    [ -s "$f" ] && grep -qx "$u" "$f" && exit 1
    exit 0 ;;
esac
exit 0
EOF
# pacman вызывать нельзя: заглушка оставляет след, и проверки его ищут
cat > "$BIN/pacman" <<'EOF'
#!/bin/bash
echo "PACMAN (вызывать нельзя): $*" >> "$W/pc.log"
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
# плохой: один источник слушает всё (так и вышло на узле 19.10, пока конфиг не применён)
cat > "$W/ss.leak" <<'EOF'
LISTEN 0 4096 172.26.50.1:9100 0.0.0.0:*
LISTEN 0 4096 *:9633 0.0.0.0:*
LISTEN 0 4096 172.26.50.1:9134 0.0.0.0:*
EOF
cp "$W/ss.ok" "$W/ss.out"

apply() { # ETC, файл вывода
    NODE_DIR="$SRC/node" SS="$BIN/ss" SYSTEMCTL="$BIN/systemctl" \
      ETC="$1" TEXTFILE_DIR="$W/textfile" OFF_FLAG="$W/off.flag" STATE_DIR="$W/state" \
      bash "$SRC/node/apply.sh" > "$2" 2>&1
}

say "1. первая установка: конфиги разложены, юнит со сменившимся конфигом перезапущен"
ETC1="$W/etc1"; rm -f "$W/sc.log" "$W/pc.log"
apply "$ETC1" "$W/run1"; rc1=$?
check "код возврата 0" "0" "$rc1"
check "конфиг node_exporter на месте" "yes" "$([ -f "$ETC1/conf.d/node_exporter-loc" ] && echo yes || echo no)"
check "конфиг smartctl на месте"      "yes" "$([ -f "$ETC1/conf.d/smartctl_exporter-loc" ] && echo yes || echo no)"
check "конфиг zfs на месте"           "yes" "$([ -f "$ETC1/conf.d/zfs_exporter-loc" ] && echo yes || echo no)"
check "конфиг vector на месте"        "yes" "$([ -f "$ETC1/vector-loc/vector.yaml" ] && echo yes || echo no)"
check "содержимое совпадает с репо"  "same" "$(cmp -s "$SRC/node/vector/vector.yaml" "$ETC1/vector-loc/vector.yaml" && echo same || echo diff)"
has    "источник привязан к сегменту" "172.26.50.1:9100" "$ETC1/conf.d/node_exporter-loc"
nothas "в аргументах нет 0.0.0.0"      "--web.listen-address=0.0.0.0" "$ETC1/conf.d/node_exporter-loc"
has    "node перезапущен (конфиг новый)" "SYSTEMCTL: restart node_exporter-loc" "$W/sc.log"
has    "vector перезапущен"              "SYSTEMCTL: restart vector-loc"        "$W/sc.log"
nothas "enable не вызывается"           "SYSTEMCTL: enable" "$W/sc.log"
check "pacman не вызывался" "no" "$([ -s "$W/pc.log" ] && echo yes || echo no)"
has    "приёмка прошла" "приёмка: три источника слушают только 172.26.50.1" "$W/run1"
has    "шаг записан в отчёт контура" "$(printf 'узел\tконфиги\tok')" "$W/state/status"

say "2. повторный прогон: файлы не переписываются, юниты не перезапускаются"
rm -f "$W/sc.log"
apply "$ETC1" "$W/run2"
check "код возврата 0" "0" "$?"
nothas "перезаписи конфигов нет" "конфиг обновлён" "$W/run2"
nothas "перезапусков нет"        "SYSTEMCTL: restart" "$W/sc.log"

say "3. изменился один конфиг → перезапускается только его юнит"
sed -i 's/9134/9135/' "$ETC1/conf.d/zfs_exporter-loc"     # намеренная порча: файл разошёлся с репо
rm -f "$W/sc.log"
apply "$ETC1" "$W/run3"
has    "конфиг zfs восстановлен"  "конфиг обновлён: $ETC1/conf.d/zfs_exporter-loc" "$W/run3"
has    "zfs перезапущен"          "SYSTEMCTL: restart zfs_exporter-loc" "$W/sc.log"
nothas "node_exporter не тронут"  "SYSTEMCTL: restart node_exporter-loc" "$W/sc.log"
nothas "vector не тронут"         "SYSTEMCTL: restart vector-loc" "$W/sc.log"

say "4. приёмка падает, если источник слушает всё (не только сегмент)"
cp "$W/ss.leak" "$W/ss.out"
apply "$ETC1" "$W/run4"; rc4=$?
check "код возврата не 0"      "1" "$rc4"
has   "сказано про ожидание"   "ОШИБКА: ждал три источника на 172.26.50.1" "$W/run4"
has   "названа причина"        "источник виден из других сегментов"        "$W/run4"
has   "провал назван"          "конфиги узла: провал"                     "$W/run4"
has   "провал записан в отчёт" "$(printf 'узел\tконфиги\tпровал')"        "$W/state/status"
cp "$W/ss.ok" "$W/ss.out"

say "5. выключатель автоматики: только отчёт"
ETC5="$W/etc5"; : > "$W/off.flag"
apply "$ETC5" "$W/run5"
check "код возврата 0" "0" "$?"
has    "сказано про флаг"    "АВТОМАТИКА ОТКЛЮЧЕНА" "$W/run5"
has    "пропуск записан в отчёт" "$(printf 'узел\tконфиги\tпропуск')" "$W/state/status"
nothas "файлы не разложены"  "конфиг обновлён"      "$W/run5"
check "каталога не появилось" "no" "$([ -f "$ETC5/conf.d/node_exporter-loc" ] && echo yes || echo no)"
rm -f "$W/off.flag"

say "6. бинарника нет → провал с готовой командой, и НИКАКОЙ установки"
rm -f "$BIN/zfs_exporter-loc" "$W/pc.log"
apply "$W/etc6" "$W/run6"; rc6=$?
check "код возврата не 0"           "1" "$rc6"
has   "сказано, что пакет не наш"   "ОШИБКА: нет бинарника zfs_exporter-loc — пакет ставит владелец узла" "$W/run6"
check "pacman так и не позвали" "no" "$([ -s "$W/pc.log" ] && echo yes || echo no)"
printf '#!/bin/sh\nexit 0\n' > "$BIN/zfs_exporter-loc"; chmod +x "$BIN/zfs_exporter-loc"

say "7. юнит не активен → конфиг разложен, но провал с адресной командой"
echo node_exporter-loc > "$W/inactive"
apply "$W/etc7" "$W/run7"; rc7=$?
check "код возврата не 0"             "1" "$rc7"
has   "сказано, что применять некому" "ОШИБКА: юнит node_exporter-loc не активен" "$W/run7"
has   "названа команда запуска"       "systemctl start node_exporter-loc"         "$W/run7"
: > "$W/inactive"

say "8. юнит не включён → предупреждение о перезагрузке, прогон не падает"
echo vector-loc > "$W/disabled"
apply "$W/etc8" "$W/run8"; rc8=$?
check "код возврата 0" "0" "$rc8"
has   "предупреждение о включении" "ВНИМАНИЕ: юнит vector-loc не включён" "$W/run8"
: > "$W/disabled"

summary
