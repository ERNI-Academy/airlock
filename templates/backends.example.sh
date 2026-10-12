# shellcheck shell=bash
# backends.example.sh — an example backends plugin for airlock.
#
# Copy it to the kit root as backends.sh (git-ignored) and edit:
#
#   cp templates/backends.example.sh backends.sh
#
# or keep it anywhere and point AIRLOCK_BACKENDS at it (the env var wins over the
# default path). It is host-side code like .env: sourced by bin/sandbox-run, read by
# bin/airlock in a subshell to learn the picker names, never mounted into the sandbox
# and never named by a project config. README.md, "LLM backends", has the rest.
#
# A project picks one of these with LOCAL_MODEL=<name> in its config (or `ask`).
# The runner does the mechanics: health check, start and wait, exclusive stop, the
# door's host port, the opencode mount. The plugin only supplies settings.
#
# Rules of the file:
#   - Top level: assignments and function definitions only. bin/airlock sources it
#     just to read BACKENDS_EXTRA, so nothing may start, print or prompt here.
#   - The runner runs under `set -euo pipefail`: write ${VAR:-default}, and do not
#     end a backend_<name> function on a test that can fail (use `if`).
#   - BK_START/BK_STOP are split on spaces and run as-is, with no shell parsing
#     (no `&`, `>`, quotes or pipes). BK_START must RETURN once the server is
#     launching; the runner then polls the health URL for up to BK_WAIT seconds.
#     For anything beyond a plain command, name a function defined in this file
#     (as below) or a script of your own.

# The picker names, in menu order. Each needs a backend_<name> function below.
BACKENDS_EXTRA="ollama llamacpp"
# Optional: what LOCAL_MODEL=ask offers first, and its choice with no terminal.
BACKENDS_DEFAULT=ollama

# Where the helpers below keep pidfiles and logs.
_EX_STATE="${AIRLOCK_HOME:-$HOME/.airlock}"

# The fields a backend_<name> function may set (bk_load in bin/sandbox-run resets
# them to these defaults before each call; only BK_PORT and BK_MODEL are required):
#   BK_LABEL          the menu line                               (the name)
#   BK_PORT           host port the door forwards to              (required)
#   BK_MODEL          model id the server lists on /v1/models     (required)
#   BK_URL            base URL inside the sandbox                 (http://llm:8080/v1)
#   BK_KEY            API key, for the sandbox and the probe      (local)
#   BK_HEALTH_URL     host-side probe       (http://127.0.0.1:$BK_PORT/v1/models)
#   BK_CHECK_ID       1 = "up" only if the probe lists BK_MODEL   (0: answering is enough)
#   BK_START/BK_STOP  host commands; no BK_START = health check only
#   BK_WAIT           seconds to wait after BK_START              (120)
#   BK_PIDFILE        a live pid in this file counts as running (a server still loading)
#   BK_HINT           printed when the start times out
#   BK_OPENCODE_DIR   opencode config dir mounted at /etc/opencode  ($HARNESS_DIR/dev/opencode)
#   BK_EXCLUSIVE_WITH other names stopped (if running) before this one starts
#
# BK_URL: inside the sandbox the door is http://llm:8080/v1 whatever BK_PORT is; it
# also answers as llm2:8000 and llm3:8090, so a backend may use its own hostname.
# All three reach the same single host port.
#
# BK_OPENCODE_DIR (opencode only): a directory holding an opencode.json whose
# provider baseURL is BK_URL and whose model id is BK_MODEL, with context/output
# limits no larger than the server was launched with. The default, dev/opencode,
# names the model `local-model` (128K context, 16K output). For another id, copy
# dev/opencode to a directory of your own, edit it, and point BK_OPENCODE_DIR there.

# ── ollama ───────────────────────────────────────────────────────────────────
# Ollama on its default port. Pull the model first (`ollama pull llama3.1:8b`);
# Ollama loads it on the first request. If the Ollama app is already serving,
# the health check finds it and nothing is started (or stopped).
_ex_ollama_start() {
  mkdir -p "$_EX_STATE"
  nohup ollama serve >"$_EX_STATE/ollama.log" 2>&1 &
  echo $! >"$_EX_STATE/ollama.pid"
}
_ex_ollama_stop() {   # stops only the server this plugin started
  if [[ -f "$_EX_STATE/ollama.pid" ]]; then
    kill "$(cat "$_EX_STATE/ollama.pid")" 2>/dev/null || true
    rm -f "$_EX_STATE/ollama.pid"
  fi
}
backend_ollama() {
  BK_PORT=11434
  BK_MODEL="${OLLAMA_MODEL:-llama3.1:8b}"
  BK_LABEL="Ollama: $BK_MODEL"
  # No BK_KEY: Ollama ignores the key, and the default placeholder is fine.
  BK_START=_ex_ollama_start
  BK_STOP=_ex_ollama_stop
  BK_WAIT=60
  BK_PIDFILE="$_EX_STATE/ollama.pid"
  BK_HINT="Check $_EX_STATE/ollama.log, and that '$BK_MODEL' is pulled (ollama list)."
  # dev/opencode names `local-model`; for opencode, point this at a copy that names
  # $BK_MODEL instead (see BK_OPENCODE_DIR above).
  if [[ -n "${OLLAMA_OPENCODE_DIR:-}" ]]; then BK_OPENCODE_DIR="$OLLAMA_OPENCODE_DIR"; fi
  BK_EXCLUSIVE_WITH="llamacpp"   # optional: one model in memory at a time
}

# ── llamacpp ─────────────────────────────────────────────────────────────────
# llama.cpp's llama-server. Set LLAMACPP_START_CMD to the full command line, e.g.
#   export LLAMACPP_START_CMD="llama-server -m /models/model.gguf --port 8080 -c 131072 --alias local-model"
# It is split on spaces (no quoting), so keep paths free of spaces or wrap it in a
# script. Without LLAMACPP_START_CMD the backend is health-checked only: start
# llama-server yourself. `--alias local-model` makes /v1/models list the id that
# dev/opencode already names, so the default opencode config fits as-is.
_ex_llamacpp_start() {
  mkdir -p "$_EX_STATE"
  # shellcheck disable=SC2086   # word splitting is the point
  nohup ${LLAMACPP_START_CMD} >"$_EX_STATE/llamacpp.log" 2>&1 &
  echo $! >"$_EX_STATE/llamacpp.pid"
}
_ex_llamacpp_stop() {   # stops only the server this plugin started
  if [[ -f "$_EX_STATE/llamacpp.pid" ]]; then
    kill "$(cat "$_EX_STATE/llamacpp.pid")" 2>/dev/null || true
    rm -f "$_EX_STATE/llamacpp.pid"
  fi
}
backend_llamacpp() {
  BK_PORT="${LLAMACPP_PORT:-8080}"
  BK_MODEL="${LLAMACPP_MODEL:-local-model}"   # the id llama-server lists (its --alias)
  BK_LABEL="llama.cpp: $BK_MODEL (llama-server)"
  BK_CHECK_ID=1   # up only once /v1/models lists BK_MODEL, not just any server on the port
  if [[ -n "${LLAMACPP_START_CMD:-}" ]]; then
    BK_START=_ex_llamacpp_start
    BK_STOP=_ex_llamacpp_stop
    BK_PIDFILE="$_EX_STATE/llamacpp.pid"
  fi
  BK_WAIT=300     # a large GGUF can take minutes to load
  BK_HINT="Check $_EX_STATE/llamacpp.log; --port must be $BK_PORT and --alias $BK_MODEL."
  if [[ -n "${LLAMACPP_OPENCODE_DIR:-}" ]]; then BK_OPENCODE_DIR="$LLAMACPP_OPENCODE_DIR"; fi
  BK_EXCLUSIVE_WITH="ollama"     # optional: one model in memory at a time
}
