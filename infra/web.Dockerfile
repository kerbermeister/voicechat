FROM caddy:2-alpine@sha256:24ec7b05bc532c7bb57f727030c5056e257ff7138b4b50460306819ff79362bd AS runtime
FROM --platform=$BUILDPLATFORM caddy:2-alpine@sha256:24ec7b05bc532c7bb57f727030c5056e257ff7138b4b50460306819ff79362bd AS compressed
COPY web /srv
# Static bytes are architecture-independent; compress once without ARM emulation.
RUN apk add --no-cache brotli \
    && find /srv -type f \( -name '*.js' -o -name '*.wasm' -o -name '*.ttf' -o -name '*.json' -o -name '*.html' -o -name '*.css' \) \
       -exec brotli -q 11 '{}' \; -exec gzip -9 -k '{}' \; \
    && apk del brotli
FROM runtime
COPY --from=compressed /srv /srv
COPY Caddyfile /etc/caddy/Caddyfile
