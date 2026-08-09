# Caddy with the Cloudflare DNS module — needed for DNS-01 ACME challenges
# so the internal-only planner hostname gets a real Let's Encrypt cert
# without ever being reachable (or resolvable) from the internet.
FROM caddy:2-builder AS builder

RUN xcaddy build --with github.com/caddy-dns/cloudflare

FROM caddy:2

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
