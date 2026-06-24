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

# 1. Синхронизируем Quadlets (Удаляем старые, добавляем новые, сохраняем точную копию Git)
echo "Синхронизируем файлы Systemd (Quadlets)..."
rsync -a --delete servers/yadr00/obshaga/quadlets/ ~/.config/containers/systemd/

# 2. Синхронизируем конфиги приложений (Создаем папки, но НЕ УДАЛЯЕМ локальные .env файлы)
# Здесь мы НЕ используем --delete, так как в /opt/appdata/config/ могут лежать реальные .env с паролями, которых нет в Git!
echo "Синхронизируем конфигурации приложений..."
rsync -a servers/yadr00/obshaga/app-configs/ /opt/appdata/config/

# 3. Перезагружаем генератор Quadlets
echo "Перечитываем демоны..."
systemctl --user daemon-reload

# 4. Подтягиваем новые образы
echo "Проверяем обновления контейнеров..."
podman auto-update

# 5. Перезапускаем только измененные службы
CHANGED_FILES=$(git diff --name-only $OLD_HASH $NEW_HASH -- servers/yadr00/obshaga/quadlets/)

for file in $CHANGED_FILES; do
    if [[ "$file" == *.container ]]; then
        service_name=$(basename "$file" .container)
        echo "Перезапускаем службу: $service_name"
        systemctl --user restart "$service_name"
    fi
done

# 6. Очистка мертвых служб (Если вы УДАЛИЛИ или ПЕРЕИМЕНОВАЛИ .container файл в Git)
DELETED_FILES=$(git diff --name-only --diff-filter=D $OLD_HASH $NEW_HASH -- servers/yadr00/obshaga/quadlets/)
for file in $DELETED_FILES; do
    if [[ "$file" == *.container ]]; then
        service_name=$(basename "$file" .container)
        echo "Останавливаем удаленную службу: $service_name"
        systemctl --user stop "$service_name" 2>/dev/null || true
    fi
done

echo "=== Синхронизация завершена ==="
