FROM caddy:2-alpine@sha256:24ec7b05bc532c7bb57f727030c5056e257ff7138b4b50460306819ff79362bd
COPY web /srv
# Use maximum compression once at build time instead of recompressing large assets per request.
RUN apk add --no-cache brotli \
    && find /srv -type f \( -name '*.js' -o -name '*.wasm' -o -name '*.ttf' -o -name '*.json' -o -name '*.html' -o -name '*.css' \) \
       -exec brotli -q 11 '{}' \; -exec gzip -9 -k '{}' \; \
    && apk del brotli
COPY Caddyfile /etc/caddy/Caddyfile
