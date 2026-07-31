#!/bin/bash
# Запуск и остановка лаборатории.
#
#   ./lab.sh up          — Asterisk 13.38.3 (боевая версия). Нужен для работы.
#   ./lab.sh up freepbx  — плюс учебный стенд FreePBX
#   ./lab.sh status      — что запущено и в каком состоянии
#   ./lab.sh cli         — живая консоль Asterisk внутри FreePBX (asterisk -rvvv)
#   ./lab.sh cli lab13   — то же самое, но у основной лабы
#   ./lab.sh down        — остановить всё
#   ./lab.sh down-all    — остановить и удалить тома FreePBX (сброс к чистому)
set -euo pipefail

cd "$(dirname "$0")"

PRIMARY="docker-compose.13.yml"
FREEPBX="docker-compose.freepbx.yml"
LEGACY16="docker-compose.yml"

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

status() {
  section "Контейнеры"
  docker ps -a --format '  {{.Names}}\t{{.Status}}' | grep elitesip || echo "  (ни одного)"

  if docker ps --format '{{.Names}}' | grep -qx elitesip-lab13; then
    section "Asterisk 13 — пиры"
    docker exec elitesip-lab13 asterisk -rx 'sip show peers' 2>/dev/null \
      | grep -E '^(100|101|102|200)|sip peers' | sed 's/^/  /' || true

    section "Asterisk 13 — активные звонки"
    docker exec elitesip-lab13 asterisk -rx 'core show channels' 2>/dev/null \
      | grep -E 'active' | sed 's/^/  /' || true
  fi

  if docker ps --format '{{.Names}}' | grep -qx elitesip-freepbx; then
    section "FreePBX"
    printf '  веб: http://localhost:8080  (HTTP %s)\n' \
      "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/admin/config.php || echo '—')"
  fi

  section "Куда подключать клиентов"
  local address
  address="$(ipconfig getifaddr en0 2>/dev/null || echo 'адрес не определён')"
  cat <<INFO
  с этого Mac:      127.0.0.1  порт 5060 (или 5070)
  с телефона:       $address  порт 5060 (или 5070)
  номера/пароли:    100/elite100, 101/elite101, 102/elite102
  эхо-тест:         600

  externaddr в sip.conf: $(current_externaddr)
INFO
}

current_externaddr() {
  sed -nE 's/^externaddr=(.*)$/\1/p' asterisk/config/sip.conf | head -1
}

# Подставляет текущий адрес Mac в externaddr.
#
# Раньше это была строчка в подсказке «поправьте руками». Руками её забывают, а
# симптом обманчивый: звонок устанавливается, ACK проходит, и только звука нет —
# в обе стороны. Asterisk ставит externaddr в SDP, и по старому адресу RTP
# уходит в никуда. Дважды на это наступили, поэтому теперь адрес берётся у
# системы при каждом запуске.
sync_externaddr() {
  local address current
  address="$(ipconfig getifaddr en0 2>/dev/null || true)"

  if [ -z "$address" ]; then
    echo "Адрес en0 не определён — externaddr оставлен как есть." >&2
    return
  fi

  current="$(current_externaddr)"
  [ "$current" = "$address" ] && return

  # BSD sed: -i требует суффикса, пустой означает «без резервной копии».
  sed -i '' -E "s/^externaddr=.*/externaddr=$address/" asterisk/config/sip.conf
  echo "externaddr: $current → $address"
}

case "${1:-up}" in

up)
  ensure_docker

  # Лаба на Asterisk 16 спорит с основной за RTP-порты: они публикуются один в
  # один, иначе медиа не доходит. Держим поднятой только одну.
  if docker ps --format '{{.Names}}' | grep -qx elitesip-lab; then
    echo "Останавливаю лабу на Asterisk 16 — спорит за RTP-порты."
    docker compose -f "$LEGACY16" down >/dev/null 2>&1 || true
  fi

  ./certs/generate.sh >/dev/null 2>&1 || true
  sync_externaddr

  echo "Запускаю Asterisk 13.38.3…"
  docker compose -f "$PRIMARY" up -d

  if [ "${2:-}" = "freepbx" ]; then
    echo "Запускаю FreePBX (поднимается около минуты)…"
    docker compose -f "$FREEPBX" up -d
  fi

  echo "Жду готовности…"
  for _ in $(seq 1 30); do
    docker exec elitesip-lab13 asterisk -rx 'core show version' >/dev/null 2>&1 && break
    sleep 2
  done

  status
  ;;

status)
  ensure_docker
  status
  ;;

cli)
  ensure_docker

  # По умолчанию FreePBX: команда добавлена именно ради него — у основной лабы
  # `docker exec elitesip-lab13 asterisk -rx '...'` уже используется везде
  # выше одноразовыми командами, а живая консоль (`-rvvv`, без `x`) нужна была
  # только внутри FreePBX, где диалплан и очереди генерирует не человек.
  case "${2:-freepbx}" in
    freepbx) container="elitesip-freepbx" ;;
    lab13|asterisk) container="elitesip-lab13" ;;
    *)
      echo "Неизвестная цель: ${2}. Ожидается freepbx или lab13." >&2
      exit 2
      ;;
  esac

  if ! docker ps --format '{{.Names}}' | grep -qx "$container"; then
    echo "$container не запущен. Сначала: ./lab.sh up${2:+ freepbx}" >&2
    exit 1
  fi

  # -it, а не -x: это интерактивная консоль (Ctrl+D или `quit` — выход из
  # неё, не из контейнера), а не разовая команда. `-vvv` — тот же уровень
  # подробности, что и у настоящего `asterisk -r` на живом сервере.
  exec docker exec -it "$container" asterisk -rvvv
  ;;

down)
  docker compose -f "$PRIMARY" down 2>/dev/null || true
  docker compose -f "$FREEPBX" down 2>/dev/null || true
  docker compose -f "$LEGACY16" down 2>/dev/null || true
  echo "Остановлено."
  ;;

down-all)
  docker compose -f "$PRIMARY" down 2>/dev/null || true
  docker compose -f "$FREEPBX" down -v 2>/dev/null || true
  docker compose -f "$LEGACY16" down 2>/dev/null || true
  echo "Остановлено, тома FreePBX удалены — при следующем запуске он будет чистым."
  ;;

*)
  sed -n '2,10p' "$0" >&2
  exit 2
  ;;
esac
