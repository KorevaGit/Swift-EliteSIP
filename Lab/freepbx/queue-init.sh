#!/bin/bash
# Очередь раздачи 2929 на учебном стенде FreePBX.
#
# Заводится скриптом, а не руками в веб-интерфейсе, по той же причине, по
# которой добавочные приезжают из extensions.csv: поведение очереди — часть
# воспроизводимой сквозной проверки, а не разовая настройка, которую после
# пересоздания тома придётся вспоминать.
#
# Пишем прямо в таблицы, потому что чистого API добавления у модуля queues нет:
# страница редактирования сама пишет `queues_config` и `queues_details`, а
# `fwconsole reload` уже из них генерирует `queues_additional.conf` и диалплан.
# То есть очередь остаётся ровно такой, какую делает FreePBX, — а посмотреть,
# что именно он делает, стенд и нужен.
#
# Идемпотентно: строки очереди сначала удаляются, потом вставляются заново.
set -euo pipefail

QUEUE=2929
DESCR="AutoDialer"

# Кто в очереди.
#
# Двумя частями и намеренно. 100 и 101 — те добавочные, под которыми в
# лабораторию входит сам софтфон (см. пресеты в настройках приложения): без них
# сквозную проверку «звонок пришёл в очередь и зазвонил у меня» выполнить нечем.
# 634, 711, 724 и 807 — номера, которые видны в боевых CDR: они дают очереди
# боевую форму, хотя на стенде и не регистрируются.
#
# Порядок важен: при strategy=ringall он определяет только порядок строк в
# конфиге, но при смене стратегии на rrmemory станет очередью обхода.
MEMBERS=(100 101 634 711 724 807)

echo "[freepbx:m1.5] создаю очередь $QUEUE"

{
  echo "DELETE FROM queues_details WHERE id = '$QUEUE';"
  echo "DELETE FROM queues_config  WHERE extension = '$QUEUE';"

  # CallerID очереди не переопределяем: на бою плечо агента получает
  # «AutoDialer» <2929> со стороны транка автообзвона, а не от очереди. Поставь
  # мы здесь grppre — стенд врал бы про происхождение имени.
  #
  # monitor_type пустой: запись включена принудительно для каждого добавочного
  # в AMPUSER (см. m1-6-init.sh), и плечо агента пишется независимо от очереди.
  # Колонка всё равно varchar(5) и «MixMon» в неё не помещается.
  cat <<SQL
INSERT INTO queues_config
  (extension, descr, grppre, alertinfo, ringing, maxwait, password, ivr_id, dest,
   cwignore, queuewait, use_queue_context, togglehint, qnoanswer, callconfirm,
   qregex, monitor_type, monitor_heard, monitor_spoken)
VALUES
  ('$QUEUE', '$DESCR', '', '', 1, '0', '', '', '',
   0, 0, 0, 0, 0, 0, '', '', 0, 0);
SQL

  # Значения по умолчанию FreePBX для новой очереди. Держим их явными: стенд
  # должен быть одинаковым после каждого пересоздания тома.
  cat <<SQL
INSERT INTO queues_details (id, keyword, data, flags) VALUES
  ('$QUEUE','strategy','ringall',0),
  ('$QUEUE','timeout','15',0),
  ('$QUEUE','retry','5',0),
  ('$QUEUE','wrapuptime','0',0),
  ('$QUEUE','maxlen','0',0),
  ('$QUEUE','joinempty','yes',0),
  ('$QUEUE','leavewhenempty','no',0),
  ('$QUEUE','ringinuse','no',0),
  ('$QUEUE','autofill','yes',0),
  ('$QUEUE','autopause','no',0),
  ('$QUEUE','reportholdtime','no',0),
  ('$QUEUE','memberdelay','0',0),
  ('$QUEUE','weight','0',0),
  ('$QUEUE','servicelevel','60',0),
  ('$QUEUE','music','default',0);
SQL

  # Статические участники: Local-канал через from-queue — так их записывает
  # сам FreePBX, и по этой же паре он потом находит hint добавочного.
  flags=0
  for member in "${MEMBERS[@]}"; do
    echo "INSERT INTO queues_details (id, keyword, data, flags)"
    echo "VALUES ('$QUEUE','member','Local/$member@from-queue/n',$flags);"
    flags=$((flags + 1))
  done
} | mysql asterisk

fwconsole reload >/dev/null

# Проверяем не свою же запись в базе, а то, что из неё получилось: очередь
# должна существовать в Asterisk и иметь всех участников, а набор номера —
# попадать в диалплан. Иначе контейнер не должен притворяться готовым.
queue_state="$(asterisk -rx "queue show $QUEUE")"
echo "$queue_state" | grep -q "^$QUEUE has" || {
  echo "[freepbx:m1.5] Asterisk не видит очередь $QUEUE"; exit 1
}
for member in "${MEMBERS[@]}"; do
  echo "$queue_state" | grep -q "Local/$member@from-queue/n" || {
    echo "[freepbx:m1.5] участник $member не попал в очередь"; exit 1
  }
done
asterisk -rx "dialplan show $QUEUE@ext-queues" | grep -q "Queue(" || {
  echo "[freepbx:m1.5] нет диалплана набора очереди"; exit 1
}

echo "[freepbx:m1.5] очередь $QUEUE готова, участников: ${#MEMBERS[@]}"
