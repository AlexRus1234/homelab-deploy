#!/bin/bash
# Приведение инстансов Incus на skld00 к декларациям `services/*.yaml`.
#
# Вызывается из `sync-state.sh` (аргументы — старый и новый git-хеш) и вручную.
#
# ШАГ 1 (сейчас): скрипт только перечисляет декларации и проверяет окружение.
# ШАГ 2 (следующий): создание отсутствующих инстансов, применение изменений
#                    (`incus config set` для применяемого живьём, recreate для состава,
#                    тома данных на датасеты), затем health-gate. См. `актуальная схема.md`
#                    в репозитории образов (`lxc-build`).
set -uo pipefail

REPO_DIR=${REPO_DIR:-/opt/appdata/git-repo}
SUB="$REPO_DIR/servers/skld00"
BASE_ALIAS=${BASE_ALIAS:-leap16-base}
STORE_REMOTE=${STORE_REMOTE:-skld00}

echo "=== reconcile: ${1:-нет} -> ${2:-нет}"

# окружение: incus доступен агенту (пользователь должен быть в группе incus-admin)
if ! command -v incus-loc >/dev/null 2>&1; then
    echo "ОШИБКА: нет incus-loc — агент запускается не на узле Incus" >&2
    exit 1
fi
echo "--- инстансы сейчас:"
incus-loc list -c ns4t || true
echo "--- базовый образ на складе ($STORE_REMOTE:$BASE_ALIAS):"
incus-loc image info "$STORE_REMOTE:$BASE_ALIAS" 2>/dev/null | sed -n '1,6p' || echo "база не найдена"

shopt -s nullglob
files=("$SUB"/services/*.yaml)
if [ ${#files[@]} -eq 0 ]; then
    echo "=== деклараций нет (services/*.yaml) — делать нечего"
    exit 0
fi

for f in "${files[@]}"; do
    name=$(basename "$f" .yaml)
    echo "--- декларация: $name"
    if incus-loc info "$name" >/dev/null 2>&1; then
        echo "    инстанс есть (шаг 2: решить, применять живьём или пересоздавать)"
    else
        echo "    инстанса нет (шаг 2: incus-loc launch $STORE_REMOTE:$BASE_ALIAS $name < $f)"
    fi
done

echo "=== reconcile завершён (режим перечисления, шаг 1)"
