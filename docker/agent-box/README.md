# agent-box: Claude Code + the homelab toolchain, in a container

A Linux container that runs Claude Code and everything the IaC in this repo
needs (mise-pinned terraform/terragrunt/packer/helm/kubectl/task/fnox,
Ansible with the repo's collections, Bitwarden CLI, gh, tea) as a non-root
user, with its own identity and an egress denylist firewall. The host
only needs Docker and bash.

It follows Anthropic's dev-container guidance (non-root user, pinned CLI with
autoupdate off, `CLAUDE_CONFIG_DIR` on a named volume, no host secrets
mounted) with one deliberate departure: egress is default-allow with a
denylist, not an allowlist, because the box is driven interactively and an
agent that cannot read docs or registries is not much of an agent. Sources: the
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

# Unattended (after signing in once, above):
./agent-box.sh batch "list the TODOs in this repo"   # one prompt, runs to the end, exits
./agent-box.sh mcp                      # Claude Code as an MCP server on stdio
```

With [Task](https://taskfile.dev) installed the same commands are `task build`,
`task shell`, `task doctor`, `task run -- terraform version` (see `Taskfile.yml`).
Plain `docker compose run --rm box` works as well; see "Compose stack" below.
`batch` and `mcp` are covered in "Unattended use" below.

`doctor` is the acceptance test. On a fresh volume it WARNs on every
one-time login (Claude, gh, tea, bw, fnox config) and tells you the command
for each. FAIL means the image or the run flags are wrong.

After signing in to Claude Code and adding the box's key to GitHub, run
`agent-box-extras` once inside the box. It installs ccsm (the infra repo's
PreToolUse/PostToolUse hooks call `ccsm-detect-secrets` and
`ccsm-check-output`; without it every Bash tool call logs a hook error) and
points the repo's `fnox` MCP server at the box's own fnox.

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
   two mounts are declared once, in `compose.yaml`. The unattended modes
   (`batch`, `mcp`) narrow it further: by default they bind only the one
   directory they were pointed at (`compose.scoped.yaml`).

## Unattended use: batch and MCP

Two ways to use the box without sitting in it:

- **`batch`** starts a box, hands the agent one prompt, lets it run until it
  decides it is done, prints its output, exits with a code that says how it
  went, and removes the container.
- **`mcp`** starts a box running Claude Code's own MCP server (`claude mcp
  serve`) on stdin/stdout, so an MCP client (Claude Code on the host,
  another agent) can call the box's tools: Bash, Read, Edit, Write, Grep,
  Glob and the rest, executed inside the box.

Both use the box's own Claude Code login from the home volume (sign in once
with `./agent-box.sh claude`; no host credential is passed in), and both
run with the same image, user, capabilities and egress denylist as an
interactive session. By default each one sees ONLY the directory it was
started for: the current directory, or `--dir DIR`. `--workspace` mounts
all of `AGENT_BOX_WORKSPACE` instead (as an interactive session does) and
starts in `--dir` inside it. The directory lands where an interactive
session would see it (`/work/<path relative to the workspace>`), so
sessions and per-project settings in the home volume are shared; a
directory outside the workspace lands at `/work/<its name>`. `batch` and
`mcp` refuse to mount `/`, a drive root, or your home directory.

The examples call the wrapper by path from the directory you want the
agent in. Put `docker/agent-box` on your PATH or alias it
(`alias agent-box=~/Projects/infinite-room-labs-infra/docker/agent-box/agent-box.sh`)
to shorten them.

### Batch: one prompt, run to completion

```bash
cd ~/Projects/some-repo      # the agent works here, and sees only this

# Prompt as arguments (joined with spaces)
agent-box.sh batch "run the unit tests and fix whatever fails"

# Prompt from a file
agent-box.sh batch --prompt-file task.md

# Prompt from stdin: a pipe, or --prompt-file -
{ echo "Review this diff for bugs:"; git diff; } | agent-box.sh batch

# Somewhere else, without cd
agent-box.sh batch --dir ~/Projects/other-repo "summarize the README"
```

The agent's final answer goes to stdout; progress (container start,
firewall self-test, a one-line summary with turns, cost and session id)
goes to stderr. So `agent-box.sh batch "..." > answer.md` captures just the
answer.

**JSON for programs.** `-o json` prints exactly one JSON object: Claude
Code's own `--output-format json` result (`result`, `is_error`, `subtype`,
`num_turns`, `total_cost_usd`, `session_id`, `permission_denials`, ...).
If claude produced no result at all (timeout, crash) you still get one
object, with `is_error: true` and `subtype` `error_timeout` or
`error_no_result`, so stdout always parses. `-o stream-json` streams every
message as it happens, one JSON object per line; the last line is the result.

```bash
agent-box.sh batch -o json "list the open TODOs as a JSON array" > out.json
echo "exit $?"; jq -r .result out.json
```

**Limits.**

```bash
agent-box.sh batch --timeout 10m --max-turns 30 "upgrade the helm chart pins"
```

`--timeout` is the agent's wall clock (`600`, `90s`, `30m`, `2h`; `0` for
none; default `AGENT_BOX_BATCH_TIMEOUT`, 30m). The box's few seconds of
start-up are not counted. On expiry claude gets SIGTERM, then SIGKILL 30s
later, and the run exits 124. `--max-turns` caps agent turns (default
`AGENT_BOX_BATCH_MAX_TURNS`, empty = Claude Code's own limit); hitting it
exits 3.

**Permissions.** Nobody is there to answer a permission prompt, so anything
that would prompt is denied (`claude --permission-prompts none`).
`--permission-mode` decides what prompts in the first place:

| Mode | What the agent may do unattended |
|------|----------------------------------|
| `acceptEdits` (default) | Read and edit files in the mounted directory. Most Bash commands and web fetches would prompt, so they are denied, except what the project's `.claude/settings.json` allows or you grant with `--allowedTools`. |
| `plan` | Read and plan only; no changes. |
| `auto` | Claude Code's auto mode (a classifier approves what it judges safe), if your account has it. |
| `bypassPermissions` | Everything, no checks. The wrapper prints a warning. Read "Security" below first. |

Grant specific tools, and pass any other claude flag, with `-a` (repeatable;
each `-a` is one argument):

```bash
agent-box.sh batch -a --allowedTools -a "Bash(npm test *) Bash(git diff *)" "make the tests pass"
agent-box.sh batch -a --model -a sonnet -a --max-budget-usd -a 2 "..."
```

**Continuing a run.** Sessions are saved in the home volume, keyed by the
in-box directory, so a follow-up with the same `--dir` can resume one (the
id is in the stderr summary and in the JSON as `session_id`):

```bash
agent-box.sh batch -a --resume -a 21432e57-... "now write the changelog entry"
```

**Exit codes.**

| Code | Meaning | stdout |
|------|---------|--------|
| 0 | the agent finished and reported success | the result |
| 2 | the agent finished with an error (API error, not logged in, ...) | the result (the error text) |
| 3 | `--max-turns` reached before it finished | json: the result object; text: empty |
| 4 | claude exited without producing a result | json: a synthetic `error_no_result` object |
| 124 | `--timeout` expired; the agent was killed | json: a synthetic `error_timeout` object |
| 64 | usage error (bad option, no prompt, refused `--dir`) | empty |
| 1 | the box could not start: docker down, image missing, firewall failed | empty; the reason is on stderr |

With Task: `task batch -- -o json "fix the lint errors"` (Task passes the
directory you ran it from as `--dir`; a `--dir` of your own wins).

### MCP: the box as a stdio MCP server

`agent-box.sh mcp` runs `claude mcp serve` inside the box on the wrapper's
own stdin/stdout. Register the wrapper as the server command. Claude Code
starts MCP servers in the directory it was launched from, so that directory
is what the box mounts; add `--dir DIR` to the args to pin one instead.

Linux / macOS:

```bash
claude mcp add agent-box -s user -- bash ~/Projects/infinite-room-labs-infra/docker/agent-box/agent-box.sh mcp
```

Windows (from Git Bash or PowerShell). Give the full path to Git for
Windows' `bash.exe` (the standard install is shown; scoop puts it under
`scoop\apps\git\current\usr\bin\bash.exe`): a bare `bash` can resolve to
WSL's `C:\Windows\System32\bash.exe`, which is a different Linux with its
own paths.

```bash
claude mcp add agent-box -s user -- "C:\Program Files\Git\bin\bash.exe" "C:\Users\you\Projects\infinite-room-labs-infra\docker\agent-box\agent-box.sh" mcp
```

Put the server name first: `claude mcp add <name> [-s scope] [-e KEY=value]
-- <command> [args...]`. `-e` takes several values and swallows a name that
comes after it. Knobs go in with `-e`, for example
`-e AGENT_BOX_IMAGE=irl-agent-box:local`.

Check it: `claude mcp get agent-box` should say `Connected`. The first start
takes about five seconds (the firewall self-test); if a client gives up
sooner, raise its start-up timeout (Claude Code: `MCP_TIMEOUT=60000 claude`).

The same server as JSON, for `.mcp.json` or `claude mcp add-json`. The
relative path works in THIS repo's `.mcp.json`, because Claude Code starts
project servers in the project root; anywhere else use an absolute path and
keep it in user or local scope rather than a committed file.

```json
{
  "mcpServers": {
    "agent-box": {
      "type": "stdio",
      "command": "bash",
      "args": ["docker/agent-box/agent-box.sh", "mcp"],
      "env": { "AGENT_BOX_IMAGE": "irl-agent-box:local" }
    }
  }
}
```

Without the wrapper (any MCP client, any host with Docker; `-i` without
`-t` is required, a TTY corrupts the stream). You give up the SSH values
the wrapper derives from the repo (no `homelab-ts` inside) and its cleanup
on kill; `--rm` still removes the container when the client closes stdin.

```bash
claude mcp add-json agent-box '{"type":"stdio","command":"docker","args":["run","-i","--rm","--init","--cap-add","NET_ADMIN","--cap-add","NET_RAW","-v","irl-agent-box-home:/home/agent","-v","/home/you/Projects/some-repo:/work/some-repo","-w","/work/some-repo","irl-agent-box:local","claude","mcp","serve"]}' -s user
```

(`-s` goes after the JSON for `add-json`. On Windows write the bind source
with forward slashes, `C:/Users/you/Projects/some-repo:/work/some-repo`,
and run it from PowerShell or with `MSYS_NO_PATHCONV=1` in Git Bash so the
container paths are not rewritten.)

Each client session gets its own container. It ends when the client closes
stdin or kills the wrapper, and the wrapper removes it either way.

### How the unattended modes work

```
host   agent-box.sh batch|mcp [--dir DIR | --workspace]
         resolve DIR -> AGENT_BOX_MOUNT_SRC / AGENT_BOX_MOUNT_DST / AGENT_BOX_REPO_DIR
         docker compose [-f compose.scoped.yaml] run --rm -i -T --name agent-box-<mode>-<pid>-<n> batch|mcp ...
           (in the background; traps on EXIT/INT/TERM/HUP `docker rm -f` the named container)
box    tini -> entrypoint: stdout parked on fd 3, fd 1 -> stderr
                 firewall (denylist + self-test), home skeleton, ssh key + agent
              -> exec with stdout restored:
                 mcp:   claude mcp serve                          JSON-RPC on stdin/stdout
                 batch: agent-box-batch                           prompt on stdin
                          -> timeout DUR claude -p --output-format json|stream-json
                          -> result to stdout, outcome to the exit code
```

**stdout carries only the payload.** A program reads it (the MCP protocol,
the batch result), so nothing else may write there:

- No TTY (`tty: false` on the services, `-T` on the run). A TTY would merge
  stderr into stdout and turn `\n` into `\r\n`.
- The entrypoint runs its whole setup with fd 1 pointed at stderr and only
  restores the real stdout in the final `exec`, so a chatty tool cannot
  leak a line into the stream. The `ssh-agent` daemon does not inherit it.
- The wrapper logs through `lib/log.sh` (stderr only) and never uses
  winpty here; compose's own `Container ... Creating` lines go to stderr.
- `agent-box-batch` prefixes its lines with `agent-box-batch:` on stderr.

`tests/unattended.sh` checks this directly: every line the MCP server
writes parses as JSON-RPC, and a batch `-o json` run prints exactly one
object.

**Outcome, not exit status.** Claude Code's own exit status is a plain 0/1,
which cannot tell "out of turns" from "failed". The runner always runs claude with a JSON
output format and reads the `result` message: `subtype: error_max_turns`
(or `terminal_reason: max_turns`) is 3, `is_error` or any other `error_*`
subtype is 2, else 0. Text mode prints that object's `result` field. Exit
1 is never produced by the runner, so it keeps its meaning, "the box could
not run" (the entrypoint exits 1 if the firewall fails; the wrapper exits 1
if docker or the image is missing).

**The timeout lives in the box.** GNU `timeout` wraps claude inside the
container, so it behaves the same on Linux, macOS (which has no `timeout`)
and Git Bash, and the start-up self-test does not eat into it. The wrapper
handles the other direction: Ctrl-C, SIGTERM or SIGHUP to it removes the
container. compose runs as a background job so bash can act on a signal
while waiting (it defers traps until a foreground child exits), and stdin
is passed through explicitly because an async job otherwise gets
`/dev/null`. When a Windows client kills the wrapper outright (no signal to
trap), stdin closes, the server exits, and `--rm` removes the container.

**The prompt travels on stdin**, never in argv: no size limit, no quoting
problems, and it does not show up in `docker ps` or `docker inspect`.

### Security

Everything the interactive box guarantees holds for `batch` and `mcp`,
because they are the same service with the command changed and the TTY off:
non-root user, `NET_ADMIN`/`NET_RAW` only for the firewall script, the
egress denylist applied and self-tested at every start (a failed firewall
aborts the run with exit 1), no host credentials mounted. There is no
`--open` shortcut on `batch` or `mcp`; `AGENT_BOX_FIREWALL=0` in your config
is still honoured (the entrypoint says so on stderr).

What is different is that nobody is watching. Two consequences:

- **Only one directory is mounted by default**, so a run can only change
  the project it was pointed at. `--workspace` restores the interactive
  surface; use it on purpose.
- **The home volume is the box's identity.** It holds the box's SSH key
  (authorized on the homelab and GitHub if you installed it), its
  cluster-admin kubeconfig, and its gh/tea/bw logins. An unattended run can
  use all of them. With the default `acceptEdits` mode shell commands are
  denied unless allowed, which limits that; with `bypassPermissions`,
  nothing does, and egress is default-allow, so data can leave to any
  destination not on the denylist. For prompts you do not fully trust, give
  unattended runs a volume that holds only a Claude login:

  ```bash
  AGENT_BOX_VOLUME=irl-agent-box-batch ./agent-box.sh claude   # once: sign in, nothing else
  AGENT_BOX_VOLUME=irl-agent-box-batch ./agent-box.sh batch --permission-mode bypassPermissions "..."
  ```

In MCP mode the client decides what to call, and the client's own
permission rules apply on the host side (Claude Code asks before calling an
MCP tool unless you allowed it). The design record, including why the
denylist was kept rather than switching unattended runs to an allowlist, is
`docs/plans/2026-09-25-agent-box-batch-mcp-design.md`.

## Compose stack

How the box runs is declared in compose files, not assembled in bash:

| File | Role |
|------|------|
| `compose.yaml` | Base. One `x-box-common` anchor (image, mounts, caps, env, working dir) shared by five services: `box` (bash or any command), `claude`, `doctor`, `batch`, `mcp`. The last four `extends: box` and change only `command` (and, for `batch`/`mcp`, `tty: false`). |
| `compose.override.yaml` | Git-ignored, yours. Auto-merged by compose when you run it directly; the wrapper adds it explicitly. Put private knobs here (workspace path, Gitea host, timezone). |
| `compose.open.yaml` | Opt-in overlay: `cap_add: !reset []` and firewall off. `./agent-box.sh compose --open run --rm box`. |
| `compose.ci.yaml` | Opt-in overlay: no workspace bind, no TTY, throwaway home volume. For a future CI lane. |
| `compose.scoped.yaml` | Overlay for `batch`/`mcp`, added by the wrapper unless you pass `--workspace`: the home volume plus ONE bind, `AGENT_BOX_MOUNT_SRC` at `AGENT_BOX_MOUNT_DST`. Caps, env and firewall untouched. |
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
| `agent-box.sh` | host | The entry point. `build`, `shell`, `claude`, `run`, `doctor`, `batch`, `mcp`, `identity`, `kubeconfig`, `compose`, `config`, `help`. Derives the repo-sourced values, then hands off to `docker compose`. |
| `lib/log.sh` | host | `log_info`/`log_warn`/`log_error`/`die`, stderr only, colors when a TTY. |
| `lib/paths.sh` | host | Git Bash (MSYS) path conversion, repo root lookup, `abs_path`. |
| `lib/config.sh` | host | Knobs with env > `~/.config/agent-box/env` > default precedence, plus the derived `AGENT_BOX_REPO_DIR`. Exported names are the ones `compose.yaml` interpolates. |
| `lib/docker.sh` | host | Daemon check, image helper, `dockr` (path-conversion-safe docker), `winpty` shim. |
| `image/Dockerfile` | build | `debian:trixie-slim`, user `agent` (uid 1000), every pin as an `ARG` or from the repo's `mise.toml`. |
| `image/entrypoint.sh` | container | Firewall, home skeleton, SSH identity + agent, then `exec`. All of its own output goes to stderr; stdout belongs to the exec'd command. |
| `image/batch.sh` | container | `agent-box-batch`: the in-box half of `batch`. Prompt on stdin, `claude -p` under `timeout`, result to stdout, outcome to the exit code. |
| `image/init-firewall.sh` | container (sudo) | Egress denylist from `denylist.txt` (default allow). The only sudo the user has. |
| `image/denylist.txt` | container | Hostnames, IPs, CIDRs to block. One line per destination. Ships with cloud metadata endpoints and the `example.com` canary. |
| `image/doctor.sh` | container | PASS/WARN/FAIL report of tools, logins, reach, firewall, extras. |
| `image/extras.sh` | container | `agent-box-extras`: volume-scoped installs the image can't bake in. ccsm (private repo, over the box's SSH key) for the infra repo's Claude Code hooks, and a local-scope `fnox` MCP override (the committed `.mcp.json` points at a laptop path). Idempotent; rerun after a volume wipe. |
| `image/bashrc.sh` | container | starship prompt, mise activation, history on the volume, `infra` alias, `bw-unlock`/`bw-lock`. |
| `image/starship.toml` | container | Baseline prompt config (stock starship plus always-on `user@host`). Seeded to `~/.config/starship.toml` on first start; edit the volume copy. |
| `tests/unattended.sh` | host | Smoke test for `batch` and `mcp` on a throwaway volume (no login, no model calls). `task test`. |

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
| `AGENT_BOX_BATCH_TIMEOUT` | `30m` | `batch` default for `--timeout` (`90s`, `30m`, `2h`; `0` = none) |
| `AGENT_BOX_BATCH_MAX_TURNS` | empty | `batch` default for `--max-turns` (empty = Claude Code's own limit) |
| `AGENT_BOX_BATCH_PERMISSION_MODE` | `acceptEdits` | `batch` default for `--permission-mode` |
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

Default allow, denylist. `init-firewall.sh` runs at every start (needs
`NET_ADMIN`/`NET_RAW`, which the wrapper adds). It resolves each hostname in
`denylist.txt` once, adds IPs and CIDRs as-is, and inserts one `REJECT` rule
for that set at the top of `OUTPUT`; everything else is allowed, so the agent
can read docs, pull from registries, and call APIs without a list to maintain.
It self-tests that `api.anthropic.com` answers and the `example.com` canary
does not, and refuses to start the box otherwise.

The shipped list blocks cloud/instance metadata endpoints (the classic
credential-theft target) and keeps `example.com` as the canary. To block a
new destination, add a line and rebuild. Names resolve once at start, so a
blocked service that rotates addresses can slip through until a restart.

This is a deliberate departure from Anthropic's reference container, whose
allowlist exists for unattended `--dangerously-skip-permissions` runs. If
you ever run the box that way, the allowlist version is in git history
(before 2026-09-17) and drops back in as a replacement `init-firewall.sh`.
`batch --permission-mode bypassPermissions` is exactly that case; the box
does not switch lists for it (see "Unattended use: Security" for what does
and does not protect such a run, and the design doc for why).

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
  `./agent-box.sh run bash -c 'cd docker/agent-box && shellcheck -x -P SCRIPTDIR agent-box.sh lib/*.sh image/*.sh tests/*.sh'`
- **Test the unattended modes**: `task test`, or `./tests/unattended.sh`
  (about two minutes; throwaway volume, no login needed, no model calls).
  Run it after touching the entrypoint, `batch.sh`, the compose services
  or the wrapper's `batch`/`mcp` code. `doctor` stays the acceptance test
  for the interactive box.
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
| A download or API call fails inside the box | Check `denylist.txt` first (default is allow, so it's usually DNS or the host network, not the firewall); `doctor` probes a docs site to tell the two apart. |
| `mise ERROR failed to parse template ... id_ed25519.pub` | The repo's `mise.toml` reads the box's public key; the entrypoint creates it on first start. If you see this, the container was started bypassing the entrypoint. |
| Git Bash: `-it` hangs or no prompt | The wrapper adds `winpty` automatically when it sees a mintty TTY; otherwise run from Windows Terminal. |
| `ssh homelab-ts` fails from inside | Run `identity --authorize-homelab` from the host, and confirm the host's Tailscale is up (the box rides the host's tunnel). |
| `kubectl` fails inside after working before | The ServiceAccount or its token Secret was deleted. Run `kubeconfig` again. |
| `batch` exits 2, result says `Not logged in` | The volume has no Claude login. `./agent-box.sh claude` once and sign in (same `AGENT_BOX_VOLUME` as the batch run). |
| `batch` exits 1 with nothing on stdout | The box never ran the agent. stderr says why: docker down, image not built, or the firewall failed at start. |
| `batch` exits 3 / 124 | Turn limit / timeout. Raise `--max-turns` / `--timeout`, or split the task. The JSON result has `num_turns` and `session_id` to resume from. |
| `batch` finishes but did not run commands | `acceptEdits` denies anything that would prompt, including most Bash. See `permission_denials` in `-o json`; grant with `-a --allowedTools -a "Bash(...)"` or choose another `--permission-mode`. |
| `batch: no prompt` | Pass the prompt as words, with `--prompt-file`, or on a pipe. An interactive terminal on stdin is not read. |
| `refusing to mount your whole home directory` | `batch`/`mcp` ran from `~` (Claude Code started there, for MCP). `cd` into a project or pass `--dir`. |
| `claude mcp get agent-box` shows `Failed to connect` | Run the registered command by hand with `</dev/null` to see its stderr. On Windows check the `bash.exe` path (not WSL's). If it is only slow, raise `MCP_TIMEOUT`. |
| `git` fails in a batch/mcp run on a git worktree | A worktree's `.git` is a file pointing at the main checkout's `.git/worktrees/...`, which is not mounted (and on Windows is a `C:/` path Linux cannot resolve). Point `--dir` at a normal checkout. |
| Containers named `agent-box-batch-*` / `agent-box-mcp-*` linger | Only if the wrapper and docker were both killed hard. `docker ps -a --filter name=agent-box-` and `docker rm -f` them. |
