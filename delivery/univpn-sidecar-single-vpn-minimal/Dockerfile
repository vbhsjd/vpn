ARG BASE_IMAGE=ubuntu:22.04
FROM ${BASE_IMAGE}

ARG APT_MIRROR=

RUN set -eux; \
    if [ -n "${APT_MIRROR}" ]; then \
        if [ -f /etc/apt/sources.list ]; then \
            sed -i "s@http://[^ ]*archive.ubuntu.com/ubuntu@${APT_MIRROR}@g; s@http://[^ ]*security.ubuntu.com/ubuntu@${APT_MIRROR}@g" /etc/apt/sources.list; \
        fi; \
        if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then \
            sed -i "s@http://[^ ]*archive.ubuntu.com/ubuntu@${APT_MIRROR}@g; s@http://[^ ]*security.ubuntu.com/ubuntu@${APT_MIRROR}@g" /etc/apt/sources.list.d/ubuntu.sources; \
        fi; \
    fi; \
    apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        expect \
        iproute2 \
        iptables \
        kmod \
        net-tools \
        procps \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/univpn

COPY univpn-linux-64-10781.18.1.0512.run /tmp/
RUN chmod +x /tmp/univpn-linux-64-10781.18.1.0512.run \
    && mkdir -p /usr/local/UniVPN \
    && cd /tmp \
    && tail -n +258 univpn-linux-64-10781.18.1.0512.run > UniVPN.tar.gz \
    && tar -xzf UniVPN.tar.gz -C /usr/local/UniVPN \
    && rm -f /tmp/*.run /tmp/*.tar.gz

RUN mkdir -p /usr/local/UniVPN/log /usr/local/UniVPN/config /usr/local/UniVPN/certificate /root/UniVPN/config /dev/net \
    && chmod a+w /usr/local/UniVPN/log /root/UniVPN/config /usr/local/UniVPN/config \
    && chmod 755 /usr/local/UniVPN/certificate \
    && chmod u+s /usr/local/UniVPN/serviceclient/UniVPNCS \
    && mv /usr/local/UniVPN/serviceclient/libgmcrypto.so /lib/ \
    && mknod /dev/net/tun c 10 200 2>/dev/null || true \
    && chmod 600 /dev/net/tun 2>/dev/null || true

COPY entrypoint.sh healthcheck.sh configure.exp connect.exp /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh /usr/local/bin/configure.exp /usr/local/bin/connect.exp

ENV HOME=/root
ENV USER=root
ENV LOGNAME=root
ENV XDG_CONFIG_HOME=/root/.config
ENV LD_LIBRARY_PATH=/usr/local/UniVPN/lib:/usr/local/UniVPN/serviceclient
ENV UNIVPN_CLI_ONLY=true
ENV UNIVPN_ALLOW_MANUAL_CONFIG=false
ENV UNIVPN_ENABLE_VNC=false
ENV UNIVPN_REQUIRE_TUN=true
ENV UNIVPN_AUTOGENERATE_PROFILE=true
ENV UNIVPN_BOOTSTRAP_PROFILE=true
ENV UNIVPN_READY_POLL_INTERVAL=1
ENV UNIVPN_MENU_SCAN_TIMEOUT=2
ENV UNIVPN_PROFILE_SETTLE_SECONDS=2
ENV UNIVPN_IMPORTED_PROFILE_SETTLE_SECONDS=0

HEALTHCHECK --interval=15s --timeout=5s --start-period=45s --retries=3 CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
