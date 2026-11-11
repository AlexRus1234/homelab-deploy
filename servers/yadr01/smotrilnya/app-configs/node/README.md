# Конфиги УРОВНЯ ХОСТА для smotrilnya — руками, не контуром.
#
# Почему не контуром: агент на ВМ работает от пользователя `app-runner`, а эти файлы
# живут в /etc и /etc/sysconfig. Rootless-агент туда писать не может, sudo у него нет,
# и выдавать его — значит отдать агенту root на ВМ. Поэтому деплой только раскладывает
# файлы в /opt/appdata/config/node/ (rsync app-configs), а применение — шаг человека.
#
# Раскладка:
#   node_exporter-loc.conf            → /etc/sysconfig/node_exporter-loc
#   podman-exporter-args              → ~/.config/prometheus-podman-exporter-loc/args  (от app-runner)
#   vector-loc.yaml                   → /etc/vector-loc/vector.yaml
#
# Применение (руками, от root):
#   install -m 0644 /opt/appdata/config/node/node_exporter-loc.conf /etc/sysconfig/node_exporter-loc
#   systemctl enable --now node_exporter-loc
#
#   install -m 0644 /opt/appdata/config/node/vector-loc.yaml /etc/vector-loc/vector.yaml
#   systemctl enable --now vector-loc
#
# Ни один из юнитов не включается скриптлетами пакета (в них только sysusers и tmpfiles) —
# enable делается здесь.
#
# Для podman-exporter (user-юнит, от app-runner):
#   install -D -m 0644 /opt/appdata/config/node/podman-exporter-args \
#     ~app-runner/.config/prometheus-podman-exporter-loc/args
#   systemctl --user restart prometheus-podman-exporter-loc   # от имени app-runner
