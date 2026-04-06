# TODO

## Security

- [ ] **Build custom Traefik image with `setcap`** -- The official Traefik Docker image lacks file capabilities on the binary, forcing us to run as root (UID 0) to bind ports 80/443. Build a custom image that adds `setcap cap_net_bind_service=+ep /usr/local/bin/traefik` (same pattern as our Caddy build), then switch `podSecurityContext.runAsUser` back to 1000 and restore the UID-based nftables output chain rules. See `docker/caddy/Dockerfile` for the Caddy equivalent (to be deleted after migration cleanup). Related: Traefik maintainers rejected adding setcap upstream (traefik/traefik-library-image#51).
