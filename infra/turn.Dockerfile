ARG TURN_BASE_IMAGE
FROM ${TURN_BASE_IMAGE} AS build
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    autoconf g++ git libtool make pkg-config libevent-dev libssl-dev \
    libpq-dev libmariadb-dev libsqlite3-dev libhiredis-dev libmongoc-dev libmicrohttpd-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY source.tar.gz udp-eperm.patch checksums.txt ./
RUN sha256sum -c checksums.txt && mkdir app \
    && tar -xzf source.tar.gz --strip-components=1 --no-same-owner -C app \
    && cd app && git apply --check ../udp-eperm.patch && git apply ../udp-eperm.patch
WORKDIR /src/app
# Match the official 4.18.0 Debian build, including all database/TLS features.
RUN CFLAGS="-O3" ./configure --prefix=/usr --turndbdir=/var/lib/coturn \
    --disable-rpath --sysconfdir=/etc/coturn --mandir=/tmp/coturn/man \
    --docsdir=/tmp/coturn/docs --examplesdir=/tmp/coturn/examples \
    && make -j2 && make check

FROM ${TURN_BASE_IMAGE}
USER root
COPY --from=build /src/app/bin/turnserver /usr/bin/turnserver
# Keep the upstream unprivileged execution contract and file capability.
RUN apt-get update && apt-get install -y --no-install-recommends libcap2-bin \
    && setcap CAP_NET_BIND_SERVICE=+ep /usr/bin/turnserver \
    && apt-get purge -y --auto-remove libcap2-bin \
    && rm -rf /var/lib/apt/lists/* \
    && /usr/bin/turnserver --version
LABEL org.opencontainers.image.version="4.18.0-vc-eperm1" \
    org.voicechat.turn.patch="1208eba162dfba2380d84463eb64955a59028aae"
USER nobody:nogroup
