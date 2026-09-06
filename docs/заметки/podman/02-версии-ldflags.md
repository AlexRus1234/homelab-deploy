# Заметка: версии в ldflags у Go-образов (кейс memos/mortis)

## Симптом

MoeMemos (F-Droid, Android) отказывался логиниться на `apimemos.alexrus1234.ru` (мост mortis → memos на ВМ obshaga) с алертом
«Unsupported Memos version: поддерживаются 0.21.0 и 0.27.0–0.29.0», а веб-UI memos показывал версию `dev`.

## Причина

Пайплайн `Build and Push Memos` не передавал `--build-arg VERSION/COMMIT` в `podman build`.
В `memos/Containerfile` их дефолты `dev/unknown` → ldflags `-X ...version.Version` оставались пустыми → мемос рапортовал `version:"dev"` в `/api/v1/instance/profile`, а mortis пересылает это в старый API `/api/v1/status`.

Логика клиента (`evaluateMemosVersionCompatibility`): непарсируемая semver-строка («dev», «canary») → `.unsupported`.
У v0-ветки (старый API через mortis) есть только **нижний** порог `≥0.21.0`, верхней нет — поэтому любая честная версия проходит, а «dev» нет. Диапазон `0.27.0–0.29.0` — только для ветки v1 (прямое общение с memos мимо моста).

## Решение

**Только CI, без правок исходников приложений** (коммит `6daf54a` в container-build):
`Build and Push Memos` теперь передаёт `--build-arg VERSION=$VERSION --build-arg COMMIT=<sha7>`.

## Восстановление (один раз, было выполнено вручную)

1. Forgejo: `Build → Packages → memos → <битая версия> → Delete package` (иначе шаг «Check if version already exists» пропустит пересборку).
2. Запуск `Build and Push Memos` с `memos_version=latest` (авто-резолв последнего стабильного тега).
3. Любой push в `homelab-deploy` → webhook → `sync-state.sh` → `podman auto-update` тянет новый `:latest` и перезапускает контейнер (данные на volume не затрагиваются).

## Проверка

```bash
curl http://172.20.5.17:10004/api/v1/instance/profile   # "version":"v0.30.0","commit":"xxxxxxx"
curl http://172.20.5.17:10005/api/v1/status             # mortis релей
curl https://apimemos.alexrus1234.ru/api/v1/status      # снаружи
```
