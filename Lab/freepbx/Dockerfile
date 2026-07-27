# FreePBX 15 поверх нашего же Asterisk 13.38.3.
#
# Зачем именно так:
#   * «поверх нашего asterisk» — буквально: базовый образ тот же, что в лабе для
#     отладки клиента, с тем же chan_sip и той же боевой версией;
#   * FreePBX 15 — версия, которая штатно работает с Asterisk 13, то есть та же
#     пара, что на бою (FreePBX 16 и 17 требуют Asterisk 16+ и 20+);
#   * сборка нативная под arm64. Готовые образы FreePBX на Docker Hub только
#     amd64, то есть на Apple Silicon поехали бы через эмуляцию.
#
# Это учебный стенд, а не инфраструктура: один контейнер держит MariaDB, Apache
# и Asterisk. Для понимания того, что FreePBX генерирует, этого достаточно.
FROM elitesip-asterisk13:13.38.3

ENV DEBIAN_FRONTEND=noninteractive
ARG FREEPBX_TARBALL=http://mirror.freepbx.org/modules/packages/freepbx/freepbx-15.0-latest.tgz
ARG DB_USER=freepbxuser
ARG DB_PASS=freepbxpass

# Набор пакетов — это список требований FreePBX 15, а не «что попало под руку».
# В bullseye php-метапакет даёт 7.4, что FreePBX 15 и хочет.
RUN apt-get update && apt-get install -y --no-install-recommends \
      apache2 libapache2-mod-php \
      mariadb-server mariadb-client \
      php php-cli php-mysql php-mbstring php-curl php-gd php-xml php-zip \
      php-intl php-bcmath php-soap php-ldap php-sqlite3 \
      nodejs npm \
      sox mpg123 lame ffmpeg sqlite3 git unzip \
      unixodbc odbcinst \
      uuid-runtime cron sudo procps net-tools \
      gnupg dirmngr \
 && rm -rf /var/lib/apt/lists/*
# gnupg здесь обязателен, а не «на всякий случай»: FreePBX проверяет подписи
# модулей через gpg, и без него установка падает на первом же модуле с
# «Could not find gpg command!». С --no-install-recommends он не приезжает сам.

# FreePBX ждёт, что Asterisk работает под пользователем asterisk, а не под root.
RUN useradd -r -d /var/lib/asterisk -s /bin/false asterisk 2>/dev/null || true \
 && mkdir -p /var/run/asterisk /var/log/asterisk /var/lib/asterisk \
             /var/spool/asterisk /var/lib/php/session /var/www/html \
 && chown -R asterisk:asterisk /var/run/asterisk /var/log/asterisk \
             /var/lib/asterisk /var/spool/asterisk /etc/asterisk \
             /usr/lib/asterisk /var/www \
 && chown -R asterisk:asterisk /var/lib/php/session

# Apache работает от имени asterisk — иначе веб-интерфейс не сможет писать
# конфиги Asterisk, а именно это и есть суть FreePBX.
RUN sed -i 's/^export APACHE_RUN_USER=.*/export APACHE_RUN_USER=asterisk/' /etc/apache2/envvars \
 && sed -i 's/^export APACHE_RUN_GROUP=.*/export APACHE_RUN_GROUP=asterisk/' /etc/apache2/envvars \
 && sed -i 's|DocumentRoot /var/www/html|DocumentRoot /var/www/html|' /etc/apache2/sites-available/000-default.conf \
 && sed -i 's/AllowOverride None/AllowOverride All/g' /etc/apache2/apache2.conf \
 && a2enmod rewrite \
 && printf '%s\n' \
      'upload_max_filesize = 120M' \
      'memory_limit = 256M' \
      'post_max_size = 120M' \
      'session.save_path = /var/lib/php/session' \
      '; Гигиена по официальной инструкции FreePBX для Debian. Обработчик ошибок' \
      '; Symfony это НЕ отключает — от него спасает только патч ниже.' \
      'error_reporting = E_ALL & ~E_NOTICE & ~E_DEPRECATED & ~E_STRICT' \
      'display_errors = Off' \
      > /etc/php/7.4/apache2/conf.d/99-freepbx.ini \
 && cp /etc/php/7.4/apache2/conf.d/99-freepbx.ini /etc/php/7.4/cli/conf.d/99-freepbx.ini

# ODBC — то, через что Asterisk пишет CDR в базу FreePBX.
#
# В Debian bullseye драйвера MariaDB ODBC нет (пакет odbc-mariadb появился
# только в bookworm), поэтому в этом стенде запись CDR не подключена: страница
# «Reports → CDR» останется пустой. На цель стенда это не влияет — он нужен,
# чтобы видеть, как FreePBX генерирует конфиги и диалплан, а не чтобы собирать
# статистику. Файлы всё равно создаём: если драйвер появится, останется только
# прописать путь.
RUN DRIVER="$(ls /usr/lib/*/odbc/libmaodbc.so 2>/dev/null | head -1 || true)" \
 && printf '[MySQL]\nDescription = MariaDB ODBC\nDriver = %s\n' "${DRIVER:-НЕ УСТАНОВЛЕН}" > /etc/odbcinst.ini \
 && printf '[MySQL-asteriskcdrdb]\nDescription = MySQL connection to asteriskcdrdb\nDriver = MySQL\nServer = localhost\nDatabase = asteriskcdrdb\nPort = 3306\nSocket = /var/run/mysqld/mysqld.sock\nOption = 3\n' > /etc/odbc.ini

# Установка FreePBX требует поднятой базы и работающего Asterisk, поэтому всё
# происходит в одном слое: поднимаем MariaDB, создаём базы, запускаем Asterisk,
# ставим FreePBX, гасим за собой.
RUN set -eux; \
    mkdir -p /run/mysqld && chown mysql:mysql /run/mysqld; \
    mysqld_safe --skip-syslog > /tmp/mysqld.log 2>&1 & \
    for i in $(seq 1 90); do mysqladmin ping --silent 2>/dev/null && break; sleep 1; done; \
    mysqladmin ping --silent; \
    mysql -e "CREATE DATABASE IF NOT EXISTS asterisk CHARACTER SET utf8 COLLATE utf8_general_ci;"; \
    mysql -e "CREATE DATABASE IF NOT EXISTS asteriskcdrdb CHARACTER SET utf8 COLLATE utf8_general_ci;"; \
    mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"; \
    mysql -e "GRANT ALL PRIVILEGES ON asterisk.* TO '${DB_USER}'@'localhost';"; \
    mysql -e "GRANT ALL PRIVILEGES ON asteriskcdrdb.* TO '${DB_USER}'@'localhost';"; \
    mysql -e "FLUSH PRIVILEGES;"; \
    cd /usr/src; \
    curl -fsSL "${FREEPBX_TARBALL}" -o freepbx.tgz; \
    tar xzf freepbx.tgz; \
    rm freepbx.tgz; \
    cd /usr/src/freepbx; \
    ENCODING=amp_conf/htdocs/admin/libraries/Composer/vendor/neitanod/forceutf8/src/ForceUTF8/Encoding.php; \
    sed -i 's/\$text{\([^}]*\)}/$text[\1]/g' "$ENCODING"; \
    test "$(grep -c '{\$' "$ENCODING")" = "0"; \
    ./start_asterisk start; \
    sleep 5; \
    ./install -n --dbuser="${DB_USER}" --dbpass="${DB_PASS}"; \
    fwconsole ma installall || true; \
    fwconsole reload || true; \
    fwconsole stop || true; \
    rm -f /var/www/html/index.html; \
    rm -f /etc/asterisk/extensions.ael /etc/asterisk/extensions.lua; \
    mysqladmin shutdown; \
    sleep 2
# Две удалённые вещи — не придирки:
#   * index.html от Apache перекрывал корень сайта, и http://localhost:8080/
#     показывал «It works» вместо интерфейса FreePBX;
#   * extensions.ael и extensions.lua — примеры из make samples. Они добавляют
#     два десятка контекстов ael-* и dundi-*, которых на боевом сервере нет, и
#     засоряют ровно тот список, ради которого стенд и нужен.

COPY entrypoint.sh /usr/local/bin/freepbx-entrypoint.sh
RUN chmod +x /usr/local/bin/freepbx-entrypoint.sh

EXPOSE 80 5060/udp 5061/tcp

CMD ["/usr/local/bin/freepbx-entrypoint.sh"]
