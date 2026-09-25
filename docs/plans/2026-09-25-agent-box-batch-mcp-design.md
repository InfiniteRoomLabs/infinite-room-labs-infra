# Agent Box: Batch and MCP Modes

**Date**: 2026-09-25
**Status**: Built, pending review
**Author**: Wes Gilleland + Claude Opus 5.5
**Relates to**: `docker/agent-box/README.md` ("Unattended use"), `docs/plans/2026-09-15-agent-box-design.md` (the box itself), Claude Code's [CLI reference](https://code.claude.com/docs/en/cli-reference) (`-p`, `--output-format`, `--permission-mode`) and [MCP docs](https://code.claude.com/docs/en/mcp) (`claude mcp serve`)

## Overview

The box was built to be driven by a person at a terminal. This adds two ways
to drive it without one:

- `agent-box.sh mcp`: Claude Code's own MCP server (`claude mcp serve`) in the
  box, on the wrapper's stdin/stdout, so a host MCP client can use the box's
  tools. Registered with the wrapper as the server command.
- `agent-box.sh batch`: start a box, give the agent one prompt (words, a
  file, or stdin), let it run until it decides it is done, print its output
  (text, one JSON object, or stream-json), exit with a code that describes
  the outcome, and remove the container.

Everything the interactive box guarantees carries over, because both are
compose services that `extends: box` and change only the command and the
TTY. The design questions were about the new surface: what gets mounted,
what the agent may do with nobody watching, how the outcome is reported,
and how to keep stdout clean.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Where the modes are defined | Two compose services, `batch` and `mcp`, `extends: box`, `tty: false` | The 2026-09-15 addendum made compose the one place the run is defined and variants a service or an overlay. Same caps, env, user, firewall, volume by construction; `compose config` shows the truth. The open and ci overlays list them too (extends resolves per file). |
| Wrapper arg parsing | Hand-rolled `case` loop, not `usage` | The wrapper is deliberately bash + docker only (design doc: must work on a fresh Windows host before mise/usage exist). `usage` would break that for the two modes most likely to be called from another machine's agent. |
| Mount for unattended runs | Only the target directory by default (`--dir`, default cwd), via a `compose.scoped.yaml` overlay; `--workspace` opts back into the whole workspace | An interactive session has a person watching; a batch run or an MCP client does not. Scoping to one project is the cheapest blast-radius cut available and matches how both are invoked (Claude Code starts MCP servers in the project dir). The overlay uses `volumes: !override` like `compose.ci.yaml`, so only the mount set changes. |
| In-box path of the directory | `/work/<path relative to the workspace>` (else `/work/<basename>`) | Claude Code keys sessions and per-project state by absolute path. Matching the interactive path lets a batch run resume a session and see the same project settings; verified by resuming a batch session by id. |
| Refused mounts | `/`, drive roots, `$HOME` | A mistake (running from `~`) should fail loudly, not mount every file the user owns into an unattended agent. |
| Transport for MCP | `claude mcp serve` on the wrapper's stdio, container `-i -T` | That is the transport Claude Code itself uses, and every MCP client speaks stdio. No port, no listener, nothing new on the network. |
| MCP server lifetime | A small in-box relay, `agent-box-mcp` (`image/mcp.sh`): stdin goes to `claude mcp serve` through a FIFO; on client EOF the server gets 5s, then SIGTERM, exit 0 | Found in testing: `claude mcp serve` 2.1.273 does not exit when stdin closes before the handshake completes, which is what `claude mcp get` (a health check) does, and a Windows client terminating the wrapper orphans the docker client. Each check left a running container. Tried first: a host-side watchdog subshell polling the wrapper; Claude Code on Windows kills it along with the wrapper while the docker client survives, so the fix has to live where the EOF is certain to arrive, in the box. |
| stdout discipline | Entrypoint parks stdout on fd 3 and sends fd 1 to stderr during setup, restoring it only in the final `exec`; services are `tty: false`; the wrapper and runner log to stderr only | Making it structural beats auditing every tool the entrypoint calls (`ssh-keygen`, `ssh-add`, `sudo`, `iptables`, `curl`). No change for interactive use: both fds are the terminal there. The `ssh-agent` daemon is started with fd 3 closed so it cannot hold the stream open. |
| Batch runner location | A small in-box script, `agent-box-batch` (`image/batch.sh`) | It needs `jq` and GNU `timeout`, both in the image and neither guaranteed on the host (the host needs only docker). Keeps the wrapper free of JSON handling. |
| Outcome reporting | Always run `claude -p` with `--output-format json` or `stream-json`; read the `result` message; map to 0 / 2 (error) / 3 (max turns) / 4 (no result) / 124 (timeout); 64 usage; 1 reserved for "box could not start" | Claude Code's exit status is a plain 0/1 (an error result such as "Not logged in" exits 1, checked against 2.1.273), so it cannot tell a caller whether to retry with more turns or give up. `subtype` and `terminal_reason` can. Leaving 1 unused by the runner keeps it meaning "infrastructure failed", which is what the entrypoint and the wrapper already exit with. |
| JSON always parses | On timeout or crash, json/stream-json modes print a synthetic `{"type":"result","is_error":true,"subtype":"error_timeout"/"error_no_result"}` | An agent caller should not need a second code path for "stdout was empty". |
| Prompt transport | stdin into the container, then stdin into `claude -p` | No argv size limit, no quoting across bash, compose and Git Bash, and the prompt is not visible in `docker ps`/`inspect`. |
| Timeout enforcement | GNU `timeout` in the box, TERM then KILL after 30s; default 30m (`AGENT_BOX_BATCH_TIMEOUT`); 0 disables | Identical on Linux, macOS (no `timeout` there) and Git Bash. The firewall self-test at start is not charged to the agent. |
| Turn limit | `--max-turns` passed through (hidden but accepted by Claude Code 2.1.273); no default | A default turn cap would be a guess about task size; the wall-clock timeout is the safety net. Knob `AGENT_BOX_BATCH_MAX_TURNS` for people who want one. |
| Cleanup | Named container (`agent-box-<mode>-<pid>-<n>`), `run --rm`, and wrapper traps on EXIT/INT/TERM/HUP that `docker rm -f` it; compose runs as a background job with stdin passed explicitly (`0<&0`) | bash defers traps while a foreground child runs, and an async job gets `/dev/null` for stdin unless told otherwise. Verified: SIGTERM to the wrapper removes the container; a Windows client killing the process outright (no signal) closes stdin, `agent-box-mcp` stops the server, `--rm` removes it. |
| Windows PATH | The wrapper prepends `/usr/bin` when it is missing | A Windows program starting Git's `usr\bin\bash.exe` directly passes the Windows PATH, so `uname`/`cygpath` were missing and every host path handed to docker came out as `C:\c\Users\...`. Git's `bin\bash.exe` launcher sets PATH itself; the fix makes either work. |
| Default permission mode | `acceptEdits`, plus `--permission-prompts none` | Useful out of the box (read and edit the mounted project) without making shell commands and web fetches silently allowed. Callers widen it deliberately: `--allowedTools` via `-a`, `auto`, or `bypassPermissions` (warned on stderr). |
| Egress for unattended runs | Keep the denylist; do NOT switch to an allowlist for batch | See trade-off below. |
| Credentials | The box's own Claude login from the home volume; nothing from the host | Invariant 2 of the box. `ANTHROPIC_API_KEY` passthrough was left out on purpose; if wanted later it belongs in fnox, injected per run. |

## Trade-off: denylist egress under unattended `bypassPermissions`

The README of the box says the denylist was chosen because the box is driven
interactively, and that Anthropic's allowlist exists for unattended
`--dangerously-skip-permissions` runs. `batch --permission-mode
bypassPermissions` is that case. Options considered:

1. **Switch batch to an allowlist firewall.** Strongest against
   exfiltration, but it brings back exactly what the 2026-09-17 change
   removed: an agent that cannot read docs or registries, and a list to
   curate. It would also make batch behave differently from the
   interactive box for the same task, which defeats "try it interactively,
   then automate it".
2. **Refuse `bypassPermissions` in batch.** Safe, but the permission modes
   are Claude Code's own control; forbidding one pushes people to
   `--workspace` plus wide `--allowedTools`, which is not safer.
3. **Keep the denylist, narrow everything else, say so loudly** (chosen).
   Default mode is `acceptEdits`; only the target directory is mounted;
   bypass prints a warning naming what still holds; the README documents
   that the home volume carries the box's SSH key, cluster-admin kubeconfig
   and gh/tea/bw logins, and gives the recipe for a separate volume holding
   only a Claude login (`AGENT_BOX_VOLUME=irl-agent-box-batch`).

Explicitly not weakened: the firewall still starts and self-tests on every
run, a failed firewall aborts the run, and there is no `--open` shortcut on
`batch` or `mcp` (`AGENT_BOX_FIREWALL=0` in config is still honoured, as it
is for every other subcommand).

## Verification (2026-09-25, Windows 10 host, Docker 29.6.2, Compose v5.3.1)

- `tests/unattended.sh` (new, throwaway volume, no model calls): 25 checks
  pass, covering usage errors, stdout purity for batch json/text and MCP,
  the exit-code mapping (against a fake `claude`), the scoped mount set, and
  container removal on stdin EOF (after a handshake and before one) and on
  SIGTERM.
- Native Windows client (a .NET process standing in for an MCP client):
  closing stdin ends the wrapper and the container, with and without an
  `initialize` first; before `agent-box-mcp` both cases hung.
- Real runs on a signed-in volume: a trivial prompt returned exit 0 with one
  JSON object; a prompt that needed a tool with `--max-turns 1` returned
  exit 3 (`subtype: error_max_turns`); `-a --resume -a <session_id>` in the
  same `--dir` continued the earlier session.
- Host Claude Code 2.1.282 on Windows: `claude mcp add` with the wrapper
  (Git's `bin\bash.exe` launcher and `usr\bin\bash.exe`), a JSON entry with
  a bare `bash` command and with the relative path from the repo root, and
  the plain `docker run -i ... agent-box-mcp` form all report `Connected`
  (about five seconds) and leave no container behind.
- `task lint` equivalent: shellcheck clean over `agent-box.sh lib/*.sh
  image/*.sh tests/*.sh`. `doctor` on the new image: firewall and
  everything else as before; the one FAIL (git on the repo) is because the
  run was from a git worktree whose `.git` points at a Windows path, not a
  regression.

## Follow-ups

- An opt-in allowlist firewall mode (`AGENT_BOX_FIREWALL=allowlist`) for
  batch runs that must use `bypassPermissions` on untrusted input. The old
  allowlist script is in git history before 2026-09-17.
- Per-run throwaway home volume seeded with only the Claude login (today:
  a second named volume by hand).
- Concurrent batch runs share one home volume and so one `.claude.json`;
  Claude Code tolerates parallel sessions, but this has not been stress-tested.
- A CI lane could call `batch` with `compose.ci.yaml`; the overlay lists
  both services, but it also sets `stdin_open: false`, and whether
  `compose run -i` still attaches stdin under it is untested. Check before
  relying on it.
