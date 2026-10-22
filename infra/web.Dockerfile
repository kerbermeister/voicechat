FROM caddy:2-alpine@sha256:24ec7b05bc532c7bb57f727030c5056e257ff7138b4b50460306819ff79362bd
COPY web /srv
COPY Caddyfile /etc/caddy/Caddyfile
