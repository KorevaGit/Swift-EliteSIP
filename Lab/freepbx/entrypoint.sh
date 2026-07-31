#!/bin/bash
# Запуск учебного стенда FreePBX: база, веб-сервер, затем Asterisk руками FreePBX.
#
# Порядок важен: fwconsole сам поднимает Asterisk и раскладывает конфиги из базы,
# поэтому Asterisk нельзя запускать до него — иначе он прочитает старые файлы.
set -e

mkdir -p /run/mysqld
chown mysql:mysql /run/mysqld

echo "[freepbx] запускаю MariaDB"
mysqld_safe --skip-syslog > /var/log/mysqld.log 2>&1 &

for _ in $(seq 1 90); do
    mysqladmin ping --silent 2>/dev/null && break
    sleep 1
done
mysqladmin ping --silent || { echo "[freepbx] MariaDB не поднялась"; tail -30 /var/log/mysqld.log; exit 1; }

echo "[freepbx] запускаю Apache"
. /etc/apache2/envvars
apache2 -k start

echo "[freepbx] запускаю Asterisk через fwconsole"
fwconsole start

# На пустом томе `freepbx-mysql` (первый запуск или `down -v`) MariaDB
# поднимается сразу, но собственная схема модулей FreePBX (queues, cdr и
# остальные) на этот момент ещё не создана — `fwconsole start` её досоздаёт
# в фоне и возвращает управление раньше, чем она готова. `queue-init.sh`
# писал прямо в `queues_config`/`queues_details` и падал с "Table ... doesn't
# exist", контейнер уходил в перезапуск, и в худшем случае это повторялось
# больше десятка раз подряд, пока схема не успевала досоздаться. На тёплом
# томе (обычный `up` после `down` без `-v`) схема уже есть, и цикл ниже
# проходит мгновенно.
echo "[freepbx] жду схему модулей FreePBX в базе"
for _ in $(seq 1 90); do
    mysql -N -e "SELECT 1 FROM queues_config LIMIT 1" asterisk >/dev/null 2>&1 && break
    sleep 1
done
mysql -N -e "SELECT 1 FROM queues_config LIMIT 1" asterisk >/dev/null 2>&1 || {
    echo "[freepbx] схема queues_config не появилась за 90 с"; exit 1
}

echo "[freepbx] завожу очередь раздачи 2929"
/usr/local/bin/freepbx-queue-init.sh

echo "[freepbx] применяю миграцию M1.6: CDR, CEL и записи"
/usr/local/bin/freepbx-m1-6-init.sh

echo "[freepbx] завожу тестовые номера и TLS-профиль для отладки клиента"
/usr/local/bin/freepbx-dev-tools-init.sh

echo "[freepbx] готово. Веб-интерфейс на опубликованном порту 80."
echo "[freepbx] дальше — журнал Asterisk:"

# Держим контейнер живым и сразу показываем то, что интересно смотреть.
touch /var/log/asterisk/full
exec tail -F /var/log/asterisk/full
