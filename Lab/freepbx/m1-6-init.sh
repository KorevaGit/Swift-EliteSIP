#!/bin/bash
# Идемпотентная миграция M1.6. Выполняется при каждом старте после fwconsole:
# постоянные тома могут быть созданы старой версией образа, поэтому одного COPY
# на этапе сборки недостаточно.
set -euo pipefail

SHARE=/usr/local/share/elitesip
ASTETC=/etc/asterisk
MONITOR=/var/spool/asterisk/monitor
EXTENSIONS=(100 101 102 103 634 711 724 807)

echo "[freepbx:m1.6] проверяю CDR/CEL и каталог записей"
mkdir -p "$MONITOR"
chown -R asterisk:asterisk "$MONITOR"
chmod 0775 "$MONITOR"

# Модули владеют схемами cdr/cel и генерируют правильные конфиги для своей
# версии. enable безопасен и для уже включённого модуля.
fwconsole ma enable cdr cel callrecording >/dev/null 2>&1 || true
fwconsole setting CEL_ENABLED 1 >/dev/null

# Диапазон отдельный от основной лаборатории и публикуется Docker один в один.
php -r '
include "/etc/freepbx.conf";
$settings = FreePBX::Sipsettings();
$settings->setConfig("rtpstart", "10200");
$settings->setConfig("rtpend", "10230");
$settings->setConfig("externip", getenv("FREEPBX_EXTERNAL_ADDRESS") ?: "127.0.0.1");
'

# chan_sip включает подмену адреса в SDP только при наличии localnet, поэтому
# список обязан быть непустым. Но объявлять в нём сеть контейнера нельзя, хотя
# ровно так здесь и было: Docker Desktop переписывает адрес источника, и клиент
# с хоста приходит со шлюза этой же сети. Asterisk считал его локальным и клал
# в SDP свой 172.x — адрес, до которого с macOS маршрута нет. Разговор при этом
# устанавливался целиком, а звука не было: `freepbx-traffic.sh` показывал
# «встречного потока RTP не было» при полностью прошедшей сигнализации.
#
# Поэтому диапазон заведомо ни с чем не совпадающий: он нужен, чтобы включить
# подстановку, а не чтобы кого-то пометить локальным. Через SNAT из 127.0.0.0/8
# не придёт никогда никто. То же самое и по той же причине сделано в основной
# лабе — Lab/asterisk/config/sip.conf.
printf '%s\n' \
  '; EliteSIP M1.6: Docker NAT для SIP/SDP' \
  "externip=${FREEPBX_EXTERNAL_ADDRESS:-127.0.0.1}" \
  'localnet=127.0.0.0/8' \
  > "$ASTETC/sip_general_m1_6.conf"
chown asterisk:asterisk "$ASTETC/sip_general_m1_6.conf"
touch "$ASTETC/sip_general_custom.conf"
chown asterisk:asterisk "$ASTETC/sip_general_custom.conf"
if ! grep -Fqx '#include sip_general_m1_6.conf' "$ASTETC/sip_general_custom.conf"; then
  printf '\n#include sip_general_m1_6.conf\n' >> "$ASTETC/sip_general_custom.conf"
fi

# Не затираем extensions_custom.conf: это пользовательский файл. Подключаем
# отдельный управляемый файл одной идемпотентной строкой.
install -o asterisk -g asterisk -m 0644 \
  "$SHARE/extensions_m1_6.conf" "$ASTETC/extensions_m1_6.conf"
touch "$ASTETC/extensions_custom.conf"
chown asterisk:asterisk "$ASTETC/extensions_custom.conf"
if ! grep -Fqx '#include extensions_m1_6.conf' "$ASTETC/extensions_custom.conf"; then
  printf '\n; EliteSIP M1.6: записываемый тестовый номер 600\n#include extensions_m1_6.conf\n' \
    >> "$ASTETC/extensions_custom.conf"
fi

# Политики FreePBX для расширений лежат в AstDB. Задаём все четыре направления:
# реальные SIP-вызовы должны записываться независимо от того, кто инициатор.
for extension in "${EXTENSIONS[@]}"; do
  for key in \
    recording/in/external \
    recording/in/internal \
    recording/out/external \
    recording/out/internal
  do
    asterisk -rx "database put AMPUSER $extension/$key force" >/dev/null
  done
  asterisk -rx "database put AMPUSER $extension/recording/ondemand enabled" >/dev/null
done

fwconsole reload >/dev/null

# Ошибка на этом этапе означает «интерфейс поднялся, но истории не будет» —
# такой контейнер не должен притворяться готовым.
mysql -N -e "SELECT 1 FROM asteriskcdrdb.cdr LIMIT 1" >/dev/null
mysql -N -e "SELECT 1 FROM asteriskcdrdb.cel LIMIT 1" >/dev/null
asterisk -rx 'module show like cdr_adaptive_odbc.so' | grep -q Running
asterisk -rx 'module show like cel_odbc.so' | grep -q Running
asterisk -rx 'odbc show all' | grep -q asteriskcdrdb
asterisk -rx 'dialplan show 600@from-internal-custom' | grep -q m1-6-recording-demo
asterisk -rx 'sip show settings' | grep -q 'SIP address remapping:  Enabled'

echo "[freepbx:m1.6] CDR, CEL, MixMonitor и номер 600 готовы"
