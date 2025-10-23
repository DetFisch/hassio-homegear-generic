ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base-debian:bookworm

FROM ${BUILD_FROM}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive \
    HOMEGEAR_KEYRING_DIR=/usr/share/keyrings \
    HOMEGEAR_KEYRING=${HOMEGEAR_KEYRING_DIR}/homegear-archive-keyring.gpg \
    HOMEGEAR_REPO_URL=https://apt.homegear.eu/debian/bookworm/homegear/stable \
    HOMEGEAR_KEY_URL=https://apt.homegear.eu/Release.key

RUN touch /tmp/HOMEGEAR_STATIC_INSTALLATION \
    && touch /.dockerenv

RUN apt-get update \
    && apt-get -y install --no-install-recommends \
        wget \
        curl \
        ca-certificates \
        apt-utils \
        gnupg \
        libzip4 \
        libavahi-client3 \
        libavahi-client-dev \
        insserv \
        locales \
        lsb-release \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN echo "LC_ALL=en_US.UTF-8" >> /etc/environment \
    && echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen \
    && echo "LANG=en_US.UTF-8" > /etc/locale.conf \
    && locale-gen en_US.UTF-8

RUN install -d "${HOMEGEAR_KEYRING_DIR}" \
    && curl -fsSL "${HOMEGEAR_KEY_URL}" | gpg --dearmor -o "${HOMEGEAR_KEYRING}" \
    && echo "deb [signed-by=${HOMEGEAR_KEYRING}] ${HOMEGEAR_REPO_URL} bookworm main" > /etc/apt/sources.list.d/homegear.list \
    && apt-get update \
    && apt-get -y install --no-install-recommends \
        libhomegear-node \
        homegear \
        homegear-management \
        homegear-adminui \
        homegear-nodes-core \
        homegear-nodes-extra \
        homegear-homematicbidcos \
        homegear-homematicwired \
        homegear-insteon \
        homegear-max \
        homegear-philipshue \
        homegear-sonos \
        homegear-kodi \
        homegear-beckhoff \
        homegear-knx \
        homegear-enocean \
        homegear-intertechno \
        homegear-nanoleaf \
        homegear-ccu \
        homegear-mbus \
        homegear-influxdb \
        homegear-zwave \
        homegear-zigbee \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN rm -rf /tmp/* /var/tmp/*

RUN rm -f /etc/homegear/dh1024.pem \
    && rm -f /etc/homegear/homegear.crt \
    && rm -f /etc/homegear/homegear.key \
    && cp -R /etc/homegear /etc/homegear.config \
    && cp -R /var/lib/homegear /var/lib/homegear.data

COPY rootfs/start.sh /start.sh
RUN chmod +x /start.sh
ENTRYPOINT ["/bin/bash", "-c", "/start.sh"]

EXPOSE 2001 2002 2003

# Build arguments
ARG BUILD_ARCH
ARG BUILD_DATE
ARG BUILD_DESCRIPTION
ARG BUILD_NAME
ARG BUILD_REF
ARG BUILD_REPOSITORY
ARG BUILD_VERSION

# Labels
LABEL \
    io.hass.name="${BUILD_NAME}" \
    io.hass.description="${BUILD_DESCRIPTION}" \
    io.hass.arch="${BUILD_ARCH}" \
    io.hass.type="addon" \
    io.hass.version=${BUILD_VERSION} \
    maintainer="DetFisch" \
    org.opencontainers.image.title="${BUILD_NAME}" \
    org.opencontainers.image.description="${BUILD_DESCRIPTION}" \
    org.opencontainers.image.vendor="DetFisch" \
    org.opencontainers.image.authors="DetFisch" \
    org.opencontainers.image.licenses="MIT" \
    org.opencontainers.image.url="https://github.com/${BUILD_REPOSITORY}" \
    org.opencontainers.image.source="https://github.com/${BUILD_REPOSITORY}" \
    org.opencontainers.image.documentation="https://github.com/DetFisch/hassio-homegear-generic/blob/main/README.md" \
    org.opencontainers.image.created=${BUILD_DATE} \
    org.opencontainers.image.revision=${BUILD_REF} \
    org.opencontainers.image.version=${BUILD_VERSION}
