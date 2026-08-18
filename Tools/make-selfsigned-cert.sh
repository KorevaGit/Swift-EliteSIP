#!/bin/bash
#
# Своя подпись, пока нет учётной записи Apple Developer.
#
# Создаёт самоподписанный сертификат для подписи кода и кладёт его в связку
# ключей входа. Учётной записи, оплаты и Apple для этого не нужно вовсе.
#
# ЧЕГО ЭТА ПОДПИСЬ НЕ ДАЁТ. Gatekeeper с ней не проходится: начиная с macOS
# 10.15 приложение, принесённое извне с карантином, обязано быть ещё и
# нотарифицировано, а нотарифицировать может только владелец Developer ID.
# Самоподписанный сертификат к этому не приближает ни на шаг — раздавать сборку
# ссылкой по-прежнему нельзя, её надо приносить так, чтобы карантина не было:
# `scp`, `rsync` или флешка через терминал. Подробности — docs/release.md.
#
# ЧТО ОНА ДАЁТ, И РАДИ ЧЕГО ВСЁ ЗАТЕЯНО — постоянную личность приложения.
# Ad-hoc подпись меняется при каждой пересборке, а от подписи зависят два
# системных механизма:
#
#   * Связка ключей. ACL записи привязан к подписи, и после каждой пересборки
#     macOS спрашивает разрешение заново, а `SecItemCopyMatching` держит поток
#     до ответа человека — те самые грабли, из-за которых чтение пароля вынесено
#     с главного потока.
#   * TCC, то есть доступ к микрофону. Пересборка с новой ad-hoc подписью — это
#     новое приложение с точки зрения TCC, то есть новый запрос доступа.
#
# С постоянным сертификатом и то и другое спрашивается один раз. Для приёмки на
# живом железе (M7f) это важнее, чем кажется: иначе половина прогона уходит на
# разбор того, что именно спросила система и почему.
#
# Запуск: Tools/make-selfsigned-cert.sh [имя]
#
# Связка ключей спросит разрешение — это нормально, скрипт кладёт в неё ключ.
# Пароль связки скрипт не знает и не спрашивает: диалог показывает система.

set -euo pipefail

name="${1:-EliteSIP Self-Signed}"
days=3650
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

if security find-identity -v -p codesigning | grep -qF "$name"; then
    echo "Сертификат «$name» уже есть в связке ключей. Нечего делать."
    security find-identity -v -p codesigning | grep -F "$name"
    exit 0
fi

echo "=== Ключ и сертификат"

# `extendedKeyUsage = codeSigning` обязателен: без него codesign сертификат не
# видит вовсе, а `security find-identity -p codesigning` его не покажет.
cat > "$workdir/openssl.cnf" <<CONF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no

[ dn ]
CN = $name

[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$workdir/key.pem" -out "$workdir/cert.pem" \
    -days "$days" -config "$workdir/openssl.cnf" 2>/dev/null

# Пароль на связку — случайный и живёт до конца скрипта: PKCS#12 без пароля
# macOS не принимает вовсе. Алгоритмы заданы старые намеренно: OpenSSL 3 по
# умолчанию шифрует контейнер AES-256, а `security import` такой не открывает и
# сообщает об этом как о неверном пароле — час на разбор на ровном месте.
transit_password=$(openssl rand -hex 16)
openssl pkcs12 -export -inkey "$workdir/key.pem" -in "$workdir/cert.pem" \
    -out "$workdir/bundle.p12" -passout "pass:$transit_password" -name "$name" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

echo "  ок: сертификат на $days дней"

echo "=== В связку ключей входа"

keychain="$HOME/Library/Keychains/login.keychain-db"
[[ -f "$keychain" ]] || keychain="$HOME/Library/Keychains/login.keychain"

# `-T /usr/bin/codesign` — чтобы codesign брал ключ без диалога на каждую
# подпись. Без этого выпуск останавливается на первом же вложенном файле и ждёт
# человека, а их в бандле не один.
security import "$workdir/bundle.p12" -k "$keychain" -P "$transit_password" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# Доверие ставится в пользовательском домене, без sudo и без системной связки:
# сертификат нужен только этой машине для подписи своих же сборок. Класть его в
# доверенные корни всей системы незачем — это ослабило бы проверку всего, что
# подписано этим ключом, а не только нашего приложения.
security add-trusted-cert -p codeSign -k "$keychain" "$workdir/cert.pem" >/dev/null

echo "  ок: сертификат в связке, доверие для подписи кода выставлено"

echo
if security find-identity -v -p codesigning | grep -qF "$name"; then
    security find-identity -v -p codesigning | grep -F "$name"
    cat <<DONE

Готово. Выпускать с ним так:

  Tools/release.sh --self-signed --identity "$name" --bump patch

Что важно помнить про такой выпуск:

  * Gatekeeper он не проходит. Приносить сборку на рабочее место надо без
    карантина — scp, rsync или флешка через терминал.
  * Обновлять такие сборки нечем: Sparkle (M7h) стоит после настоящей подписи.
  * Сертификат живёт только на этой машине. На другой машине сборка будет
    подписана другим ключом, то есть для связки ключей и TCC это будет другое
    приложение.
DONE
else
    echo "ПРОВАЛ: сертификат в связке не появился." >&2
    exit 1
fi
