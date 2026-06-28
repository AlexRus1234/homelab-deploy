#!/bin/bash
echo "=== Начинаем синхронизацию GitOps ==="
cd /opt/appdata/git-repo

OLD_HASH=$(git rev-parse HEAD)
git pull origin main
NEW_HASH=$(git rev-parse HEAD)

if git diff --quiet $OLD_HASH $NEW_HASH -- servers/yadr00/obshaga/; then
    echo "Изменений не найдено. Завершаем работу."
    podman auto-update
    exit 0
fi

echo "Найдены изменения! Применяем..."

# 1. Очистка мертвых служб (ДО синхронизации и daemon-reload!)
DELETED_FILES=$(git diff --name-only --diff-filter=D $OLD_HASH $NEW_HASH -- servers/yadr00/obshaga/quadlets/)
for file in $DELETED_FILES; do
    if [[ "$file" == *.container ]]; then
        service_name=$(basename "$file" .container)
        echo "Останавливаем удаленную службу: $service_name"
        systemctl --user stop "$service_name" 2>/dev/null || true
    fi
done

# 2. Синхронизируем Quadlets (заменили -a на -rlptD)
rsync -rlptD --delete servers/yadr00/obshaga/quadlets/ ~/.config/containers/systemd/

# 3. Синхронизируем конфиги приложений (заменили -a на -rlptD)
rsync -rlptD servers/yadr00/obshaga/app-configs/ /opt/appdata/config/

# 4. Перечитываем демоны
systemctl --user daemon-reload

# 5. Подтягиваем новые образы
podman auto-update

# 6. Перезапускаем все активные .container службы
echo "Перезапускаем активные службы..."
for file in ~/.config/containers/systemd/*.container; do
    if [ -f "$file" ]; then
        service_name=$(basename "$file" .container)
        echo "Перезапуск: $service_name"
        systemctl --user restart "$service_name"
    fi
done

echo "=== Синхронизация завершена ==="
