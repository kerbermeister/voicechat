# Test tooling only; this is not a production bootstrap/base image.
FROM python:3.13-slim-bookworm@sha256:a881a81282cca8c57f97014867fa651def1b3799030cc6b1cff45ed55ba8ef36
RUN apt-get update && apt-get install -y --no-install-recommends \
    wireguard-tools=1.0.20210914-1+b1 iproute2=6.1.0-3 iputils-ping=3:20221126-1+deb12u1 \
    nftables=1.0.6-2+deb12u2 \
    systemd=252.39-1~deb12u2 python3=3.11.2-1+b1 \
    openssh-client=1:9.2p1-2+deb12u10 openssh-server=1:9.2p1-2+deb12u10 \
    && rm -f /etc/ssh/ssh_host_* \
    && rm -rf /var/lib/apt/lists/*
