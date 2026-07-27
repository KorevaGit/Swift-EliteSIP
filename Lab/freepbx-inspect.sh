#!/bin/bash
# Показывает, что FreePBX сгенерировал внутри Asterisk.
#
# Смысл инструмента: FreePBX — это веб-интерфейс над базой плюс генератор
# конфигов. Asterisk про FreePBX не знает ничего и читает обычные файлы. Понять
# связку можно только одним способом: изменить что-то в интерфейсе и посмотреть,
# какие файлы и какой диалплан от этого поменялись.
#
#   ./freepbx-inspect.sh                 — отчёт по текущему состоянию
#   ./freepbx-inspect.sh snapshot до     — снять копию /etc/asterisk под именем «до»
#   ./freepbx-inspect.sh diff до после   — показать, что изменилось между копиями
set -euo pipefail

CONTAINER=elitesip-freepbx
SNAPSHOTS="$(cd "$(dirname "$0")" && pwd)/freepbx-snapshots"

section() { printf '\n\033[1m=== %s\033[0m\n' "$1"; }

require_container() {
  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "Контейнер $CONTAINER не запущен." >&2
    echo "Запуск: docker compose -f docker-compose.freepbx.yml up -d" >&2
    exit 1
  fi
}

case "${1:-report}" in

snapshot)
  require_container
  name="${2:?укажите имя снимка, например: ./freepbx-inspect.sh snapshot до}"
  target="$SNAPSHOTS/$name"
  rm -rf "$target"
  mkdir -p "$target"
  # tar -h, а не docker cp: FreePBX подменяет часть файлов в /etc/asterisk
  # символическими ссылками на каталоги модулей (sip.conf, extensions.conf,
  # features.conf и ещё несколько). docker cp копирует сами ссылки, и на хосте
  # они оказываются битыми — diff потом жалуется на «No such file».
  docker exec "$CONTAINER" tar -ch -C /etc/asterisk . | tar -x -C "$target"
  echo "Снимок сохранён: $target ($(find "$target" -type f | wc -l | tr -d ' ') файлов)"
  ;;

diff)
  a="$SNAPSHOTS/${2:?укажите первый снимок}"
  b="$SNAPSHOTS/${3:?укажите второй снимок}"
  [ -d "$a" ] || { echo "Нет снимка $a" >&2; exit 1; }
  [ -d "$b" ] || { echo "Нет снимка $b" >&2; exit 1; }
  echo "Разница между «$2» и «$3»:"
  # Без -q: интересны именно строки, а не список файлов.
  diff -ru "$a" "$b" || true
  ;;

report)
  require_container

  section "Версии"
  docker exec "$CONTAINER" asterisk -rx 'core show version' | head -1
  docker exec "$CONTAINER" fwconsole --version 2>/dev/null | head -2 || true

  section "Файлы, которые FreePBX генерирует и которые оставляет вам"
  # _additional перезаписывается при каждом «Apply Config» — править бесполезно.
  # _custom FreePBX не трогает никогда — только сюда можно писать руками.
  docker exec "$CONTAINER" bash -c \
    'ls -1 /etc/asterisk | grep -E "_additional|_custom" | sort' || true

  section "Точки входа: кто кого подключает"
  docker exec "$CONTAINER" bash -c \
    'grep -Hn "^#include" /etc/asterisk/sip.conf /etc/asterisk/extensions.conf 2>/dev/null' || true

  section "Контексты диалплана, созданные FreePBX"
  docker exec "$CONTAINER" asterisk -rx 'dialplan show' \
    | grep -oE "^\[ Context '[^']+'" | sed "s/.*'\(.*\)'/\1/" | sort || true

  section "Пиры chan_sip"
  docker exec "$CONTAINER" asterisk -rx 'sip show peers' || true

  section "Контекст from-internal — он же в боевых CDR"
  docker exec "$CONTAINER" asterisk -rx 'dialplan show from-internal' | head -30 || true

  section "sub-record-check — подпрограмма записи из боевого CEL"
  docker exec "$CONTAINER" asterisk -rx 'dialplan show sub-record-check' | head -25 || true

  section "Очереди"
  docker exec "$CONTAINER" asterisk -rx 'queue show' || true

  section "Установленные модули FreePBX"
  docker exec "$CONTAINER" fwconsole ma list 2>/dev/null | head -35 || true
  ;;

*)
  echo "Неизвестный режим: $1" >&2
  sed -n '2,12p' "$0" >&2
  exit 2
  ;;
esac
