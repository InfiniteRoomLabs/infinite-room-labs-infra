# agent-box: Claude Code + the homelab toolchain, in a container

A Linux container that runs Claude Code and everything the IaC in this repo
needs (mise-pinned terraform/terragrunt/packer/helm/kubectl/task/fnox,
Ansible with the repo's collections, Bitwarden CLI, gh, tea) as a non-root
user, with its own identity and a default-deny egress firewall. The host
only needs Docker and bash.

It follows Anthropic's dev-container guidance (non-root user, pinned CLI with
autoupdate off, `CLAUDE_CONFIG_DIR` on a named volume, no host secrets
mounted, optional iptables egress allowlist). Sources: the
[dev container guide](https://code.claude.com/docs/en/devcontainer),
[sandbox environments](https://code.claude.com/docs/en/sandbox-environments),
and the reference `.devcontainer/` in `anthropics/claude-code`.

## Quick start

```bash
cd docker/agent-box
./agent-box.sh build                    # ~10 min first time (downloads every pin)
./agent-box.sh identity --authorize-homelab --github   # print the box's key, install it
./agent-box.sh kubeconfig               # mint a box-only ServiceAccount kubeconfig
./agent-box.sh shell                    # bash inside; run `claude` and sign in once
./agent-box.sh doctor                   # everything green?
./agent-box.sh claude                   # or go straight to Claude Code
```

With [Task](https://taskfile.dev) installed the same commands are `task build`,
`task shell`, `task doctor`, `task run -- terraform version` (see `Taskfile.yml`).
Plain `docker compose run --rm box` works as well; see "Compose stack" below.

`doctor` is the acceptance test. On a fresh volume it WARNs on every
one-time login (Claude, gh, tea, bw, fnox config) and tells you the command
for each. FAIL means the image or the run flags are wrong.

## Boundary

```
host                                 container (image irl-agent-box:local)
~/Projects  ───bind, rw───────────>  /work            your repos
volume irl-agent-box-home ────────>  /home/agent      logins, keys, caches, history
(nothing else)                       /opt, /usr/local tools (image-owned, read-only in spirit)
```

Three invariants keep this maintainable:

1. **Nothing the image installs lives under `/home/agent`.** That path is a
   volume; Docker seeds it from the image once and never again. Tools go in
   `/opt` and `/usr/local` (mise data in `/opt/mise`, npm globals in
   `/opt/npm-global`, uv tools in `/opt/uv-tools`, Ansible collections in
   `/opt/ansible`).
2. **No host credential is ever mounted.** The box has its own SSH key
   (generated on first start), its own kubeconfig (a dedicated ServiceAccount),
   and its own `gh`/`tea`/`bw`/Claude logins. Each is revocable without
   touching the host: delete the ServiceAccount, remove the key from
   `authorized_keys`, or `docker volume rm irl-agent-box-home` to wipe all of it.
3. **The workspace is the only shared surface.** Whatever Claude edits under
   `/work` is on your disk immediately, exactly as with a plain checkout. The
   two mounts are declared once, in `compose.yaml`.

## Compose stack

How the box runs is declared in compose files, not assembled in bash:

| File | Role |
|------|------|
| `compose.yaml` | Base. One `x-box-common` anchor (image, mounts, caps, env, working dir) shared by three services: `box` (bash or any command), `claude`, `doctor`. `claude` and `doctor` `extends: box` and change only `command`. |
| `compose.override.yaml` | Git-ignored, yours. Auto-merged by compose when you run it directly; the wrapper adds it explicitly. Put private knobs here (workspace path, Gitea host, timezone). |
| `compose.open.yaml` | Opt-in overlay: `cap_add: !reset []` and firewall off. `./agent-box.sh compose --open run --rm box`. |
| `compose.ci.yaml` | Opt-in overlay: no workspace bind, no TTY, throwaway home volume. For a future CI lane. |
| `.env.example` | The interpolation variables, documented. Copy to `.env` only if you bypass the wrapper. |
| `Taskfile.yml` | Short names (`task doctor`) that call the wrapper. Optional. |

What compose can do for you here, and what it can't: later files merge over
earlier ones (scalars replace, lists append, `!reset` clears a list); services
inherit with `extends`; anchors share structure; `${VAR:-default}` is the only
conditional. There are no loops or if-statements, so a variant is a file or a
profile, never a flag. Set `COMPOSE_FILE=compose.yaml:compose.open.yaml` in
`.env` to make an overlay sticky for a checkout.

Always `run --rm`, never `up`: the box is a throwaway container over a
persistent volume.

## Files

| Path | Runs on | Purpose |
|------|---------|---------|
| `agent-box.sh` | host | The entry point. `build`, `shell`, `claude`, `run`, `doctor`, `identity`, `kubeconfig`, `compose`, `config`, `help`. Derives the repo-sourced values, then hands off to `docker compose`. |
| `lib/log.sh` | host | `log_info`/`log_warn`/`log_error`/`die`, stderr only, colors when a TTY. |
| `lib/paths.sh` | host | Git Bash (MSYS) path conversion, repo root lookup, `abs_path`. |
| `lib/config.sh` | host | Knobs with env > `~/.config/agent-box/env` > default precedence, plus the derived `AGENT_BOX_REPO_DIR`. Exported names are the ones `compose.yaml` interpolates. |
| `lib/docker.sh` | host | Daemon check, image helper, `dockr` (path-conversion-safe docker), `winpty` shim. |
| `image/Dockerfile` | build | `debian:trixie-slim`, user `agent` (uid 1000), every pin as an `ARG` or from the repo's `mise.toml`. |
| `image/entrypoint.sh` | container | Firewall, home skeleton, SSH identity + agent, then `exec`. |
| `image/init-firewall.sh` | container (sudo) | Default-deny egress from `allowlist.txt`. The only sudo the user has. |
| `image/allowlist.txt` | container | Hostnames, CIDRs, `@github`. One line per destination. |
| `image/doctor.sh` | container | PASS/WARN/FAIL report of tools, logins, reach, firewall. |
| `image/bashrc.sh` | container | Prompt, mise activation, history on the volume, `infra` alias. |

## Configuration

Precedence is environment variable, then `~/.config/agent-box/env` (a plain
`KEY=value` bash file), then the default. `./agent-box.sh config` prints the
effective values followed by the rendered compose configuration. The same
names are what `compose.yaml` interpolates, so a knob set for the wrapper is
the knob compose sees. (Bypassing the wrapper, compose reads `.env` instead.)

| Knob | Default | Meaning |
|------|---------|---------|
| `AGENT_BOX_IMAGE` | `irl-agent-box:local` | image tag |
| `AGENT_BOX_VOLUME` | `irl-agent-box-home` | named volume for `/home/agent` |
| `AGENT_BOX_WORKSPACE` | `$HOME/Projects` | host dir mounted at `/work` |
| `AGENT_BOX_FIREWALL` | `1` | `0` runs with unrestricted egress (no caps added) |
| `AGENT_BOX_TZ` | `$TZ` or `America/New_York` | timezone inside |
| `AGENT_BOX_KUBE_CONTEXT` | `homelab` | host kubectl context used by `kubeconfig` |
| `AGENT_BOX_SSH_USER` | from `ansible/inventory/hosts.ini` | user for `homelab-ts` in the box's ssh config |
| `AGENT_BOX_SSH_HOST` | from `mise.toml` (`HOMELAB_TAILSCALE_IP`) | host for `homelab-ts` |
| `AGENT_BOX_GIT_HOST` | empty | optional Gitea SSH hostname to add (empty skips it) |
| `AGENT_BOX_GIT_SSH_PORT` | `30022` | port for `AGENT_BOX_GIT_HOST` |

No hostname, username, or host path is written into the image or this
directory: the SSH defaults are read from files the repo already tracks, and
anything else belongs in your private `~/.config/agent-box/env`.

## Identity and secrets, in detail

- **SSH**: `entrypoint.sh` generates `~/.ssh/id_ed25519` on first start and
  regenerates `~/.ssh/config` from the `AGENT_BOX_SSH_*`/`AGENT_BOX_GIT_*`
  values on every start (`homelab-ts`, plus the Gitea host if configured).
  `identity --authorize-homelab` appends the public key to
  `~/.ssh/authorized_keys` on the homelab using the host's own SSH once;
  `--github` uses the host's `gh` once. Gitea keys are added in its web UI.
- **Kubernetes**: `kubeconfig` creates ServiceAccount `kube-system/agent-box`
  bound to `cluster-admin`, a long-lived token Secret, and writes a kubeconfig
  into the volume. Revoke: `kubectl -n kube-system delete sa agent-box` and
  `kubectl delete clusterrolebinding agent-box-admin`.
- **Bitwarden / fnox**: inside the box run `bw login`, then `bw unlock` and
  store the session in `~/.bw_session` (mode 600), which is what the repo's
  `scripts/includes/bw-session.sh` expects. Copy `~/.config/fnox/config.toml`
  from the laptop into the volume once (it declares the providers, no
  secrets). After that `fnox check`, `scripts/vault-pass.sh`, `mise run
  secrets:sync` and `ansible-playbook` all work unchanged.
- **Claude Code**: run `claude` once and sign in. `CLAUDE_CONFIG_DIR` points
  at the volume so `.claude.json` (the OAuth account) persists across
  rebuilds. Autoupdate is off; the image pin is the version.

## Network policy

`init-firewall.sh` runs at every start (needs `NET_ADMIN`/`NET_RAW`, which
the wrapper adds). It resolves each hostname in `allowlist.txt` once, adds
CIDRs as-is, expands `@github` from GitHub's published ranges, then sets
`OUTPUT DROP` with the allow set as the only exception. It self-tests that
`api.anthropic.com` answers and `example.com` does not, and refuses to start
the box otherwise.

To allow a new destination, add a line to `allowlist.txt` and rebuild.
Because names resolve once at start, a CDN that rotates addresses can fail
mid-session; restarting the box re-resolves. Ports on an allowed destination
are not restricted.

`./agent-box.sh compose --open run --rm box` runs open, for debugging only
(the `compose.open.yaml` overlay drops the caps and sets `AGENT_BOX_FIREWALL=0`).

## Maintaining

- **Bump a tool**: pins the repo already has live in `mise.toml` (one source
  of truth; the image installs from it). Everything else is an `ARG` at the
  top of `image/Dockerfile` (mise, node, uv, Claude Code, bw, tea,
  ansible-core). Rebuild after either.
- **Add a tool**: mise-installable, add it to `mise.toml`; Debian package,
  add it to the `apt-get install` list; otherwise a pinned download like
  `tea`. Keep it out of `/home/agent`.
- **Lint** (shellcheck is in the image, so the host needs nothing): `task lint`, or
  `./agent-box.sh run bash -c 'cd docker/agent-box && shellcheck -x -P SCRIPTDIR agent-box.sh lib/*.sh image/*.sh'`
- **Add a variant** (another entry command, a different mount set): a new
  service that `extends: box` in `compose.yaml`, or a new overlay file for
  anything that changes caps or mounts. Then a one-line task in `Taskfile.yml`.
- **Wipe and start over**: `docker volume rm irl-agent-box-home` (all logins
  and the SSH key go with it; revoke the k8s ServiceAccount too).

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `docker daemon is not reachable` | Start Docker Desktop. |
| `firewall setup failed` at start | Image run without `NET_ADMIN`/`NET_RAW` (compose.yaml adds them); use the wrapper or compose, or the `--open` overlay. |
| `self-test failed: api.anthropic.com is NOT reachable` | DNS inside the container is broken, or the host has no network. Check `docker run --rm debian:trixie-slim getent hosts api.anthropic.com`. |
| A tool download fails inside the box | Its host is not in `allowlist.txt`. Add it, rebuild. |
| `mise ERROR failed to parse template ... id_ed25519.pub` | The repo's `mise.toml` reads the box's public key; the entrypoint creates it on first start. If you see this, the container was started bypassing the entrypoint. |
| Git Bash: `-it` hangs or no prompt | The wrapper adds `winpty` automatically when it sees a mintty TTY; otherwise run from Windows Terminal. |
| `ssh homelab-ts` fails from inside | Run `identity --authorize-homelab` from the host, and confirm the host's Tailscale is up (the box rides the host's tunnel). |
| `kubectl` fails inside after working before | The ServiceAccount or its token Secret was deleted. Run `kubeconfig` again. |
