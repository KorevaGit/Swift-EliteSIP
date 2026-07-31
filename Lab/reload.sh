#!/bin/bash
# Раскладывает изменённые конфиги в контейнер и перечитывает их без перезапуска.
#
# Без этого шага правки в Lab/asterisk/config/ не видны: в /etc/asterisk файлы
# попадают копированием при старте (см. entrypoint.sh и комментарий в
# docker-compose.yml).
set -euo pipefail

CONTAINER=elitesip-lab13

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "Контейнер $CONTAINER не запущен. Сначала: ./lab.sh up" >&2
  exit 1
fi

# Тот же адрес, что подставляет lab.sh при запуске: сеть могла смениться и
# между запусками, а перечитывание конфигов — как раз тот момент, когда это
# замечают. Симптом старого адреса — установленный звонок без звука.
address="$(ipconfig getifaddr en0 2>/dev/null || true)"
if [ -n "$address" ]; then
  sed -i '' -E "s/^externaddr=.*/externaddr=$address/" asterisk/config/sip.conf
fi

docker exec "$CONTAINER" sh -c 'cp -f /etc/asterisk-elitesip/*.conf /etc/asterisk/'

# core reload перечитывает разом диалплан, sip.conf, features и confbridge.
docker exec "$CONTAINER" asterisk -rx 'core reload' > /dev/null

echo "Конфиги обновлены. Текущие фич-коды:"
docker exec "$CONTAINER" asterisk -rx 'features show' | sed -n '1,20p'
