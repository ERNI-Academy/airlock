# airlock — a sandbox for AI coding harnesses

Run an AI coding harness (opencode, Claude Code, Codex CLI, GitHub Copilot CLI) on a real
project, against a **local LLM** or a cloud API, inside a container that cannot leak: no
internet except a short per-project whitelist, no credential that can push code, no access
to your machine beyond one LLM port.

## The three rules

The point is to run an agent with permission prompts **off** without risking exfiltration
(source or secrets posted somewhere), host compromise (your home, SSH keys, other projects)
or silent scope creep (telemetry, auto-update). The answer is not a firewall rule or a policy
the agent is asked to respect, but the absence of a route. Each rule below is structural — a
missing route or a missing file.

| | Rule | How it is enforced |
|---|------|--------------------|
| **R1** | No open internet. Whitelist-only egress. | `dev` sits on a Docker network with `internal: true`, which Docker creates **without a gateway** — there is no route to drop packets on. The only reachable machines are `proxy` (squid, default-deny + a [per-project whitelist](#the-egress-whitelist)) and the LLM door. |
| **R2** | Access to one project folder, nothing else. | One bind mount at `/workspace`. `airlock` refuses to launch from `$HOME`, `/`, or a folder that is not a repo and holds ≥2 child repos — `--force` overrides deliberately. Config, whitelist, state and secrets all live **outside** that folder, in the [control dir](#the-control-dir). |
| **R3** | No environment variable, token or resource outside an allow list. | The project config is parsed against a fixed key allow list, never sourced. `HARNESS=` names **one** harness per project: only its state dir is mounted, only its credentials are passed in (every other credential name is exported *empty*, overriding your shell), only its vendor domains reach the whitelist, and a project that is not opencode gets an empty `/etc/opencode`. The LLM door forwards to exactly one host port. |

`airlock verify` [proves all three from inside the container](#verify).

Layered on top, and not boundaries in themselves: the image rewrites git push URLs to
`push-disabled://` (catches accidental pushes; an agent that means to can step around a git
config), harness config is bind-mounted read-only, and telemetry/auto-update are switched
off so the whitelist never has to grow for noise.

`docker-compose.yml` runs three containers:

| Container | What it is | Networks |
|-----------|------------|----------|
| `dev` | The sandbox. Your project is at `/workspace`. `cap_drop: [ALL]`, `no-new-privileges`, non-root. | `internal` only |
| `proxy` | Squid — the only web door. Default-deny plus one whitelist file. | `internal` + `egress` |
| `llm` | One socat pipe to **one** host port (this machine or a LAN box). Absent with `LOCAL_MODEL=off`. Answers to `llm2`/`llm3` as aliases. | `internal` + `egress` |

## Prerequisites

- Docker running — Docker Desktop, Colima, or docker-ce on Linux/WSL2. The launchers are
  bash.
- For local models, any OpenAI-compatible server (Ollama, LM Studio, vLLM, llama-server…) on
  this machine or your LAN. Cloud-only use (Claude Code, Copilot, Codex against OpenAI) needs
  none.
- **Colima users:** only your home directory is shared into the VM by default. Projects
  (and an `AIRLOCK_HOME` or a checkout of this repo) outside `$HOME` mount as *empty*
  folders or fail to mount. Add mounts in `~/.colima/default/colima.yaml` if you need them.

## Quick start

```sh
# once per machine: put this repo's bin/ on your PATH (zsh shown; bash: ~/.bashrc)
echo 'export HARNESS_ROOT="$HOME/src/airlock"' >> ~/.zshrc   # wherever you cloned it
echo 'export PATH="$HARNESS_ROOT/bin:$PATH"' >> ~/.zshrc
exec zsh

cd "$HARNESS_ROOT" && cp .env.example .env   # version pins, raw-caller defaults; git-ignored

# per project, from inside it
cd ~/projects/my-app
airlock oc                          # first launch: a short wizard (stack, harness, backend)
                                    #   writes ~/.airlock/<slug>-<hash6>/config, then carries on
                                    #   (non-interactive: airlock init --stack base)
airlock config --edit               # later: WHITELIST=, GH=, LOCAL_MODEL=, …
airlock verify                      # prove the boundary and the posture
airlock down                        # stop
```

Each project gets its own compose stack, so several can run side by side. A cloud tool's
first run prints a login URL: authorize in your host browser, paste the code back. Logins
are per project and survive rebuilds.

## The verbs

Run `airlock` from **inside** the project directory; the current folder is what gets
mounted, and every start prints `sandboxing <dir> → /workspace`.

| Verb | What it does |
|------|--------------|
| `airlock init [--stack S]` | Write this project's config into the control dir. Fresh only — it refuses if one exists. Without `--stack`, at a terminal it runs the [first-launch wizard](#first-launch-the-wizard); off a terminal it writes `STACK=base`, `LOCAL_MODEL=off`. |
| `airlock import [file]` | Review a config file (default `./.airlock`) and adopt it as this project's config. Interactive, TTY only; never touches the secrets file. |
| `airlock config` | Print the control dir, the config, the effective settings and the *names* in the secrets file. |
| `airlock config --edit` | Open the config in `$EDITOR`, then re-parse it (a broken edit is fatal here, not at the next launch). |
| `airlock config --secrets` | Open the credentials file (created 0600). |
| `airlock` | Shell in the sandbox (the default verb). |
| `airlock claude` \| `codex` \| `copilot` \| `oc` | Run **the** harness. The other three verbs are refused — one harness per project. `airlock claude` runs with permission prompts off (see [Limits](#limits)). |
| `airlock run <cmd…>` | Run any command in the sandbox. No `--` separator: a `--` is passed through as the command and fails. |
| `airlock verify` | Build, boot, and run the boundary + posture probes. See [verify](#verify). |
| `airlock up` | Start the stack without opening a session. |
| `airlock down` | Stop the container; host LLM backends stay up. |
| `airlock stop` | Container **and** every host backend a [backends plugin](#a-backends-plugin-backendssh) manages that is running. An `endpoint` server is never stopped — it is not ours. |
| `airlock denied` | Show the proxy's `TCP_DENIED` lines. |
| `airlock reload-proxy` | Force squid to re-read the whitelist (normally automatic). |
| `airlock deps` | Where to add tools (the install lines in `dev/Dockerfile`), the stacks `airlock.json` defines, and the `LOCAL_MODEL` pickers in force. |
| `airlock gc [--dry-run] [--days N] [--all-stale]` | Remove per-project sandbox images that are dead weight. Works from any dir. See [Sandbox images and `gc`](#sandbox-images-and-gc). |
| `airlock -C <dir> <verb>` | Act on `<dir>` instead of the current one. |
| `airlock --force <verb>` | Skip the launch-dir guard (R2). |
| `airlock help` | Print the verb list (also `--help`, `-h`). An unknown verb is refused before anything starts. |

**The layers underneath.** `bin/harness <verb> [dir] [cmd…]` mounts a dir at `/workspace`
and runs a command in `dev`, reading no project config — scripted callers (CI) use it
directly. `bin/sandbox-run`, between it and `airlock`, owns all host-side work: backend
health check and auto-start, `verify`, `stop`, `deps`.

## The control dir

The project folder is mounted **read-write**, so anything inside it is agent-writable. A
config that decides which image to build, which domains to open and which host directories
to mount therefore cannot live there. Each project gets a host-side control dir the sandbox
has no path to, keyed by the project's absolute path:

```
~/.airlock/<slug>-<hash6>/          (mode 0700; AIRLOCK_HOME moves the root)
  config                            the KEY=VALUE settings
  env                               the credentials, mode 0600
  whitelist.txt                     the composed squid list
  whitelist.applied                 what the running proxy last read
  last-launch                       epoch seconds of the last launch verb (gc's clock)
  state/{claude,codex,gh,copilot}   the tool-state mounts (logins)
  opencode-endpoint/opencode.json   rendered for LOCAL_MODEL=endpoint (0600)
```

A `.airlock` file left in a project is **ignored**, with a notice once per launch;
`airlock import` is how you adopt one (a teammate's config, or an old in-tree one).
`airlock` refuses to start if a state dir is a symlink: a bind mount follows host symlinks.

### First launch: the wizard

A verb that builds or boots the sandbox (`shell`, `oc`, `claude`, `codex`, `copilot`, `run`,
`up`) in a project with no config **never falls back to a default**:

- **At a terminal** it asks, writes the config exactly as `airlock init` would, and carries
  on: the **stack** (suggested from the project's files — `pom.xml`/`build.gradle*` →
  `java-angular`, a `*.csproj`/`*.sln` → `dotnet`, `pyproject.toml`/`requirements*.txt` →
  `base`, `package.json` alone → `node`, else `base`; or `custom` to pick components),
  **Playwright** (default no), the **harness** (skipped when the verb names it), and the
  **LLM backend** (`endpoint` with host/port/model/key, or `off`; plugin pickers and `ask`
  when a plugin is loaded).
- **Anywhere else** (scripts, CI, a calling agent) it exits 1, naming
  `airlock init --stack <s>`. Nothing is guessed and nothing is built.

`down`, `stop`, `denied`, `deps`, `reload-proxy` and `verify` run without a config.

### Config keys

The config is **parsed, never sourced**: blank lines, `#` comments and
`[export ]KEY=VALUE` (bare, `'single'`- or `"double"`-quoted) only. No expansion of any kind —
a `$`, backtick, `;` or `|` in a value is a hard error — plus a fixed key allow list and a
per-key value check. Commented format reference: [templates/airlock.example](templates/airlock.example).

| Key | Values | Notes |
|-----|--------|-------|
| `STACK` | a stack `airlock.json` defines: `base` \| `java-angular` \| `dotnet` \| `node` | Decides the image components **and** the whitelist blocks, unless `COMPONENTS` is set. Default `base`. |
| `COMPONENTS` | comma- or space-separated from `node` `python` `java` `angular` `dotnet`, plus the extra `playwright` | Overrides the stack's set, for the build **and** the whitelist blocks. `node` is required in a list. Empty = the stack's set. `playwright` alone (`COMPONENTS=playwright`) is **added** to the stack's set; it bakes Playwright + headless Chromium in and opens no egress. |
| `HARNESS` | `opencode` \| `claude` \| `codex` \| `copilot` | ONE per project; must be listed in `airlock.json`. Default `opencode`. |
| `GH` | `on` \| `off` | Mount the gh login. Default `off`. |
| `GC` | `on` \| `off` | `off` = this project's launches run no image sweep. Default `on`. |
| `GC_DAYS` | whole days | How long this project's image survives unlaunched before a sweep removes it. Default `30`; `0` = never stale. |
| `WHITELIST` | space-separated domains | Extra egress on top of the stack and harness blocks. Plain lowercase domains, optional leading dot; no IPs, ports, paths or wildcards. |
| `LOCAL_MODEL` | `endpoint` \| `off` \| `ask` \| a plugin picker | See [LLM backends](#llm-backends). Absent = `ask`. |
| `LLM_HOST` | hostname or IP | The `endpoint` server's host (no scheme, port or path). Default `host.docker.internal`. |
| `LLM_PORT` | 1–65535 | The `endpoint` server's **host** port. |
| `LLM_MODEL` | model id | The id the server lists on `/v1/models`. |
| `LLM_KEY` | API-key characters, may be empty | Better kept in the secrets file, which wins. |
| `LLM_CONTEXT` `LLM_OUTPUT` | number (tokens) | opencode's limits for `endpoint`; keep them ≤ what the server allows. |
| `ANTHROPIC_MODEL` | model id | Claude Code's model; empty = its default. |
| `CLAUDE_STATE` `CODEX_STATE` `GH_STATE` `COPILOT_STATE` | absolute path or `~/…` | Share one login across projects. May not resolve to `/`, your home root, this repo, the control-dir root, or into `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.config`, `~/.kube`, `~/.docker`, `~/Library`. |
| `DEV_DOCKERFILE` | `Dockerfile*` in `dev/` | Escape hatch for a recipe of your own (e.g. one with pre-warmed dependency caches). |
| `ANGULAR_VERSION` `JDK_VERSION` | version string | Legacy knobs, still honoured. |

Deliberately **not** allowed, because the project must not decide these: `EXTRA_WHITELIST`,
`OPENCODE_DIR`, `WORKSPACE`, `PROJECT`, `COMPOSE_*`, `HARNESS_*`, `PATH`, `AIRLOCK_HOME`, and
every credential.

### Credentials

`env` in the control dir (mode 0600, `airlock config --secrets`) is parsed by the same strict
parser against its own allow list: `OPENAI_API_KEY`, `OPENROUTER_API_KEY`,
`ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, plus `LLM_KEY` (the `endpoint` server's key;
it reaches the sandbox only as that endpoint's `OPENAI_API_KEY`). It is separate from `config`
so sharing or importing a config can never carry a key.

Every credential name is **exported** before launch: with the project's value when it belongs
to the selected harness, otherwise **empty** — so a key exported in your shell for something
else cannot ride in.

| `HARNESS` | Credentials passed in |
|-----------|-----------------------|
| `opencode` | `OPENAI_API_KEY` `OPENROUTER_API_KEY` |
| `claude` | `ANTHROPIC_API_KEY` `CLAUDE_CODE_OAUTH_TOKEN` |
| `codex` | `OPENAI_API_KEY` |
| `copilot` | none (its own device flow) |

Every launch prints one line naming what goes in — names only, never values:

```
airlock: into sandbox → harness=claude, credentials: CLAUDE_CODE_OAUTH_TOKEN (project secrets), gh: off
```

Only the selected harness's state dir is mounted (the others get an empty placeholder), and
the verbs for a different harness are refused with a hint. `GH=on` is off by default because
a gh token plus a whitelisted `.github.com` is an upload path (`gh api`, `gist create`);
`airlock` warns when it sees both.

**macOS:** Claude Code keeps host credentials in the Keychain, so pointing `CLAUDE_STATE` at
your host `~/.claude` does **not** carry auth in. Log in inside the sandbox, or run
`claude setup-token` on the host and put `CLAUDE_CODE_OAUTH_TOKEN` in the secrets file. On
Linux/WSL2 it is a plain file and sharing works; `gh` and `codex` keep plain files everywhere.

## `airlock.json`: what the image is built with

The repo-root [airlock.json](airlock.json) is the **kit** config: tracked, not per project,
not secret. It names the harness CLIs a project may pick and each `STACK`'s components:

```json
{
  "harnesses": ["opencode", "claude", "codex", "copilot"],
  "stacks": {
    "base":         { "node": true, "python": true },
    "java-angular": { "node": true, "python": true, "java": true, "angular": true },
    "dotnet":       { "node": true, "dotnet": true },
    "node":         { "node": true }
  }
}
```

`bin/airlock` turns the project's `STACK=` (or `COMPONENTS=`, which wins) into the `WITH_*`
build args of `dev/Dockerfile` — one parametrised recipe, each optional component a single
guarded `RUN`, so trimming one keeps the others' layers cached. Each image installs **only**
the project's one `HARNESS`. Playwright is not a kit setting: a project opts in with
`COMPONENTS=playwright`. A `STACK` or `HARNESS` the kit does not build is refused with the
file named; `AIRLOCK_KIT_CONFIG=<path>` points at a different kit file. Version pins live in
`.env`; Claude Code and opencode otherwise track the latest npm release.

## Sandbox images and `gc`

Every project gets its own image, `harness-<slug>-<hash6>-dev`, ~4–6 GB each, and a rebuild
leaves the previous one dangling. `airlock gc` plans, prints and (without `--dry-run`)
removes, with a reason per image:

| Rule | Removed when |
|------|--------------|
| **orphaned** | the image's control dir no longer exists. |
| **stale** | its `last-launch` is older than the project's `GC_DAYS` or `--days N` (default 30; `0` turns the rule off). `--all-stale` ignores the age. |
| **dangling** | untagged leftovers of sandbox builds. Manual `gc` only. |

Never removed: an image any container uses (running or stopped — `airlock down` first), the
current project's image, images built by raw `bin/harness` or under another `AIRLOCK_HOME`,
and anything not named like a sandbox image. Every launch verb also runs an **automatic sweep** of the orphaned + stale rules over other
projects' labelled images before the build, printing a line only when it removed something.
`GC=off` turns it off for that project's launches. On Colima the launch warns when the VM
disk has under 10 GB free.

## The egress whitelist

`proxy/squid.conf` carries the **policy** — default-deny, HTTPS tunnels to `:443` only, one
`dstdomain` include — and **no domains**. The list it enforces is composed per project at
every launch into `whitelist.txt` in the control dir, from the blocks in
[proxy/whitelist.d/](proxy/whitelist.d/README.md):

| Source | Blocks |
|--------|--------|
| `STACK=base` | `stack-node` `stack-python` |
| `STACK=java-angular` | `stack-node` `stack-python` `stack-java` |
| `STACK=dotnet` | `stack-node` `stack-dotnet` |
| `STACK=node` | `stack-node` |
| `COMPONENTS=…` | replaces the stack's row: one block per component, same map |
| `HARNESS=<name>` | `harness-<name>` — one only |
| the project's `WHITELIST=` | those domains, verbatim |

Harness vendor domains: opencode `.models.dev`; Claude Code `.anthropic.com` `.claude.ai`
`.claude.com`; Codex `.openai.com` `.chatgpt.com`; Copilot `.github.com`
`.githubcopilot.com` `.githubusercontent.com`. Duplicates and entries a broader `.domain`
covers are dropped, `airlock` reloads the proxy by itself when the list changed, and every
launch prints the count and the blocks that went in. `gh` / `git fetch` over HTTPS is in no
block — `.github.com` plus a mounted gh token is an upload path, so whitelist it per project,
deliberately. Raw `bin/harness` callers get `proxy/extra-whitelist.txt` (npm + PyPI only).

### When something cannot connect

That is usually the sandbox doing its job.

```sh
airlock denied          # the proxy's TCP_DENIED lines; the hostname is in each one
airlock reload-proxy    # force squid to re-read the list (normally automatic)
```

Add a domain only when a real run is blocked, and decide **where** it belongs. A property of
one project goes in that project's `WHITELIST=` (`airlock config --edit`); a property of a
stack or a harness goes in the matching `proxy/whitelist.d/` block, and then every project on
it carries the domain. Nothing goes into `proxy/squid.conf` — it is policy, not a list.

A cloud harness whose vendor block is missing just hangs on login; `airlock` checks the list
for the verb's domains up front and prints a hint instead.

## LLM backends

The sandbox has no route to the host; the only host port it can reach is the one the `llm`
door forwards to, and `LOCAL_MODEL` decides which — or that there is none:

| `LOCAL_MODEL` | Backend | Started for you? |
|---------------|---------|------------------|
| `endpoint` | Any OpenAI-compatible server you already run, on this machine or your LAN. | no — health check only |
| `off` | No door: `llm` does not resolve and no host port is reachable. For harnesses that talk to their cloud vendor. | n/a |
| `ask` | Prompt at every launch. With no terminal: a plugin backend already serving, else the plugin's default, else `endpoint` if configured, else `off`. The default when the key is absent. | — |
| *plugin picker* | A server a [backends plugin](#a-backends-plugin-backendssh) starts and stops. | yes |

Inside the sandbox the door is `http://llm:8080/v1`. It also answers as `llm2:8000` and
`llm3:8090`, so a plugin or opencode config may use a distinct hostname per backend; all
three names reach the same single host port. It is reached directly, not through the proxy.
`OPENAI_BASE_URL`/`OPENAI_API_KEY` are passed in only for `HARNESS=opencode` and `codex`; for
`claude`/`copilot` the door still opens if a backend is configured, but the two variables stay
out, and the launch says so.

### Bring your own server (`LOCAL_MODEL=endpoint`)

Ollama, LM Studio, vLLM, llama-server. In the project config (the wizard writes this):

```sh
LOCAL_MODEL=endpoint
LLM_HOST=host.docker.internal   # this machine; or a LAN box (name or IP)
LLM_PORT=11434                  # the HOST port it listens on
LLM_MODEL=llama3.1:8b           # the model id the server lists on /v1/models
# LLM_CONTEXT=131072            # opencode limits; keep them ≤ what the server allows
# LLM_OUTPUT=16384
```

and, only if the server wants one, `LLM_KEY=…` in the secrets file. Nothing is started or
stopped: `airlock` health-checks `GET /v1/models`, says plainly if it is down, and lists what
the server serves when `LLM_MODEL` is not among them. opencode's config is rendered from
`dev/opencode-endpoint/opencode.json.tmpl` into the control dir at launch.

### Cloud only (`LOCAL_MODEL=off`)

Claude Code and the Copilot CLI log in and talk to their vendor through the whitelist
(`HARNESS=` brings in the vendor's block); `off` keeps the door shut. opencode under `off`
needs a cloud provider of its own. For Codex against real OpenAI, set
`OPENAI_BASE_URL=https://api.openai.com/v1` in `.env` (`HARNESS=codex` already whitelists
`.openai.com`).

### A backends plugin (`backends.sh`)

To have `airlock` **start and stop** a server on this machine — and stop one model before
loading another — register it in a backends plugin: a shell file on the host, sourced by
`bin/sandbox-run`. By default that is `backends.sh` at the kit root (git-ignored, used only
if it exists); `AIRLOCK_BACKENDS=<path>` in your environment points elsewhere instead.
`templates/backends.example.sh` is a commented starting point with two backends, Ollama and
llama-server: `cp templates/backends.example.sh backends.sh`. It is host-side code like
`.env`, never mounted into the sandbox and never named by a project config. It sets `BACKENDS_EXTRA` (the
picker names) and defines one `backend_<name>` function per picker that sets `BK_*` fields;
health check, start-and-wait, exclusive stop, door port and opencode mount are the runner's
job:

```sh
# backends.sh (or the file AIRLOCK_BACKENDS names)
BACKENDS_EXTRA="llama"           # picker names, in menu order (LOCAL_MODEL=llama)
BACKENDS_DEFAULT=llama           # optional: what `ask` defaults to

backend_llama() {
  BK_LABEL="Llama 3.1 8B (llama-server :8081)"   # the menu line
  BK_PORT=8081                   # host port the door forwards to          (required)
  BK_MODEL=llama3.1-8b           # model id the server serves              (required)
  BK_START="$HOME/bin/llama-up.sh"   # any command; it must return (background the server)
  BK_STOP="$HOME/bin/llama-down.sh"
  BK_WAIT=180                    # seconds to wait for /v1/models after the start (default 120)
  BK_OPENCODE_DIR="$HOME/.config/airlock/opencode-llama"   # holds opencode.json for it
  # Optional: BK_KEY (default "local"), BK_URL (default http://llm:8080/v1),
  # BK_HEALTH_URL (default http://127.0.0.1:$BK_PORT/v1/models), BK_CHECK_ID=1 (up only
  # if /v1/models lists BK_MODEL), BK_PIDFILE (a live pid counts as running while it
  # loads), BK_HINT (shown on a start timeout), BK_EXCLUSIVE_WITH="other names".
}
```

The opencode config is `dev/opencode/opencode.json` with the provider's `baseURL` at
`http://llm:8080/v1` and your model id and limits — which must not exceed what the server
was launched with. `airlock deps` lists the pickers in force; `airlock stop` stops every
plugin backend that is running; `airlock down` leaves them up.

## `verify`

`airlock verify` builds and starts the project's stack, then asks the sandbox itself what it
can reach and what it holds — `PASS`/`FAIL`/`SKIP` per line, non-zero exit on any failure. No
model is started. The boundary:

- a non-whitelisted domain is denied by the proxy; a whitelisted one works (skipped when the
  machine is offline);
- a direct connection bypassing the proxy fails (domain and raw IP); there is no external
  DNS, and `host.docker.internal` does not resolve;
- the LLM door forwards to exactly one host port and `llm`/`llm2`/`llm3` are one container —
  or, with `LOCAL_MODEL=off`, none of them resolves;
- a variable exported in the launching shell is absent inside;
- the opencode config dir is read-only; `/Users`, your host home and `/home/<you>` do not
  exist inside;
- `/proc/self/mountinfo` holds exactly the expected bind mounts and nothing else.

Then the posture: the whitelist carries no vendor domain of a harness this project does not
run (one your own `WHITELIST=` asked for is a `WARN`), no credential of an unselected harness
is set inside, and no gh login is mounted while `GH=off`. It ends by printing the effective
whitelist in full. Run it after any config change you care about.

## Windows

Use **WSL2** with the bash launchers, which work unchanged there. With Docker Desktop,
`host.docker.internal` works as-is. With docker-ce inside WSL2 it reaches the WSL2 VM, so an
LLM server on the Windows side needs mirrored networking (`.wslconfig`:
`networkingMode=mirrored`) or `LLM_HOST` set to the Windows host IP. Line endings are pinned by
`.gitattributes` so a Windows checkout cannot corrupt files mounted into Linux containers.

## Limits

- **The blast radius is one project directory**, mounted read-write, plus your local git.
  Nothing leaves. `--force` widens that deliberately.
- **`--dangerously-skip-permissions` is fine here, and only here.** `airlock claude` runs
  Claude Code with permission prompts off. Every layer that flag would need to abuse is
  already closed: no route to your machine or the internet, whitelist-only egress, non-root
  with all capabilities dropped, and no credential that can push code. The honest residual
  risk: the OAuth token inside the container could in principle be exfiltrated — but only to
  domains *you* whitelisted. Keep the whitelist short and `GH=off`.
- **Push is not a boundary, the whitelist is.** `push-disabled://` is a git config an agent
  can step around; what holds is that `api.github.com` is not whitelisted and no
  push-capable credential is inside. Commit locally as checkpoints; push from the host after
  review.
- **The proxy sees hostnames, not URLs.** You cannot allow one path on a domain.
- **Playwright + headless Chromium**, when a project opts in with `COMPONENTS=playwright`,
  are baked in at build time and drive *your app* on localhost, needing no egress. A project
  pinning a different Playwright version may try to re-download a browser and be blocked —
  match the version or re-pin `PLAYWRIGHT_VERSION` in `.env`.
- **`COMPOSE_EXTRA_FILE` is outside the boundary checks.** `bin/harness` layers that compose
  file over the stack when the variable is set; it can add services, mounts or networks and
  so widen everything above. `airlock` never sets it; if you do, run `airlock verify`.
- **Docker only.** Podman and rootless setups are untested; after any port, `airlock verify`
  in a throwaway project is the acceptance test.

## Developing the kit

Launcher behaviour goes in `bin/sandbox-run`; `bin/airlock` (with `bin/lib/*.sh`) and
`bin/harness` stay thin. The offline checks need no model and no network beyond a local
Docker daemon:

```sh
cp .env.example .env                              # once
bin/test-airlock-config.sh                        # the airlock config path
docker compose config -q
python3 -m json.tool airlock.json >/dev/null
python3 -m json.tool dev/opencode/opencode.json >/dev/null
for f in bin/airlock bin/harness bin/sandbox-run bin/test-airlock-config.sh bin/lib/*.sh templates/backends.example.sh; do bash -n "$f"; done
```

For a change that touches the boundary (compose, the proxy, the image, mounts,
credentials), also run `airlock verify` in a throwaway project. The egress whitelist is
security-critical: add a domain only when a real run is blocked, in the block where it
belongs (see [When something cannot connect](#when-something-cannot-connect)). Keep shell
scripts LF, and no secrets in git — live keys belong in `.env` (git-ignored) or a project's
secrets file.

## License

Apache-2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
