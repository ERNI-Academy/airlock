# The sandbox image — ONE recipe for every stack, driven by build args.
#
# There used to be a file per stack (Dockerfile + Dockerfile.java-angular), each a
# copy of the same base with one section bolted on, and each carrying all four
# harness CLIs and Playwright whether the project used them or not. Now the engineer
# says what the sandbox needs in the repo-root `airlock.json`; `bin/airlock` turns a
# project's STACK= (and COMPONENTS=) into the args below, and compose defaults them to
# the base image (node + python + all four harnesses, no Playwright) for raw
# `docker compose build` and raw `bin/harness` callers.
#
# Every optional component is ONE guarded RUN, so a project that trims one does not
# invalidate the layers of the ones it kept.
#
# Recipes with pre-warmed offline dependency caches (selected with DEV_CONTEXT +
# DEV_DOCKERFILE) are deliberately NOT built from this file: they must stay byte-stable.
#
# WHITELIST: the JDK component needs .adoptium.net and the .NET one dot.net /
# .microsoft.com reachable at BUILD time — builds use the host network, not the
# sandbox's, so this is about your own machine, not the egress whitelist.
FROM mcr.microsoft.com/devcontainers/base:ubuntu

RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl ca-certificates gnupg \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI (gh), from GitHub's official apt repo. Auth happens at runtime
# (`gh auth login` inside the container) — nothing from the host is baked in,
# and push stays blocked either way (see the git config below).
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# ── python ────────────────────────────────────────────────────────────────────
ARG WITH_PYTHON=1
RUN if [ "$WITH_PYTHON" = "1" ]; then \
        apt-get update && apt-get install -y --no-install-recommends \
            python3 python3-pip python3-venv \
        && rm -rf /var/lib/apt/lists/*; \
    fi

# ── Node LTS (22.x) — ships a recent npm, which the Angular CLI needs ─────────
# Everything npm-shaped below (the harness CLIs, Angular, Playwright's installer)
# depends on this; airlock.json refuses a stack that needs one of them without node.
ARG WITH_NODE=1
RUN if [ "$WITH_NODE" = "1" ]; then \
        curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
        && apt-get install -y nodejs && rm -rf /var/lib/apt/lists/*; \
    fi

# ── Playwright + headless Chromium (drive the app under test / local e2e) ────
# Per project, off by default: COMPONENTS=playwright in the project's config (the
# first-launch wizard asks). Baked at BUILD time (host network), so it needs NO runtime egress — the
# browser only ever drives localhost, which keeps the airlock guarantee intact.
# Chromium only, to stay lean. Pin PLAYWRIGHT_VERSION in .env for reproducible
# builds; keep a project's own playwright dep on the SAME version, or it may try
# to re-download a browser at run time (which airlock blocks — no CDN whitelisted).
ARG WITH_PLAYWRIGHT=0
ARG PLAYWRIGHT_VERSION=latest
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN if [ "$WITH_PLAYWRIGHT" = "1" ]; then \
        npx --yes playwright@${PLAYWRIGHT_VERSION} install --with-deps chromium \
        && chmod -R a+rX /ms-playwright \
        && rm -rf /var/lib/apt/lists/*; \
    fi

# ── Java (Eclipse Temurin, the Adoptium apt repo) ─────────────────────────────
# Temurin installs to an arch-suffixed dir (…-amd64 / …-arm64); the symlink gives
# JAVA_HOME a stable path on any arch (Apple Silicon builds arm64). JAVA_HOME is a
# plain ENV, so it is set on every image — on a stack without java it points at a
# directory that does not exist, which is harmless: nothing java-shaped is installed
# to read it.
ARG WITH_JAVA=0
ARG JDK_VERSION=25
RUN if [ "$WITH_JAVA" = "1" ]; then \
        curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public \
            -o /usr/share/keyrings/adoptium.asc \
        && echo "deb [signed-by=/usr/share/keyrings/adoptium.asc] https://packages.adoptium.net/artifactory/deb $(. /etc/os-release && echo "$VERSION_CODENAME") main" \
            > /etc/apt/sources.list.d/adoptium.list \
        && apt-get update \
        && apt-get install -y --no-install-recommends "temurin-${JDK_VERSION}-jdk" \
        && rm -rf /var/lib/apt/lists/* \
        && ln -s "$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")" /opt/java-home; \
    fi
ENV JAVA_HOME=/opt/java-home

# ── Angular CLI ───────────────────────────────────────────────────────────────
# Defaults to latest; pin ANGULAR_VERSION in .env (e.g. 21) for reproducible
# builds. NOTE: "Angular 25" does not exist yet — latest is ~v21–22.
ARG WITH_ANGULAR=0
ARG ANGULAR_VERSION=latest
RUN if [ "$WITH_ANGULAR" = "1" ]; then npm install -g @angular/cli@${ANGULAR_VERSION}; fi

# ── .NET SDK ──────────────────────────────────────────────────────────────────
# Installed via the official script (arch-aware). Bump DOTNET_VERSION in .env to
# match a project's global.json.
ARG WITH_DOTNET=0
ARG DOTNET_VERSION=10.0.203
RUN if [ "$WITH_DOTNET" = "1" ]; then \
        curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \
        && chmod +x /tmp/dotnet-install.sh \
        && /tmp/dotnet-install.sh --version "${DOTNET_VERSION}" --install-dir /usr/share/dotnet \
        && ln -s /usr/share/dotnet/dotnet /usr/local/bin/dotnet \
        && rm /tmp/dotnet-install.sh; \
    fi
ENV DOTNET_ROOT=/usr/share/dotnet
# Keep .NET quiet on the network (no first-run telemetry / package sign check noise).
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1

# ── the harness CLIs ──────────────────────────────────────────────────────────
# HARNESSES is the `harnesses` list from airlock.json, space-separated. Trim it
# there and the image stops carrying the CLIs the project cannot start anyway —
# one harness per project is already the rule (0014). Versions default to `latest`;
# pin them in .env (they arrive as build args via docker-compose.yml) for
# reproducible builds.
ARG HARNESSES="opencode claude codex copilot"
ARG CLAUDE_CODE_VERSION=latest
ARG CODEX_VERSION=latest
ARG OPENCODE_VERSION=latest
ARG COPILOT_VERSION=latest
RUN set -e; pkgs=""; \
    for h in ${HARNESSES}; do \
      case "$h" in \
        opencode) pkgs="$pkgs opencode-ai@${OPENCODE_VERSION}" ;; \
        claude)   pkgs="$pkgs @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" ;; \
        codex)    pkgs="$pkgs @openai/codex@${CODEX_VERSION}" ;; \
        copilot)  pkgs="$pkgs @github/copilot@${COPILOT_VERSION}" ;; \
        *) echo "unknown harness '$h' in HARNESSES" >&2; exit 1 ;; \
      esac; \
    done; \
    [ -z "$pkgs" ] || npm install -g $pkgs

# Rewrite push URLs to an invalid scheme. This stops ACCIDENTAL pushes — it is a
# git config, and an agent that wants to can bypass it (GIT_CONFIG_NOSYSTEM, a
# plain curl). The controls that actually hold are the egress whitelist
# (api.github.com is not allowed) and having no push-capable credential inside.
RUN git config --system 'url.push-disabled://.pushInsteadOf' 'https://' \
    && git config --system --add 'url.push-disabled://.pushInsteadOf' 'git@'

# Non-root user (base image provides 'vscode'; add 'dev' alias-style home).
# Non-root is also a hard requirement: claude's --dangerously-skip-permissions
# refuses to run as root.
RUN useradd -m -s /bin/bash dev
USER dev
# Pre-create ~/.config (and opencode's dir) owned by dev. Otherwise the gh
# bind-mount at ~/.config/gh makes Docker create ~/.config as root, and opencode
# can't create/write its runtime dir there (EACCES on startup).
RUN mkdir -p /home/dev/.config/opencode
WORKDIR /workspace
