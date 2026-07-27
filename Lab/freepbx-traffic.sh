#!/bin/bash
# Создаёт реальные звонки на стенде FreePBX, чтобы в CDR и CEL появились записи.
#
# Зачем: страница «Отчёты → CDR» пуста, пока не было ни одного звонка, и понять
# по ней ничего нельзя. Клиента, который умеет звонить, ещё нет (это M2),
# поэтому звонки инициирует сам Asterisk командой channel originate.
#
#   ./freepbx-traffic.sh            — сделать звонки и показать результат
#   ./freepbx-traffic.sh show       — только показать, что уже записано
#   ./freepbx-traffic.sh clear      — очистить CDR и CEL
set -euo pipefail

CONTAINER=elitesip-freepbx
COUNT="${COUNT:-4}"

section() { printf '\n\033[1m=== %s\033[0m\n' "$1"; }

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "Контейнер $CONTAINER не запущен." >&2
  echo "Запуск: docker compose -f docker-compose.freepbx.yml up -d" >&2
  exit 1
fi

ast() { docker exec "$CONTAINER" asterisk -rx "$1"; }
sql() { docker exec "$CONTAINER" mysql -e "$1" asteriskcdrdb; }

show() {
  section "CDR — последние записи"
  sql "SELECT calldate, dst, dcontext, lastapp, disposition, duration
       FROM cdr ORDER BY calldate DESC, sequence DESC LIMIT 12" || true

  section "CEL — события последнего звонка"
  # linkedid связывает все плечи одного звонка. Именно по нему страница
  # «Детализация связанных звонков» собирает их вместе.
  sql "SELECT eventtype, eventtime, exten, context, appname, channame
       FROM cel
       WHERE linkedid = (SELECT linkedid FROM cel ORDER BY id DESC LIMIT 1)
       ORDER BY id" || true

  section "Итого"
  echo "CDR: $(docker exec "$CONTAINER" mysql -N -e 'SELECT COUNT(*) FROM cdr' asteriskcdrdb) записей"
  echo "CEL: $(docker exec "$CONTAINER" mysql -N -e 'SELECT COUNT(*) FROM cel' asteriskcdrdb) событий"
}

case "${1:-generate}" in

show)
  show
  ;;

clear)
  sql "TRUNCATE TABLE cdr" >/dev/null
  sql "TRUNCATE TABLE cel" >/dev/null
  echo "CDR и CEL очищены."
  ;;

generate)
  section "Проверяю, что запись в базу вообще подключена"
  if ! ast 'odbc show all' | grep -q asteriskcdrdb; then
    echo "Соединение asteriskcdrdb в Asterisk отсутствует — CDR писаться не будет." >&2
    echo "Проверьте: fwconsole ma list | grep cdr  (модуль должен быть включён)" >&2
    exit 1
  fi
  echo "Соединение asteriskcdrdb на месте."

  section "Звоню"
  # *43 — эхо-тест FreePBX, он отвечает сразу: получаем ANSWERED-записи.
  for _ in $(seq 1 "$COUNT"); do
    ast 'channel originate Local/*43@from-internal application Wait 2' >/dev/null || true
    printf '  эхо-тест *43\n'
    sleep 3
  done

  # Звонок на незарегистрированный номер: получаем плечо с уходом в
  # macro-vm по CHANUNAVAIL — ровно так же выглядит недоступный агент на бою.
  ast 'channel originate Local/711@from-internal application Wait 1' >/dev/null || true
  printf '  звонок на незарегистрированный 711\n'
  sleep 4

  show
  echo
  echo "Дальше — «Отчёты → CDR» в интерфейсе: http://localhost:8080"
  ;;

*)
  echo "Неизвестный режим: $1" >&2
  sed -n '2,12p' "$0" >&2
  exit 2
  ;;
esac
