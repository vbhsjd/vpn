ARG BASE_IMAGE=swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/ubuntu:22.04

# Stage 1: build microsocks
FROM ${BASE_IMAGE} AS microsocks-builder
ARG APT_MIRROR=http://repo.huaweicloud.com/ubuntu

RUN set -eux; \
    if [ -n "${APT_MIRROR}" ]; then \
        if [ -f /etc/apt/sources.list ]; then \
            sed -i "s@http://[^ ]*archive.ubuntu.com/ubuntu@${APT_MIRROR}@g; s@http://[^ ]*security.ubuntu.com/ubuntu@${APT_MIRROR}@g" /etc/apt/sources.list; \
        fi; \
        if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then \
            sed -i "s@http://[^ ]*archive.ubuntu.com/ubuntu@${APT_MIRROR}@g; s@http://[^ ]*security.ubuntu.com/ubuntu@${APT_MIRROR}@g" /etc/apt/sources.list.d/ubuntu.sources; \
        fi; \
    fi; \
    apt-get update && apt-get install -y gcc make git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 https://github.com/rofl0r/microsocks /tmp/microsocks \
    && cd /tmp/microsocks && make

# Stage 2: runtime image
FROM ${BASE_IMAGE}
ARG APT_MIRROR=http://repo.huaweicloud.com/ubuntu

RUN set -eux; \
    if [ -n "${APT_MIRROR}" ]; then \
        if [ -f /etc/apt/sources.list ]; then \
            sed -i "s@http://[^ ]*archive.ubuntu.com/ubuntu@${APT_MIRROR}@g; s@http://[^ ]*security.ubuntu.com/ubuntu@${APT_MIRROR}@g" /etc/apt/sources.list; \
        fi; \
        if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then \
            sed -i "s@http://[^ ]*archive.ubuntu.com/ubuntu@${APT_MIRROR}@g; s@http://[^ ]*security.ubuntu.com/ubuntu@${APT_MIRROR}@g" /etc/apt/sources.list.d/ubuntu.sources; \
        fi; \
    fi; \
    apt-get update && apt-get install -y \
    libxcb-xinerama0 libxcb-xinput0 libxcb-icccm4 libxcb-image0 \
    libxcb-keysyms1 libxcb-randr0 libxcb-render-util0 libxcb-shape0 \
    libxcb-xfixes0 libxcb-sync1 libxcb-util1 libxcb-xkb1 \
    libxkbcommon-x11-0 libfontconfig1 libfreetype6 libglib2.0-0 \
    libdbus-1-3 libssl3 ca-certificates \
    iproute2 iptables net-tools procps kmod psmisc \
    expect util-linux \
    netcat-openbsd \
    xvfb x11-utils xz-utils libxcb1 libx11-xcb1 libxrender1 libxi6 libxext6 libxkbcommon0 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=microsocks-builder /tmp/microsocks/microsocks /usr/local/bin/microsocks
RUN chmod +x /usr/local/bin/microsocks

WORKDIR /opt/univpn

COPY univpn-linux-64-10781.18.1.0512.run /tmp/
RUN chmod +x /tmp/univpn-linux-64-10781.18.1.0512.run \
    && mkdir -p /usr/local/UniVPN \
    && cd /tmp \
    && tail -n +258 univpn-linux-64-10781.18.1.0512.run > UniVPN.tar.gz \
    && tar -xzf UniVPN.tar.gz -C /usr/local/UniVPN \
    && rm -f /tmp/*.run /tmp/*.tar.gz

RUN mkdir -p /usr/local/UniVPN/log /usr/local/UniVPN/config /usr/local/UniVPN/certificate \
    /root/UniVPN/config /dev/net \
    && chmod a+w /usr/local/UniVPN/log /root/UniVPN/config /usr/local/UniVPN/config \
    && chmod 755 /usr/local/UniVPN/certificate \
    && chmod u+s /usr/local/UniVPN/serviceclient/UniVPNCS \
    && mv /usr/local/UniVPN/serviceclient/libgmcrypto.so /lib/ \
    && mknod /dev/net/tun c 10 200 2>/dev/null || true \
    && chmod 600 /dev/net/tun 2>/dev/null || true

COPY entrypoint.sh healthcheck.sh configure.exp connect.exp /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh \
    /usr/local/bin/configure.exp /usr/local/bin/connect.exp

ENV HOME=/root
ENV USER=root
ENV LOGNAME=root
ENV XDG_CONFIG_HOME=/root/.config
ENV LD_LIBRARY_PATH=/usr/local/UniVPN/lib:/usr/local/UniVPN/serviceclient

EXPOSE 1080

HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
