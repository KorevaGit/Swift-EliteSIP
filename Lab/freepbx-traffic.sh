#!/bin/bash
# Создаёт реальные звонки на стенде FreePBX, чтобы в CDR и CEL появились записи.
#
# Основной ANSWERED-вызов делает настоящий SIP-клиент `sipcheck`: регистрация,
# INVITE, RTP и BYE проходят через FreePBX, а не появляются искусственной
# вставкой в SQL или одним `channel originate`.
#
#   ./freepbx-traffic.sh            — сделать звонки и показать результат
#   ./freepbx-traffic.sh show       — только показать, что уже записано
#   ./freepbx-traffic.sh clear      — очистить CDR и CEL
set -euo pipefail

CONTAINER=elitesip-freepbx
COUNT="${COUNT:-4}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SIPCHECK_DIR="$SCRIPT_DIR/../Tools/sipcheck"

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
  sql "SELECT calldate, src, dst, dcontext, lastapp, disposition,
              duration, billsec, recordingfile
       FROM cdr ORDER BY calldate DESC, sequence DESC LIMIT 12" || true

  section "CEL — события последнего звонка"
  # linkedid связывает все плечи одного звонка. Именно по нему страница
  # «Детализация связанных звонков» собирает их вместе.
  sql "SELECT eventtype, eventtime, exten, context, appname, channame
       FROM cel
       WHERE linkedid = (
         SELECT linkedid FROM cdr
         WHERE dst = '600'
         ORDER BY calldate DESC, sequence DESC LIMIT 1
       )
       ORDER BY id" || true

  section "Итого"
  echo "CDR: $(docker exec "$CONTAINER" mysql -N -e 'SELECT COUNT(*) FROM cdr' asteriskcdrdb) записей"
  echo "CEL: $(docker exec "$CONTAINER" mysql -N -e 'SELECT COUNT(*) FROM cel' asteriskcdrdb) событий"
  echo "Записи:"
  docker exec "$CONTAINER" find /var/spool/asterisk/monitor -type f \
    -printf '  %P  %s байт\n' 2>/dev/null | sort | tail -20 || true
}

case "${1:-generate}" in

show)
  show
  ;;

clear)
  sql "TRUNCATE TABLE cdr" >/dev/null
  sql "TRUNCATE TABLE cel" >/dev/null
  docker exec "$CONTAINER" find /var/spool/asterisk/monitor -type f -delete
  echo "CDR, CEL и файлы записей очищены."
  ;;

generate)
  section "Проверяю, что запись в базу вообще подключена"
  if ! ast 'odbc show all' | grep -q asteriskcdrdb; then
    echo "Соединение asteriskcdrdb в Asterisk отсутствует — CDR писаться не будет." >&2
    echo "Проверьте: fwconsole ma list | grep cdr  (модуль должен быть включён)" >&2
    exit 1
  fi
  echo "Соединение asteriskcdrdb на месте."

  section "Делаю реальные SIP-разговоры с записью"
  for _ in $(seq 1 "$COUNT"); do
    (
      cd "$SIPCHECK_DIR"
      swift run sipcheck \
        --user 100 --password elite100 \
        --host 127.0.0.1 --transport udp --port 5080 \
        --call 600 --duration 2
    )
  done

  sleep 2

  section "Проверяю связь CDR с физическим файлом"
  RECORDING="$(
    docker exec "$CONTAINER" mysql -N -e \
      "SELECT recordingfile FROM cdr
       WHERE dst = '600' AND recordingfile <> ''
       ORDER BY calldate DESC, sequence DESC LIMIT 1" \
      asteriskcdrdb
  )"
  if [ -z "$RECORDING" ]; then
    echo "CDR создан, но recordingfile пуст — MixMonitor не связал запись со звонком." >&2
    exit 1
  fi
  DATE_PART="$(printf '%s' "$RECORDING" | cut -d- -f4)"
  RECORDING_PATH="/var/spool/asterisk/monitor/${DATE_PART:0:4}/${DATE_PART:4:2}/${DATE_PART:6:2}/$RECORDING"
  RECORDING_BYTES="$(docker exec "$CONTAINER" stat -c %s "$RECORDING_PATH" 2>/dev/null || printf 0)"
  if [ "$RECORDING_BYTES" -le 44 ]; then
    echo "CDR ссылается на отсутствующий файл или WAV без аудио: $RECORDING_PATH" >&2
    exit 1
  fi
  RECORDING_SECONDS="$(docker exec "$CONTAINER" soxi -D "$RECORDING_PATH")"
  echo "  $RECORDING_PATH — $RECORDING_BYTES байт, ${RECORDING_SECONDS} с"

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
