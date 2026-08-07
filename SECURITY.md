# Security Policy

This is a personal homelab infrastructure repo published as a working reference. It describes real (private, tailnet-gated) infrastructure, so reports are welcome even though there is no bug bounty.

## Reporting

If you spot a security issue -- a real credential in history, an exposed surface, a dangerous default in a chart or playbook -- please open a private report via GitHub's "Report a vulnerability" (Security tab) rather than a public issue.

## Scope notes

- Secrets are never committed in plaintext: env-var secrets flow through fnox (Bitwarden-backed), cluster secrets through `scripts/bw-sync.sh` into Ansible Vault / Kubernetes Secrets. The only committed secret material is the Ansible Vault `.example` file.
- Internal hostnames, Tailscale CGNAT IPs, LAN addresses, and NodePorts in this repo are published deliberately (they are the documentation), and none of them are reachable from the public internet.
