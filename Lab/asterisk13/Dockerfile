# Asterisk 13.38.3 — ровно та версия, что на бою.
#
# Из пакетов её взять негде: Debian bullseye даёт 16, а stretch с 13.14 уже в
# архиве. Поэтому собираем из исходников. Это дороже по времени сборки, но
# отлаживать сигнализацию против другой мажорной версии — значит ловить чужие
# баги: у 13 и 16 отличается поведение chan_sip в мелочах, а мелочи здесь и
# составляют совместимость.
FROM debian:bullseye

ENV DEBIAN_FRONTEND=noninteractive
ARG ASTERISK_VERSION=13.38.3

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      curl \
      file \
      libedit-dev \
      libjansson-dev \
      libncurses5-dev \
      libsqlite3-dev \
      libsrtp2-dev \
      libssl-dev \
      libxml2-dev \
      pkg-config \
      uuid-dev \
      xmlstarlet \
      iproute2 \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src
RUN curl -fsSL "https://downloads.asterisk.org/pub/telephony/asterisk/releases/asterisk-${ASTERISK_VERSION}.tar.gz" \
      -o asterisk.tar.gz \
 && tar xzf asterisk.tar.gz \
 && rm asterisk.tar.gz

WORKDIR /usr/src/asterisk-${ASTERISK_VERSION}

# pjproject не собираем: chan_pjsip нам не нужен, а сборка pjproject добавляет
# минуты и лишние зависимости. res_srtp собирается — он понадобится в M2b.
RUN ./configure \
      --with-jansson-bundled \
      --with-ssl \
      --with-srtp \
      --without-pjproject \
 && make menuselect.makeopts \
 && menuselect/menuselect \
      --enable chan_sip \
      --enable app_confbridge \
      --enable func_confbridge \
      --enable res_srtp \
      --enable CORE-SOUNDS-EN-GSM \
      --enable EXTRA-SOUNDS-EN-GSM \
      menuselect.makeopts

RUN make -j"$(nproc)" \
 && make install \
 && make samples \
 && make config \
 && ldconfig

# Проверяем на этапе сборки, что получили именно то, зачем всё это затевалось.
RUN test -f /usr/lib/asterisk/modules/chan_sip.so \
 && test -f /usr/lib/asterisk/modules/res_srtp.so \
 && /usr/sbin/asterisk -V | grep -q "${ASTERISK_VERSION}"

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 5060/udp 5061/tcp

CMD ["/usr/local/bin/entrypoint.sh"]
