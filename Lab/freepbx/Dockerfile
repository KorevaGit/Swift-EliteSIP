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
      unixodbc odbcinst unixodbc-dev \
      uuid-runtime cron sudo procps net-tools \
      gnupg dirmngr \
      cmake libmariadb-dev locales \
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

# Драйвер MariaDB ODBC — то, через что Asterisk пишет CDR и CEL в базу FreePBX.
#
# Собирается из исходников, потому что готового пакета нет ни в Debian bullseye
# (odbc-mariadb появился только в bookworm), ни в репозитории MariaDB под arm64.
# Без этого драйвера вся цепочка выглядит настроенной, но таблицы остаются
# пустыми: cdr_adaptive_odbc -> res_odbc -> unixODBC -> драйвера нет.
ARG MARIADB_ODBC_VERSION=3.1.20
RUN set -eux; \
    cd /usr/src; \
    curl -fsSL "https://github.com/mariadb-corporation/mariadb-connector-odbc/archive/refs/tags/${MARIADB_ODBC_VERSION}.tar.gz" \
      | tar xz; \
    cd "mariadb-connector-odbc-${MARIADB_ODBC_VERSION}"; \
    cmake -DCMAKE_BUILD_TYPE=Release \
          -DWITH_OPENSSL=ON \
          -DUSE_SYSTEM_INSTALLED_LIB=ON \
          -DCONC_WITH_UNIT_TESTS=OFF \
          .; \
    make -j"$(nproc)"; \
    make install; \
    ldconfig; \
    DRIVER="$(find /usr/local /usr/lib -name libmaodbc.so 2>/dev/null | head -1)"; \
    test -n "$DRIVER"; \
    printf '[MySQL]\nDescription = MariaDB ODBC\nDriver = %s\n' "$DRIVER" > /etc/odbcinst.ini; \
    printf '[MySQL-asteriskcdrdb]\nDescription = MySQL connection to asteriskcdrdb\nDriver = MySQL\nServer = localhost\nDatabase = asteriskcdrdb\nPort = 3306\nSocket = /var/run/mysqld/mysqld.sock\nOption = 3\n' > /etc/odbc.ini; \
    cd /usr/src && rm -rf "mariadb-connector-odbc-${MARIADB_ODBC_VERSION}"

# Русская локаль. Переводы интерфейса FreePBX уже в комплекте
# (i18n/ru_RU/LC_MESSAGES/amp.mo), но gettext без сгенерированной локали их не
# подхватит и молча покажет английский.
RUN sed -i 's/^# *\(ru_RU.UTF-8 UTF-8\)/\1/' /etc/locale.gen \
 && sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen \
 && locale-gen \
 && test -n "$(locale -a | grep -i ru_RU)"

# Установка FreePBX требует поднятой базы и работающего Asterisk, поэтому всё
# происходит в одном слое: поднимаем MariaDB, создаём базы, запускаем Asterisk,
# ставим FreePBX, гасим за собой.
#
# Про порядок шагов внутри — три вещи, каждая из которых стоила отдельной сборки:
#
#   * patch-php74.sh вызывается ЧЕТЫРЕ раза, и это не перестраховка: install и
#     каждая установка модулей перезаписывают уже пропатченные файлы своими
#     свежими копиями. Патч обязан идти после каждого такого шага, иначе
#     следующая команда fwconsole падает на deprecated-предупреждении.
#   * `fwconsole ma install cdr` нужен отдельно: installall оставляет cdr в
#     состоянии «отключён, ожидает обновления», а res_odbc_additional.conf с
#     описанием подключения к базе пишет именно этот модуль. Без него соединения
#     asteriskcdrdb в Asterisk нет, и CDR с CEL молча никуда не пишутся.
#   * cel.conf и cel_odbc.conf копируются нами: FreePBX их не создаёт, а без
#     enable=yes в cel.conf журнал событий не ведётся вообще.
COPY patch-php74.sh /usr/local/bin/patch-php74.sh
COPY extensions.csv /usr/local/share/elitesip/extensions.csv
COPY cel.sql /usr/local/share/elitesip/cel.sql
COPY cel.conf cel_odbc.conf /usr/local/share/elitesip/
RUN chmod +x /usr/local/bin/patch-php74.sh

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
    /usr/local/bin/patch-php74.sh /usr/src/freepbx; \
    cd /usr/src/freepbx; \
    ./start_asterisk start; \
    sleep 5; \
    ./install -n --dbuser="${DB_USER}" --dbpass="${DB_PASS}"; \
    /usr/local/bin/patch-php74.sh /var/www/html/admin; \
    fwconsole ma installall || true; \
    /usr/local/bin/patch-php74.sh /var/www/html/admin; \
    fwconsole ma install cdr; \
    fwconsole ma downloadinstall bulkhandler; \
    /usr/local/bin/patch-php74.sh /var/www/html/admin; \
    fwconsole bulkimport /usr/local/share/elitesip/extensions.csv --type=extensions --replace; \
    fwconsole setting UIDEFAULTLANG ru_RU; \
    fwconsole setting SHOWLANGUAGE 1; \
    mysql asteriskcdrdb < /usr/local/share/elitesip/cel.sql; \
    cp /usr/local/share/elitesip/cel.conf /usr/local/share/elitesip/cel_odbc.conf /etc/asterisk/; \
    chown asterisk:asterisk /etc/asterisk/cel.conf /etc/asterisk/cel_odbc.conf; \
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

COPY extensions_m1_6.conf /usr/local/share/elitesip/extensions_m1_6.conf
COPY queue-init.sh /usr/local/bin/freepbx-queue-init.sh
COPY m1-6-init.sh /usr/local/bin/freepbx-m1-6-init.sh
COPY entrypoint.sh /usr/local/bin/freepbx-entrypoint.sh
RUN chmod +x \
      /usr/local/bin/freepbx-entrypoint.sh \
      /usr/local/bin/freepbx-queue-init.sh \
      /usr/local/bin/freepbx-m1-6-init.sh

EXPOSE 80 5060/udp 5160/udp 5061/tcp

CMD ["/usr/local/bin/freepbx-entrypoint.sh"]
