#!/bin/bash
echo "=== Начинаем синхронизацию GitOps ==="
cd /opt/appdata/git-repo

OLD_HASH=$(git rev-parse HEAD)

git pull origin main

NEW_HASH=$(git rev-parse HEAD)

if git diff --quiet $OLD_HASH $NEW_HASH -- servers/yadr00/obshaga/; then
    echo "Изменений для ВМ 'Общежитие' не найдено. Завершаем работу."
    podman auto-update
    exit 0
fi

echo "Найдены изменения конфигурации! Применяем..."

cp -r servers/yadr00/obshaga/quadlets/* ~/.config/containers/systemd/

cp -rn servers/yadr00/obshaga/app-configs/* /opt/appdata/config/ 2>/dev/null || true

systemctl --user daemon-reload

podman auto-update

CHANGED_FILES=$(git diff --name-only $OLD_HASH $NEW_HASH -- servers/yadr00/obshaga/quadlets/)

for file in $CHANGED_FILES; do
    if [[ "$file" == *.container ]]; then
        service_name=$(basename "$file" .container)
        echo "Перезапускаем службу: $service_name"
        systemctl --user restart "$service_name"
    fi
done

echo "=== Синхронизация завершена ==="
