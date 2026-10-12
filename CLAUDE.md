# CLAUDE.md

Guidance for working in this repo. `README.md` is the user-facing documentation; do not
restate it here.

**Private notes:** if `.local/CLAUDE.md` exists in this checkout, read it first. It is a private,
git-ignored notes file the maintainer may keep. Nothing in this file depends on it.

## What this is

A Docker-based sandbox for running AI coding harnesses (opencode, Claude Code, Codex CLI, GitHub
Copilot CLI) against an OpenAI-compatible LLM endpoint or a cloud API, inside a container that
**cannot leak**: no internet except a squid whitelist, nothing inside that can push code out, no
host access beyond one LLM port. Containers in `docker-compose.yml`: `dev` (sandbox,
internal-only network), `proxy` (squid egress door) and `llm` (ONE profile-gated socat pipe to
ONE host port; it also answers as `llm2`/`llm3` so a plugin or opencode config may use a
distinct hostname per backend, all three reaching the same host port).

## Layout

| Path | What |
|------|------|
| `docker-compose.yml` | The container stack + networks. `dev` builds from `DEV_DOCKERFILE` (default `Dockerfile`) in `DEV_CONTEXT` (default `./dev`); the `HARNESSES`/`WITH_*` build args come from `airlock.json` via `bin/airlock`, version pins from `.env`. Its defaults are the plain base image (node + python, all four harnesses, no Playwright) for raw callers. |
| `airlock.json` | **Kit-level** build config (tracked, not per project, not secret): which harness CLIs a project may pick (an image installs only its project's one) and each `STACK`'s components (`node`/`python`/`java`/`angular`/`dotnet`). Those components also derive the stack's egress whitelist blocks. Playwright is a per-project extra, `COMPONENTS=playwright` (default off; the wizard asks). `AIRLOCK_KIT_CONFIG=<path>` overrides the file. |
| `dev/Dockerfile` | THE sandbox image — one parametrised recipe for every stack, each optional component a single guarded `RUN` (so trimming one keeps the others' layers cached). |
| `bin/airlock` | The per-project front-end: run from inside any project dir. Reads that project's config from the host-side control dir `${AIRLOCK_HOME:-~/.airlock}/<slug>-<hash6>/`, translates it to `sandbox-run` env vars, and execs `bin/sandbox-run`. The config is **parsed, never sourced**: KEY=VALUE only, fixed key allow list, validated values. Verbs, config keys and credentials: `README.md`. |
| `bin/lib/` | Sourced libraries (functions only, no top-level side effects): `airlock-kit.sh` (airlock.json), `airlock-backends.sh` (the backends plugin path, shared with `bin/sandbox-run`), `airlock-config.sh` (control dir, config + secrets parsers, allow lists, state mounts, credentials), `airlock-whitelist.sh` (whitelist composition + squid reload marker), `airlock-init.sh` (the one config writer, project-type detection, first-launch wizard), `airlock-gc.sh` (`airlock gc` + the launch-time image sweep), `airlock-verify.sh` (the `verify` probes, sourced by `sandbox-run`). |
| `bin/sandbox-run` | **Shared** high-level runner: the model picker, backend health check (and auto-start where configured), the `endpoint` opencode render, `verify`, `stop`, `deps`. All host-side logic lives here. |
| `bin/harness` | Low-level launcher: `up`/`shell`/`oc`/`claude`/`codex`/`copilot`/`run`/`down`/`denied`/`reload-proxy`/`config`. Mounts a dir at `/workspace`, runs a command in `dev`, reads no project config. On Windows use WSL2. |
| `dev/opencode/`, `dev/opencode-endpoint/` | opencode provider/model configs, mounted read-only at `/etc/opencode` and loaded via `OPENCODE_CONFIG`. `dev/opencode/` is the raw-caller default; `dev/opencode-endpoint/opencode.json.tmpl` is rendered per project for `LOCAL_MODEL=endpoint`. |
| `proxy/` | `squid.conf` is egress **policy** only (default-deny + one `dstdomain` include). `whitelist.d/` holds the blocks (`stack-*.txt`, `harness-*.txt`); `extra-whitelist.txt` is the default list compose mounts for raw callers (`stack-node` + `stack-python`, what `STACK=base` needs). `airlock` composes a per-project list into the control dir instead. |
| `templates/airlock.example` | The config format reference. |
| `templates/backends.example.sh` | Example backends plugin (Ollama, llama-server); copied to the git-ignored `backends.sh`. |
| `.env` | Host/port/model and version pins. **Git-ignored**; the tracked template is `.env.example`. |
| `state/` | Fallback tool-state mounts for raw `bin/harness` callers. Git-ignored except the skeleton. Under `airlock`, per-project state lives in the control dir instead. |
| `workspace/` | Default bind mount when `harness` runs with no project dir. Contents git-ignored. |

## Launcher architecture

Three layers, one job each: `bin/harness` (mechanical: mount a dir at `/workspace`, run a
command in `dev`), `bin/sandbox-run` (host-side concerns: LLM health check, paired shutdown,
verify; env vars with defaults, requires only `PROJECT`) and `bin/airlock` (per-directory
front-end: reads the control-dir config, translates it, execs `bin/sandbox-run`).
**When changing launcher behavior, edit `bin/sandbox-run`** — the other two layers are
deliberately thin, and that is the whole point of the split.

## LLM backends

The sandbox reaches the model through **one** socat pipe (`llm`) to **one** host port, so no
proxy or whitelist entry is involved. `LOCAL_MODEL` in the project config picks the backend;
the kit ships `endpoint` (any OpenAI-compatible server, described by `LLM_HOST`/`LLM_PORT`
/`LLM_MODEL`, key `LLM_KEY` in the secrets file; health-checked only), `off` (cloud APIs only,
door not started) and `ask`. Servers the host should start/stop are pickers registered by a
backends plugin, the host shell file `backends.sh` at the kit root (git-ignored, optional;
`AIRLOCK_BACKENDS` overrides the path; example in `templates/backends.example.sh`), which
`bin/sandbox-run` sources:
`BACKENDS_EXTRA` + one `backend_<name>` function setting `BK_*` fields (field list at
`bk_load`); the mechanics stay in `sandbox-run`. See `README.md` "LLM backends". Model
context/output limits in the opencode configs must not exceed what the server was launched with.

## Working style

- **Small steps.** One tool call does one thing; a repro, a cleanup and a second repro are
  separate commands so each can be approved or rejected on its own.
- **Delegate legwork to subagents** where available; relay conclusions only. One running task
  at a time; a subagent's background shells count.

## Maintenance (keep this folder healthy)

- **Prune build/test artifacts.** `workspace/` and `state/*/` contents are git-ignored; stray
  files at the repo root from an agent run get deleted.
- **No secrets in git.** Live tokens belong in `.env`, the control dir's `env`, or `state/`.
- **One source of truth per concern.** Don't reintroduce a monolithic launcher alongside
  `bin/sandbox-run` — extend the shared runner instead.
- **Validate after edits.** `docker compose config` for compose, `python3 -m json.tool airlock.json`
  and `python3 -m json.tool dev/opencode/opencode.json` for the JSON,
  `for f in bin/airlock bin/harness bin/sandbox-run bin/test-airlock-config.sh bin/lib/*.sh templates/backends.example.sh; do bash -n "$f"; done`
  for the scripts, `bin/test-airlock-config.sh` for the airlock config path.
- **Record durable host/tooling pitfalls** in private notes; they are not shipped.

## Conventions

- Line endings are pinned by `.gitattributes` so Windows checkouts can't corrupt files mounted
  into Linux containers. Keep shell scripts LF.
- The egress whitelist is security-critical — keep it minimal; add a domain only when a real
  run is blocked (`airlock denied` shows the `TCP_DENIED` lines). A stack or harness property
  goes in the matching `proxy/whitelist.d/` block, a one-project property in that project's
  `WHITELIST=`. Nothing goes back into `proxy/squid.conf` — it is policy, not a list.
