#!/bin/bash
# Самоподписанный сертификат для TLS-транспорта лабораторного Asterisk.
# Только для локальной отладки — в .gitignore, в репозиторий не попадает.
set -euo pipefail

cd "$(dirname "$0")"

if [[ -f asterisk.pem && "${1:-}" != "--force" ]]; then
  echo "asterisk.pem уже есть. Перевыпустить: $0 --force"
  exit 0
fi

# SAN с 127.0.0.1 и localhost: клиент ходит на опубликованный порт по loopback,
# и проверка имени должна проходить, когда мы её включим.
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout asterisk.key -out asterisk.crt \
  -days 3650 -sha256 \
  -subj "/C=RU/O=EliteSIP Lab/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
  -addext "extendedKeyUsage=serverAuth" 2>/dev/null

# chan_sip читает ключ и сертификат из одного файла.
cat asterisk.key asterisk.crt > asterisk.pem
chmod 600 asterisk.key asterisk.pem

echo "Готово: $(pwd)/asterisk.pem"
openssl x509 -in asterisk.crt -noout -subject -dates -ext subjectAltName
