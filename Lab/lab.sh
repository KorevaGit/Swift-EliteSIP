#!/bin/bash
# Запуск и остановка учебного стенда FreePBX.
#
#   ./lab.sh up       — поднять стенд (первый запуск — несколько минут)
#   ./lab.sh status   — что запущено и куда подключать клиентов
#   ./lab.sh sync     — перечитать адрес Mac в сети без пересоздания контейнера
#   ./lab.sh cli      — живая консоль Asterisk (asterisk -rvvv)
#   ./lab.sh down     — остановить, тома сохранить
#   ./lab.sh down-all — остановить и стереть тома (сброс к чистому)
#
# 31 июля 2026 отдельные стенды на голом Asterisk 13 и 16 убраны. FreePBX стал
# единственным стендом — и для отладки клиента, и для того, чтобы понимать
# устройство боевого сервера. Разбор решения и того, что при этом перенесено, —
# Lab/README.md.
set -euo pipefail

cd "$(dirname "$0")"

FREEPBX="docker-compose.freepbx.yml"
CONTAINER="elitesip-freepbx"
BASE_IMAGE="elitesip-asterisk13:13.38.3"

section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

ensure_docker() {
  if docker info >/dev/null 2>&1; then return; fi

  echo "Docker не запущен, запускаю Docker Desktop…"
  open -a Docker
  for _ in $(seq 1 60); do
    docker info >/dev/null 2>&1 && { echo "Docker поднялся."; return; }
    sleep 5
  done
  echo "Docker так и не поднялся. Запустите Docker Desktop вручную." >&2
  exit 1
}

# freepbx/Dockerfile собирается `FROM elitesip-asterisk13:13.38.3` — это не
# отдельный стенд, а только база, которую строит asterisk13/Dockerfile. Своего
# compose-сервиса у неё больше нет, поэтому собрать её надо явно, до сборки
# FreePBX. Слои кэшируются, поэтому при повторных запусках это доли секунды.
ensure_base_image() {
  docker build -q -t "$BASE_IMAGE" ./asterisk13 >/dev/null
}

running() {
  docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"
}

current_address() {
  ipconfig getifaddr en0 2>/dev/null || true
}

# Синхронизирует внешний адрес Mac в уже запущенный контейнер без пересоздания.
#
# FreePBX получает externip через переменную окружения при создании контейнера,
# а docker не даёт поменять окружение уже созданного контейнера — только
# пересоздать его целиком, а это дороже: fwconsole поднимает Asterisk заново.
# Быстрее и надёжнее — исправить уже развёрнутый файл и перечитать конфиг,
# тем же способом, что раньше делал отдельный reload.sh для голого Asterisk.
sync_address() {
  local address
  address="$(current_address)"
  if [ -z "$address" ]; then
    # Не «оставляю как есть» молча: остаётся при этом 127.0.0.1, с которым
    # телефон будет слать RTP себе в петлю (см. check_external_address).
    echo "Адрес en0 не определён — в SDP останется прежний адрес." >&2
    echo "Если это 127.0.0.1, с телефона звука не будет: ./lab.sh status покажет." >&2
    return
  fi

  docker exec "$CONTAINER" sh -c \
    "sed -i -E 's/^externip=.*/externip=$address/' /etc/asterisk/sip_general_m1_6.conf" \
    2>/dev/null || return
  docker exec "$CONTAINER" asterisk -rx 'sip reload' >/dev/null 2>&1 || true
  echo "externip: $address"
}

# Проверяет, годится ли адрес, который Asterisk кладёт в SDP, для телефона.
#
# Ловушка стоит дорого и молчит. Свежесозданный контейнер получает
# externip=127.0.0.1 (см. FREEPBX_EXTERNAL_ADDRESS в compose), а localnet —
# только 127.0.0.0/8. Значит всем, кто пришёл не с петли, Asterisk объявляет в
# SDP «шлите медиа на 127.0.0.1».
#
# Для клиента на этом же Mac это случайно работает: 127.0.0.1:1020x — как раз
# опубликованный порт контейнера. Для телефона 127.0.0.1 — это сам телефон, и
# он шлёт RTP себе в петлю. Asterisk не получает от него ничего, и разговор
# выходит односторонним: телефон нас слышит, мы его — нет.
#
# Отличить это по симптому почти невозможно: со стороны Mac всё выглядит
# исправным. Поэтому проверка встроена в `status` — 3 августа 2026 на разбор
# этого ушло два захода.
check_external_address() {
  local configured expected
  configured="$(docker exec "$CONTAINER" \
    sh -c "sed -nE 's/^externip=(.*)/\1/p' /etc/asterisk/sip_general_m1_6.conf" 2>/dev/null | tr -d '\r')"
  expected="$(current_address)"

  printf '  в конфиге: %s\n' "${configured:-—}"
  printf '  адрес Mac: %s\n' "${expected:-— (en0 не определён)}"

  if [ -z "$configured" ]; then
    echo "  ⚠️  externip не прочитался — стенд поднят не через ./lab.sh up?"
  elif [ "$configured" = "127.0.0.1" ] && [ -n "$expected" ]; then
    echo "  ⚠️  ПЕТЛЯ: телефону в SDP уедет 127.0.0.1, он будет слать RTP сам себе."
    echo "      Со стороны Mac всё выглядит исправным — звука не будет только с телефона."
    echo "      Лечится: ./lab.sh sync"
  elif [ -n "$expected" ] && [ "$configured" != "$expected" ]; then
    echo "  ⚠️  адрес разъехался (сеть сменилась?). Лечится: ./lab.sh sync"
  else
    echo "  ок"
  fi
}

status() {
  section "Контейнер"
  docker ps -a --format '  {{.Names}}\t{{.Status}}' | grep elitesip || echo "  (не запущен)"

  if running; then
    section "Адрес в SDP (externip)"
    check_external_address

    section "Пиры"
    docker exec "$CONTAINER" asterisk -rx 'sip show peers' 2>/dev/null | sed 's/^/  /' || true

    section "Очередь раздачи 2929"
    docker exec "$CONTAINER" asterisk -rx 'queue show 2929' 2>/dev/null | head -1 | sed 's/^/  /' || true

    section "Веб"
    printf '  http://localhost:8080  (HTTP %s)\n' \
      "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/admin/config.php || echo '—')"
  fi

  section "Куда подключать клиентов"
  local address
  address="$(current_address)"
  cat <<INFO
  с этого Mac:   127.0.0.1  порт 5060 (UDP) / 5061 (TLS)
  с телефона:    ${address:-адрес не определён}  порт 5060 (UDP) / 5061 (TLS)
  номера:        100/elite100 … 103/elite103, 200/elite200 (TLS+SRTP)
  тестовые цели: 650 эхо, 601 плейбек, 602 тон, 603 DTMF, 8000 конференция
  подробнее:     Lab/CLIENTS.md
INFO
}

case "${1:-up}" in

up)
  ensure_docker
  ./certs/generate.sh >/dev/null 2>&1 || true
  ensure_base_image

  echo "Запускаю FreePBX (первый запуск на чистом томе — несколько минут)…"
  docker compose -f "$FREEPBX" up -d

  echo "Жду готовности…"
  for _ in $(seq 1 90); do
    [ "$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null)" = "healthy" ] && break
    sleep 3
  done

  sync_address
  status
  ;;

status)
  ensure_docker
  status
  ;;

sync)
  ensure_docker
  if ! running; then
    echo "$CONTAINER не запущен. Сначала: ./lab.sh up" >&2
    exit 1
  fi
  sync_address
  ;;

cli)
  ensure_docker
  if ! running; then
    echo "$CONTAINER не запущен. Сначала: ./lab.sh up" >&2
    exit 1
  fi
  # -it, а не -x: это интерактивная консоль (Ctrl+D или `quit` — выход из неё,
  # не из контейнера), а не разовая команда. `-vvv` — тот же уровень
  # подробности, что и у настоящего `asterisk -r` на живом сервере.
  exec docker exec -it "$CONTAINER" asterisk -rvvv
  ;;

down)
  docker compose -f "$FREEPBX" down 2>/dev/null || true
  echo "Остановлено, тома сохранены."
  ;;

down-all)
  docker compose -f "$FREEPBX" down -v 2>/dev/null || true
  echo "Остановлено, тома удалены — при следующем запуске стенд будет чистым."
  ;;

*)
  sed -n '2,10p' "$0" >&2
  exit 2
  ;;
esac
