#!/bin/bash
# GitOps-агент узла skld00 (Incus-инстансы).
#
# Модель — как у ВМ (`servers/yadr00/obshaga/sync-state.sh`): webhook принимает POST
# от Forgejo, проверяет HMAC, запускает этот скрипт; скрипт делает `git pull` в
# sparse-checkout узла и применяет изменения. Отличие одно: применяет не rootless
# Podman, а Incus — поэтому дальше вызывается `reconcile.sh` (см. рядом).
#
# Запуск webhook'ом: command-working-directory = /opt/appdata, execute-command =
# /opt/appdata/git-repo/servers/skld00/sync-state.sh
set -uo pipefail

REPO_DIR=${REPO_DIR:-/opt/appdata/git-repo}
SUBTREE=servers/skld00

cd "$REPO_DIR" || { echo "ОШИБКА: нет каталога $REPO_DIR" >&2; exit 1; }

# Ручной chmod на узле не должен делать дерево «грязным» и блокировать pull
git config core.fileMode false

OLD_HASH=$(git rev-parse HEAD)

# pull обязан пройти: при ошибке падаем громко, webhook вернёт 500 и сбой будет
# виден в логах Forgejo (та же логика, что на ВМ)
if ! git pull origin main; then
    echo "ОШИБКА: git pull не удался. Синхронизация прервана." >&2
    exit 1
fi

NEW_HASH=$(git rev-parse HEAD)

if git diff --quiet "$OLD_HASH" "$NEW_HASH" -- "$SUBTREE/"; then
    echo "Изменений в $SUBTREE нет — делать нечего."
    exit 0
fi

echo "=== Изменения в $SUBTREE: $OLD_HASH -> $NEW_HASH"
echo "--- изменённые файлы:"
git diff --name-status "$OLD_HASH" "$NEW_HASH" -- "$SUBTREE/"

# Дальше — хостовый контур. Запускаем через /bin/bash явно: агент не должен зависеть
# от бита исполняемости в репозитории (у моего git core.fileMode=false, и +x легко
# не попадает в коммит — на узле это давало «Permission denied» и 500 от webhook).
exec /bin/bash "$REPO_DIR/$SUBTREE/reconcile.sh" "$OLD_HASH" "$NEW_HASH"
