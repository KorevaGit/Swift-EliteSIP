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

echo "[freepbx] применяю миграцию M1.6: CDR, CEL и записи"
/usr/local/bin/freepbx-m1-6-init.sh

echo "[freepbx] готово. Веб-интерфейс на опубликованном порту 80."
echo "[freepbx] дальше — журнал Asterisk:"

# Держим контейнер живым и сразу показываем то, что интересно смотреть.
touch /var/log/asterisk/full
exec tail -F /var/log/asterisk/full
