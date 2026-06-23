#!/bin/bash
# Переходим в репозиторий и подтягиваем изменения
cd /opt/appdata/git-repo
git pull origin main

# Копируем Quadlets-файлы
cp -r servers/yadr00/obshaga/quadlets/* ~/.config/containers/systemd/

# Копируем конфиги приложений (без перезаписи существующих локальных .env)
cp -rn servers/yadr00/obshaga/app-configs/* /opt/appdata/config/ 2>/dev/null || true

# Перезагружаем генератор Quadlets
systemctl --user daemon-reload

# Podman проверяет обновления образов
podman auto-update

# Применяем новые конфиги
for file in ~/.config/containers/systemd/*.container; do
    service_name=$(basename "$file" .container)
    systemctl --user restart "$service_name"
done
