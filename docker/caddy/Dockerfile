# Custom Caddy build with DNS-01 (Cloudflare) and S3 cert storage plugins.
# Build with: docker build -t irl-caddy:2.11.2-custom .
# Import to k3s: docker save irl-caddy:2.11.2-custom | sudo k3s ctr images import -

FROM caddy:2.11.2-builder AS builder
RUN xcaddy build v2.11.2 \
    --with github.com/caddy-dns/cloudflare@v0.2.4 \
    --with github.com/techknowlogick/certmagic-s3@v1.4.1

FROM caddy:2.11.2-alpine
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
