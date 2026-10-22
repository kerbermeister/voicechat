FROM livekit/livekit-server@sha256:89ca9ce0791e18d6e03bf6e2c49ceb27e1c754eae8bd50c989386c1a5963791a AS sfu
FROM python:3.13-slim-bookworm@sha256:a881a81282cca8c57f97014867fa651def1b3799030cc6b1cff45ed55ba8ef36
COPY --from=sfu /livekit-server /usr/local/bin/livekit-server
WORKDIR /work
COPY prototype/token_server.py prototype/call_control.py prototype/scheduled_messages.py prototype/contacts.py prototype/link_preview.py prototype/client_policy.py prototype/client-policy.json ./prototype/
COPY infra/supervise.py ./infra/supervise.py
RUN mkdir -p /work/.prototype && chown 10001:10001 /work/.prototype
USER 10001:10001
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 VOICECHAT_BIND=0.0.0.0 VOICECHAT_LAB=0
ENTRYPOINT ["python3", "infra/supervise.py"]
