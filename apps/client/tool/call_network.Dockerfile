# Disposable test tooling, never used by production containers.
FROM python:3.13-slim-bookworm@sha256:a881a81282cca8c57f97014867fa651def1b3799030cc6b1cff45ed55ba8ef36
RUN apt-get update && apt-get install -y --no-install-recommends iproute2=6.1.0-3 \
    && rm -rf /var/lib/apt/lists/*
