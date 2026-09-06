#!/bin/bash
echo "=== Начинаем синхронизацию GitOps ==="
cd /opt/appdata/git-repo

# Игнорируем бит исполнения файлов — ручной chmod на ВМ не должен делать дерево "грязным" и блокировать pull
git config core.fileMode false

OLD_HASH=$(git rev-parse HEAD)

# git pull обязан пройти успешно, иначе состояние непредсказуемо — падаем громко (webhook вернёт 500)
if ! git pull origin main; then
    echo "ОШИБКА: git pull не удался. Синхронизация прервана." >&2
    exit 1
fi

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
if [ -d servers/yadr00/obshaga/app-configs ]; then
    rsync -rlptD servers/yadr00/obshaga/app-configs/ /opt/appdata/config/
else
    echo "Каталог app-configs отсутствует — пропуск шага rsync конфигов."
fi

# 4. Перечитываем демоны
systemctl --user daemon-reload

# 5. Подтягиваем новые образы
podman auto-update

# 6. Перезапуск служб: точечно по изменённым Quadlets, либо всех при FORCE_FULL_RESTART=1
if [ "${FORCE_FULL_RESTART:-0}" = "1" ]; then
    echo "FORCE_FULL_RESTART=1 — перезапускаем ВСЕ .container службы..."
    for file in ~/.config/containers/systemd/*.container; do
        if [ -f "$file" ]; then
            service_name=$(basename "$file" .container)
            echo "Перезапуск: $service_name"
            systemctl --user restart "$service_name" 2>/dev/null || true
        fi
    done
else
    CHANGED_FILES=$(git diff --name-only --diff-filter=AM $OLD_HASH $NEW_HASH -- servers/yadr00/obshaga/quadlets/ | grep '\.container$' || true)
    if [ -z "$CHANGED_FILES" ]; then
        echo "Изменённых Quadlet-служб нет — перезапуск не требуется."
    else
        for file in $CHANGED_FILES; do
            service_name=$(basename "$file" .container)
            echo "Точечный перезапуск: $service_name"
            systemctl --user restart "$service_name" 2>/dev/null || true
        done
    fi
fi

echo "=== Синхронизация завершена ==="
