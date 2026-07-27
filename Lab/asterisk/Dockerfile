# Asterisk 16 LTS (Debian bullseye) — выбран специально: chan_sip там собирается
# по умолчанию. С Asterisk 17 chan_sip помечен deprecated и отключён в сборке,
# а в 21 удалён совсем. Отлаживаться надо против того же драйвера, что на бою.
FROM debian:bullseye

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      asterisk \
      asterisk-modules \
      asterisk-config \
      openssl \
      ca-certificates \
      iproute2 \
 && rm -rf /var/lib/apt/lists/*

# Падаем на этапе сборки, а не в рантайме, если chan_sip в пакете отсутствует.
RUN test -f /usr/lib/asterisk/modules/chan_sip.so \
 || (echo "FATAL: chan_sip.so нет в этом пакете asterisk" && exit 1)

EXPOSE 5060/udp 5061/tcp

# -f = foreground, чтобы контейнером управлял docker, а не asterisk-демон.
CMD ["asterisk", "-f", "-vvvg", "-U", "root", "-G", "root"]
