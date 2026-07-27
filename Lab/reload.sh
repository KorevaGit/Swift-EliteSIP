#!/bin/bash
# Раскладывает изменённые конфиги в контейнер и перечитывает их без перезапуска.
#
# Без этого шага правки в Lab/asterisk/config/ не видны: в /etc/asterisk файлы
# попадают копированием при старте (см. entrypoint.sh и комментарий в
# docker-compose.yml).
set -euo pipefail

CONTAINER=elitesip-lab

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "Контейнер $CONTAINER не запущен. Сначала: docker compose up -d" >&2
  exit 1
fi

docker exec "$CONTAINER" sh -c 'cp -f /etc/asterisk-elitesip/*.conf /etc/asterisk/'

# core reload перечитывает разом диалплан, sip.conf, features и confbridge.
docker exec "$CONTAINER" asterisk -rx 'core reload' > /dev/null

echo "Конфиги обновлены. Текущие фич-коды:"
docker exec "$CONTAINER" asterisk -rx 'features show' | sed -n '1,20p'
