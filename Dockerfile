###############################################
# RTORRENT + RUTORRENT - Image Custom v3.2.0  #
# Build depuis les sources officielles        #
# LaboBox-VPN - 2025                          #
###############################################

FROM alpine:3.20 AS builder

# Installation des dependances de compilation
RUN apk add --no-cache \
    build-base \
    git \
    libtool \
    automake \
    autoconf \
    curl-dev \
    ncurses-dev \
    openssl-dev \
    zlib-dev \
    linux-headers \
    cppunit-dev \
    cmake \
    ninja \
    udns-dev \
    wget

# Compilation de xmlrpc-c avec support i8 (64-bit integers)
WORKDIR /tmp
RUN wget -q https://sourceforge.net/projects/xmlrpc-c/files/Xmlrpc-c%20Super%20Stable/1.59.03/xmlrpc-c-1.59.03.tgz && \
    tar xzf xmlrpc-c-1.59.03.tgz && \
    cd xmlrpc-c-1.59.03 && \
    ./configure --prefix=/usr/local \
        --enable-abyss-threads \
        --enable-long-long \
        --disable-cgi-server \
        --disable-libwww-client \
        --disable-wininet-client && \
    make -j$(nproc) && \
    make install

# Compilation de libtorrent v0.16.5 (dependance de rtorrent)
# NOTE : rester en 0.16.5. Les tags >= 0.16.x recents renomment des
# commandes du .rc (ex. network.port_range.set -> network.listen.port.range.set),
# ce qui empeche rtorrent de demarrer avec la config actuelle.
RUN git clone https://github.com/rakshasa/libtorrent.git && \
    cd libtorrent && \
    git checkout v0.16.5 && \
    autoreconf -fiv && \
    ./configure --prefix=/usr/local --disable-debug && \
    make -j$(nproc) && \
    make install

# Compilation de rtorrent v0.16.5 (voir NOTE libtorrent ci-dessus)
RUN git clone https://github.com/rakshasa/rtorrent.git && \
    cd rtorrent && \
    git checkout v0.16.5 && \
    autoreconf -fiv && \
    PKG_CONFIG_PATH=/usr/local/lib/pkgconfig ./configure --prefix=/usr/local --with-xmlrpc-c=/usr/local/bin/xmlrpc-c-config --disable-debug && \
    make -j$(nproc) && \
    make install

###############################################
# Image finale
###############################################
FROM alpine:3.20

LABEL maintainer="laboboxvpn"
LABEL description="rtorrent + ruTorrent custom build"
LABEL version="3.2.0"

# Variables d'environnement par defaut
ENV PUID=1000 \
    PGID=1000 \
    TZ=Europe/Paris \
    RT_PORT=50000 \
    RT_DHT=off \
    RT_PEX=no \
    RT_ENCRYPTION=allow_incoming,try_outgoing,enable_retry \
    RT_CHECK_HASH=no \
    RU_USER=admin \
    RU_PASSWORD=admin \
    TOP_DIR=/data/ \
    RU_DISABLED_PLUGINS=""

# Installation des dependances runtime
RUN apk add --no-cache \
    bash \
    curl \
    shadow \
    su-exec \
    tzdata \
    # rtorrent runtime
    libcurl \
    libstdc++ \
    ncurses \
    openssl \
    zlib \
    cppunit \
    udns \
    # nginx + php
    nginx \
    php83 \
    php83-fpm \
    php83-json \
    php83-ctype \
    php83-curl \
    php83-mbstring \
    php83-session \
    php83-sockets \
    php83-phar \
    php83-openssl \
    php83-xml \
    php83-dom \
    php83-simplexml \
    php83-zlib \
    php83-fileinfo \
    # outils
    mediainfo \
    ffmpeg \
    p7zip \
    zip \
    unzip \
    sox \
    procps \
    htop \
    python3 \
    py3-pip

# Installer cloudscraper pour le plugin _cloudflare
RUN pip3 install --break-system-packages cloudscraper

# Creer un wrapper unrar (utilise 7z)
RUN echo '#!/bin/sh' > /usr/local/bin/unrar && \
    echo 'exec 7z x "$@"' >> /usr/local/bin/unrar && \
    chmod +x /usr/local/bin/unrar

# Copier rtorrent, libtorrent et xmlrpc-c compiles depuis le builder
COPY --from=builder /usr/local/bin/rtorrent /usr/local/bin/rtorrent
COPY --from=builder /usr/local/bin/xmlrpc-c-config /usr/local/bin/
COPY --from=builder /usr/local/lib/libtorrent* /usr/local/lib/
COPY --from=builder /usr/local/lib/libxmlrpc* /usr/local/lib/
COPY --from=builder /usr/local/include/xmlrpc* /usr/local/include/
RUN ldconfig /usr/local/lib || true

# Telecharger ruTorrent v5.3.13
WORKDIR /var/www
RUN apk add --no-cache git && \
    git clone --depth 1 --branch v5.3.13 https://github.com/Novik/ruTorrent.git rutorrent && \
    rm -rf rutorrent/.git && \
    apk del git

# Creer les dossiers necessaires
RUN mkdir -p \
    /config/rtorrent/.session \
    /config/rtorrent/log \
    /config/rutorrent \
    /data/torrents \
    /data/watch \
    /run/nginx \
    /run/php \
    /var/run/rtorrent

# Lien symbolique pour php
RUN ln -sf /usr/bin/php83 /usr/bin/php

# Copier l'entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Ports
EXPOSE 8080 50000

# Volumes
VOLUME ["/config/rtorrent", "/config/rutorrent", "/data"]

# Entrypoint
ENTRYPOINT ["/entrypoint.sh"]
