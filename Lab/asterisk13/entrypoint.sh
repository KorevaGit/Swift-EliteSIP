#!/bin/sh
# Копируем наши конфиги в /etc/asterisk поверх пакетных.
#
# Почему копирование, а не bind-mount каждого файла: монтирование отдельного
# файла привязано к его inode, а любой редактор (и любая правка из Xcode или
# скриптом) пересоздаёт файл заново. Контейнер после этого продолжает видеть
# старое содержимое, и отладка превращается в охоту за призраками. Каталог
# монтируется целиком, а нужные файлы кладутся на место при старте.
#
# Пакетные asterisk.conf, logger.conf и прочие при этом остаются на месте —
# без них Asterisk не поднимется.
set -e

if [ -d /etc/asterisk-elitesip ]; then
    cp -f /etc/asterisk-elitesip/*.conf /etc/asterisk/
    chown asterisk:asterisk /etc/asterisk/*.conf 2>/dev/null || true
fi

exec asterisk -f -vvvg -U root -G root
