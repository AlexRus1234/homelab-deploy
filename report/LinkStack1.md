

# Архитектура и развертывание LinkStack в суверенном дата-центре (Rootless Podman + GitOps)

## 1. Введение и Архитектурные принципы
**Цель:** Развернуть приложение LinkStack (PHP/Laravel + Apache) в полностью изолированной среде Rootless Podman, управляемой через Systemd Quadlets (GitOps-модель), с соблюдением принципов суверенного дата-центра (независимость от внешнего интернета после сборки).

**Базовые требования к инфраструктуре:**
*   **Безопасность:** Контейнер запускается от обычного системного пользователя (`app-runner`).
*   **Stateless ОС:** Конфигурации и базы данных вынесены на отдельный виртуальный диск (`/opt/appdata`). Сама ВМ является расходным материалом.
*   **Изоляция сети:** Приложение не должно управлять SSL-сертификатами. Внутри контейнера используется только HTTP (порт 80), HTTPS терминируется внешним прокси-сервером (Caddy).

## 2. Анализ официального образа и проблематика
При попытке использования официального образа `linkstackorg/linkstack` в Rootless-среде были выявлены фундаментальные архитектурные изъяны:
1.  **Зависимость от внешнего состояния (Stateful init):** Официальный `docker-entrypoint.sh` пытается "на лету" скопировать `.env.example`, сгенерировать `APP_KEY` и выполнить миграции базы данных при каждом чистом старте. Это создает состояние "гонки" и делает запуск непредсказуемым.
2.  **Ошибка `BindingResolutionException` (Target class [] does not exist):** В официальном `composer.json` отсутствует зависимость для кастомного middleware `Impersonate`. При пересборке кэша Laravel в процессе инициализации фреймворк не находит этот класс и падает с ошибкой 500 после успешной авторизации.
3.  **Привилегированные порты в Rootless:** Внутри контейнера процесс запускается от пользователя `apache` (UID 100). Ядро Linux запрещает ему открывать порт 80, что приводит к ошибке `make_sock: could not bind to address [::]:80`.
4.  **Права доступа (UID/GID Mapping):** При использовании обычного *Bind Mount* файлы на хосте получают UID `165635` (subuid пользователя), что делает невозможным их чтение и резервное копирование без прав `root`.

---

## 3. Решение: Фабрика сборок (CI Pipeline & Containerfile)
Вместо использования готовых архивов (ZIP-релизов), образ собирается из исходного кода в локальном реестре пакетов Forgejo с использованием **Multi-stage build**.

### Идеальный `Containerfile`
Ключевые исправления на этапе сборки:
*   Внедрение доверия к локальному УЦ (`step-ca.crt`).
*   **Pre-bake базы данных:** Инициализация SQLite, генерация `APP_KEY` и выполнение миграций (`artisan migrate/seed`) происходят прямо во время сборки. Образ получается "запечатанным" и готовым к работе.
*   **Хирургическое удаление бага Impersonate:** Проблемный класс перекрывается пустой PHP-заглушкой (`stub`), что позволяет фреймворку успешно загружать роуты без паники.
*   **Очистка кэша:** Принудительное выполнение `php artisan optimize:clear`, чтобы зафиксировать правильные абсолютные пути (`/htdocs`).

```dockerfile
# === ЭТАП 1: Сборка зависимостей и инициализация Laravel ===
FROM docker.io/library/composer:2.7 AS builder
WORKDIR /htdocs

COPY ./linkstack /htdocs/
COPY ./step-ca.crt /usr/local/share/ca-certificates/step-ca.crt
RUN update-ca-certificates

# Скачиваем ВСЕ PHP-зависимости
RUN composer install --optimize-autoloader --ignore-platform-reqs

# Устанавливаем sqlite для выполнения миграций
RUN apk add --no-cache sqlite

# Подготавливаем .env файл для локальной базы
RUN cp .env.example .env && \
    sed -i 's/DB_CONNECTION=mysql/DB_CONNECTION=sqlite/g' .env && \
    sed -i 's/DB_DATABASE=linkstack/DB_DATABASE=\/htdocs\/database\/database.sqlite/g' .env

# Pre-bake БД: создаем таблицы, ключи и данные
RUN touch database/database.sqlite && \
    php artisan key:generate && \
    php artisan migrate --force && \
    php artisan db:seed --force && \
    php artisan db:seed --class="PageSeeder" --force && \
    php artisan db:seed --class="ButtonSeeder" --force && \
    echo "." > storage/app/ISINSTALLED

# Заглушка для сломанного Middleware Impersonate
RUN echo '<?php namespace App\Http\Middleware; use Closure; class Impersonate { public function handle($request, Closure $next) { return $next($request); } }' > app/Http/Middleware/Impersonate.php

# Очищаем кеши Laravel
RUN php artisan optimize:clear


# === ЭТАП 2: Упаковка финального образа ===
FROM docker.io/library/alpine:3.23.2

EXPOSE 80 443

RUN apk --no-cache --update \
    add apache2 apache2-ssl curl \
    php83-apache2 php83-bcmath php83-bz2 php83-calendar php83-common \
    php83-ctype php83-curl php83-dom php83-fileinfo php83-gd \
    php83-iconv php83-json php83-mbstring php83-mysqli php83-mysqlnd \
    php83-openssl php83-pdo_mysql php83-pdo_pgsql php83-pdo_sqlite \
    php83-phar php83-session php83-xml php83-tokenizer php83-zip \
    php83-xmlwriter php83-redis tzdata \
    && mkdir /htdocs

RUN ln -s /usr/bin/php83 /usr/bin/php

# Копируем готовое приложение
COPY --from=builder /htdocs /htdocs
COPY ./configs/apache2/httpd.conf /etc/apache2/httpd.conf
COPY ./configs/apache2/ssl.conf /etc/apache2/conf.d/ssl.conf
COPY ./configs/php/php.ini /etc/php83/conf.d/40-custom.ini
COPY --chmod=0755 ./docker-entrypoint.sh /usr/local/bin/

RUN chown apache:apache /etc/ssl/apache2/server.pem && \
    chown apache:apache /etc/ssl/apache2/server.key && \
    chown -R apache:apache /htdocs && \
    find /htdocs -type d -print0 | xargs -0 chmod 0755 && \
    find /htdocs -type f -print0 | xargs -0 chmod 0644 && \
    chmod -R 755 /etc/php83 && \
    chown -R apache:apache /etc/php83

USER apache:apache
HEALTHCHECK CMD curl -f http://localhost -A "HealthCheck" || exit 1
WORKDIR /htdocs
CMD ["docker-entrypoint.sh"]
```

---

## 4. Развертывание (GitOps & Quadlets)
Для развертывания используется подход Bind Mount в сочетании с технологией **User Namespace Mapping (`keep-id`)**.

### Первичная инициализация данных на хосте
Так как Podman не копирует данные из образа в обычный `bind-mount`, перед первым запуском необходимо "наполнить" директорию на хосте данными из собранного образа.

Выполняется от имени пользователя `app-runner`:
```bash
# Создание директории
install -d -m 0755 /opt/appdata/db/linkstack

# Экстракция данных из образа с пробросом UID/GID
podman run --rm \
  -v /opt/appdata/db/linkstack:/target \
  --userns=keep-id:uid=100,gid=101 \
  git.yadr00.internal/build/linkstack:latest sh -c 'cp -a /htdocs/. /target/'
```
*Результат:* Все файлы на хосте имеют владельца `app-runner:app-runner`, но внутри контейнера они будут видны как принадлежащие `apache:apache`.

### Конфигурация Quadlet (`03-linkstack.container`)
```ini
[Unit]
Description=LinkStack (Multi-link page)
After=network-online.target

[Container]
Image=git.yadr00.internal/build/linkstack:latest
AutoUpdate=registry

# Решение проблемы портов: Разрешаем UID 100 открывать порт 80
# ТОЛЬКО внутри сетевого пространства контейнера (не влияет на хост)
Sysctl=net.ipv4.ip_unprivileged_port_start=80
PublishPort=10002:80

# Маппинг пространств имен: Host User (app-runner) = Container User (apache, UID 100)
UserNS=keep-id:uid=100,gid=101

# Проброс файлов (Stateless-архитектура)
Volume=/opt/appdata/db/linkstack:/htdocs

[Install]
WantedBy=default.target
```

---

## 5. Резервное копирование и восстановление
Благодаря отказу от Именованных томов в пользу `Bind Mount + keep-id`, бэкап приложения стал тривиальной задачей.

*   **Резервное копирование:** Выполняется обычным копированием директории `/opt/appdata/db/linkstack` (или снапшотом ZFS всего диска). Файлы принадлежат локальному пользователю, `sudo` не требуется.
*   **Восстановление на новой ВМ:** Достаточно примонтировать диск `/opt/appdata` и выполнить `git pull` конфигураций (вебхук). Контейнер подхватит базу `database.sqlite` и загруженные медиафайлы без необходимости повторного выполнения инициализации (Шаг 4). 

**Итог:** Получено полностью детерминированное, безопасное и обновляемое приложение, лишенное конструктивных недостатков авторов фреймворка.