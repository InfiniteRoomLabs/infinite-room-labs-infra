# docker/agent-box/image/Dockerfile
# ===================================
# The "agent box": a Linux container that runs Claude Code plus the full
# homelab toolchain (mise-pinned terraform/helm/kubectl/fnox, Ansible, bw,
# gh, tea) as a non-root user, following Anthropic's dev-container guidance
# (non-root, pinned CLI, autoupdate off, CLAUDE_CONFIG_DIR on a volume,
# optional default-deny egress firewall).
#
# Build via the host wrapper (it wires the extra build context):
#   docker/agent-box/agent-box.sh build
#
# Or by hand from the repo root:
#   docker build -f docker/agent-box/image/Dockerfile \
#     --build-context repo=. -t irl-agent-box:local docker/agent-box/image
#
# INVARIANT: nothing the image installs lives under /home/agent. That path
# is a named volume at runtime (logins, caches, keys), and Docker seeds a
# fresh volume from the image exactly once -- anything baked there would
# go stale after the first rebuild. Tools go under /opt and /usr/local.
#
# Version pins live here as ARGs (Renovate's dockerfile manager tracks the
# FROM line; bump the ARGs deliberately). Tools already pinned in the repo's
# mise.toml are installed from that file, so there is one source of truth.

FROM debian:trixie-slim

ARG MISE_VERSION=v2026.9.9
ARG NODE_VERSION=24.21.0
ARG UV_VERSION=0.12.15
ARG CLAUDE_CODE_VERSION=2.1.273
ARG BW_CLI_VERSION=2026.8.0
ARG TEA_VERSION=0.16.0
ARG STARSHIP_VERSION=1.26.0
ARG ANSIBLE_CORE_VERSION=2.18.18
ARG TZ=America/New_York

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    TZ=${TZ}

# ── OS packages ────────────────────────────────────────────────────────
# iptables/ipset/aggregate/dnsutils: egress firewall (init-firewall.sh).
# bubblewrap/socat: Claude Code's built-in Bash sandbox, if enabled inside.
# gh: Debian trixie ships a current-enough GitHub CLI; no third-party repo.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git gnupg jq less procps sudo tmux vim-tiny \
      openssh-client rsync unzip xz-utils bash-completion locales \
      iptables ipset iproute2 dnsutils aggregate \
      bubblewrap socat \
      gh shellcheck \
    && rm -rf /var/lib/apt/lists/*

# ── Non-root user (uid 1000 matches the homelab's anonuid convention) ──
ARG USERNAME=agent
ARG USER_UID=1000
RUN groupadd --gid ${USER_UID} ${USERNAME} \
    && useradd --uid ${USER_UID} --gid ${USER_UID} --create-home --shell /bin/bash ${USERNAME} \
    && mkdir -p /work /opt/mise /opt/npm-global /opt/uv-tools /opt/ansible /etc/mise /etc/agent-box \
    && chown -R ${USERNAME}:${USERNAME} /work /opt/mise /opt/npm-global /opt/uv-tools /opt/ansible

# ── Firewall script: the only thing the user may sudo ──────────────────
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
COPY allowlist.txt /etc/agent-box/allowlist.txt
RUN chmod 0755 /usr/local/bin/init-firewall.sh \
    && echo "${USERNAME} ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/${USERNAME}-firewall \
    && chmod 0440 /etc/sudoers.d/${USERNAME}-firewall

# ── mise: one installer for every pinned tool ──────────────────────────
RUN curl -fsSL "https://github.com/jdx/mise/releases/download/${MISE_VERSION}/mise-${MISE_VERSION}-linux-x64" \
      -o /usr/local/bin/mise && chmod 0755 /usr/local/bin/mise

# Global mise config = the repo's [tools] table + node/uv (which the repo
# does not pin because it does not need them on the laptop). Shims then
# resolve every tool from any directory, not only inside the repo.
COPY --from=repo mise.toml /opt/mise-src/mise.toml
RUN { sed -n '/^\[tools\]/,/^\[/p' /opt/mise-src/mise.toml | sed '$d'; \
      printf 'node = "%s"\nuv = "%s"\n' "${NODE_VERSION}" "${UV_VERSION}"; \
      printf '\n[settings]\nexperimental = true\n'; } > /etc/mise/config.toml \
    && cat /etc/mise/config.toml

ENV MISE_DATA_DIR=/opt/mise \
    MISE_CACHE_DIR=/opt/mise/cache \
    MISE_GLOBAL_CONFIG_FILE=/etc/mise/config.toml \
    MISE_TRUSTED_CONFIG_PATHS=/work:/opt/mise-src \
    MISE_YES=1 \
    NPM_CONFIG_PREFIX=/opt/npm-global \
    UV_TOOL_DIR=/opt/uv-tools \
    UV_TOOL_BIN_DIR=/opt/uv-tools/bin \
    UV_PYTHON_INSTALL_DIR=/opt/uv-tools/python \
    UV_CACHE_DIR=/opt/uv-tools/cache \
    ANSIBLE_COLLECTIONS_PATH=/opt/ansible/collections \
    ANSIBLE_ROLES_PATH=/opt/ansible/roles \
    PATH=/opt/mise/shims:/opt/npm-global/bin:/opt/uv-tools/bin:/usr/local/bin:/usr/bin:/bin

USER ${USERNAME}
WORKDIR /

# Install everything the global config names (as the runtime user so the
# tool store stays writable for `mise install` of new pins later). Run from
# / on purpose: the repo's mise.toml has an [env] template that shells out
# to read ~/.ssh/id_ed25519.pub, which only exists once the box has run.
RUN mise install && mise ls

# ── Claude Code + Bitwarden CLI (npm, pinned; autoupdate off at runtime) ─
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" "@bitwarden/cli@${BW_CLI_VERSION}" \
    && claude --version && bw --version

# ── Ansible: same core pin as ansible/pyproject.toml, plus the collections ─
# uv's managed interpreter must land under /opt (UV_PYTHON_INSTALL_DIR
# above): the tool venv links to it, and /home/agent is wiped below.
COPY --from=repo ansible/requirements.yml /opt/ansible/requirements.yml
RUN uv tool install --python 3.12 "ansible-core==${ANSIBLE_CORE_VERSION}" \
      --with "jmespath>=1.0" --with "kubernetes>=28.0" --with "openshift>=0.13" \
    && ansible-galaxy collection install -r /opt/ansible/requirements.yml -p /opt/ansible/collections \
    && ansible-galaxy role install -r /opt/ansible/requirements.yml -p /opt/ansible/roles \
    && ansible --version | head -1

# Honor the /home/agent invariant: installers leave caches in the home dir
# (galaxy, npm, uv). Strip them so the first volume seed is clean and small.
RUN rm -rf /home/agent/.ansible /home/agent/.npm /home/agent/.cache /home/agent/.local \
    && ls -A /home/agent

# ── tea (Gitea CLI): single static binary ──────────────────────────────
USER root
RUN curl -fsSL "https://gitea.com/gitea/tea/releases/download/v${TEA_VERSION}/tea-${TEA_VERSION}-linux-amd64" \
      -o /usr/local/bin/tea && chmod 0755 /usr/local/bin/tea && tea --version

# ── starship prompt: single static binary, image-owned default config ──
# The default config is seeded into the home volume on first start
# (entrypoint) so it can be edited there; the image copy stays pristine.
RUN curl -fsSL "https://github.com/starship/starship/releases/download/v${STARSHIP_VERSION}/starship-x86_64-unknown-linux-gnu.tar.gz" \
      | tar -xz -C /usr/local/bin starship && chmod 0755 /usr/local/bin/starship && starship --version | head -1
COPY starship.toml /etc/agent-box/starship.toml

# ── Runtime wiring ─────────────────────────────────────────────────────
COPY entrypoint.sh /usr/local/bin/agent-box-entrypoint
COPY doctor.sh /usr/local/bin/agent-box-doctor
COPY extras.sh /usr/local/bin/agent-box-extras
COPY bashrc.sh /etc/agent-box/bashrc.sh
RUN chmod 0755 /usr/local/bin/agent-box-entrypoint /usr/local/bin/agent-box-doctor /usr/local/bin/agent-box-extras \
    && echo 'source /etc/agent-box/bashrc.sh' >> /etc/bash.bashrc \
    # Bind-mounted repos under /work are owned by whatever uid the host
    # maps (Docker Desktop: not 1000), and git refuses "dubious ownership"
    # unless told otherwise. System-level so it is image-owned, not volume state.
    && git config --system --add safe.directory '*'

ENV AGENT_BOX=1 \
    CLAUDE_CONFIG_DIR=/home/agent/.claude \
    DISABLE_AUTOUPDATER=1 \
    AGENT_BOX_FIREWALL=1 \
    EDITOR=vim.tiny \
    SHELL=/bin/bash

USER ${USERNAME}
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/agent-box-entrypoint"]
CMD ["bash"]
