#!/usr/bin/env bash
#
# airlock-init.sh — owns how a project GETS its config: the one function that writes
# it (used by `init --stack S` and by the wizard alike), the project-type detection
# that suggests a stack, and the first-launch wizard itself.
#
# Why a wizard at all: a project with no config used to launch on a built-in default
# (STACK=java-angular), so `cd project && airlock oc` silently built a ~6.5 GB
# JDK + Angular image for a Python app. Now a launch verb with no config either asks
# (at a terminal) or refuses with the exact `init` command (anywhere else). The
# dispatcher (bin/airlock) decides WHEN; this file only knows HOW.
#
# The detection reads the project tree, which is agent-writable (0012) — so it only
# ever produces a SUGGESTION a human confirms at a terminal. Nothing it finds is
# written anywhere without that, and the non-interactive path never reads it.
#
# Sourced, defines functions only. Callers provide $NAME, $HARNESS_DIR
# and $CTL (via ctl_init), and have sourced airlock-kit.sh.
#
# Exposes:
#   detect_project_stack <dir>   → "<stack>|<reason>" on stdout (pure: reads <dir> only)
#   init_write_config <dir> <stack> <harness> [components] [local-model]   writes $CTL/config
#                                (for local-model=endpoint it also writes INIT_LLM_HOST/PORT/MODEL)
#   init_write_key <key>         puts LLM_KEY in the secrets file ($CTL/env, 0600)
#   init_wizard <dir> [harness]  asks on stdin/stderr (a harness given = the answer, not asked) → WIZ_STACK WIZ_HARNESS WIZ_COMPONENTS
#                                WIZ_LOCAL_MODEL, and for endpoint INIT_LLM_HOST/PORT/MODEL + WIZ_LLM_KEY
#   harness_blurb <harness>      the one-line description the menu shows

# ── project-type detection ───────────────────────────────────────────────────
# Marker files in the project root or one directory down (a repo with backend/ and
# frontend/ subdirs counts) — two directories down for .NET, whose usual layout is
# src/<Project>/<Project>.csproj. First match wins, in this order: a JVM build → java-angular, a .NET project →
# dotnet, a Python project → base (node + python), a package.json alone → node,
# nothing → base. A suggested stack the kit does not define falls back to base (or
# the kit's first stack). Prints "<stack>|<reason>".
detect_project_stack() {   # <dir>
  local d="$1" hit stack reason
  _dps_find() {   # <dir levels> <find name args…> → the first match, relative to $d
    local depth=$(( $1 + 1 )); shift
    ( cd "$d" 2>/dev/null && find . -maxdepth "$depth" \( -name .git -o -name node_modules \) -prune -o \
        -type f \( "$@" \) -print 2>/dev/null | sed 's|^\./||' | sort | head -1 )
  }
  if hit="$(_dps_find 1 -name pom.xml -o -name 'build.gradle*')" && [[ -n "$hit" ]]; then
    stack=java-angular; reason="found $hit"
  elif hit="$(_dps_find 2 -name '*.csproj' -o -name '*.sln')" && [[ -n "$hit" ]]; then
    stack=dotnet; reason="found $hit"
  elif hit="$(_dps_find 1 -name pyproject.toml -o -name 'requirements*.txt')" && [[ -n "$hit" ]]; then
    stack=base; reason="found $hit"
  elif hit="$(_dps_find 1 -name package.json)" && [[ -n "$hit" ]]; then
    stack=node; reason="found $hit (and no Python/JVM/.NET project file)"
  else
    stack=base; reason="no project file recognised"
  fi
  unset -f _dps_find
  if ! kit_stack_known "$stack"; then
    reason="$reason, but airlock.json has no '$stack' stack"
    stack=base
    kit_stack_known base || { stack="$(kit_stack_list)"; stack="${stack%% *}"; }
  fi
  printf '%s|%s' "$stack" "$reason"
}

harness_blurb() {
  case "$1" in
    opencode) echo "local/cloud models via opencode.json" ;;
    claude)   echo "Claude Code" ;;
    codex)    echo "OpenAI Codex CLI" ;;
    copilot)  echo "GitHub Copilot CLI" ;;
    *)        echo "" ;;
  esac
}

# ── the one config writer ────────────────────────────────────────────────────
# `init --stack S` and the wizard both end here, so a config written either way is
# byte-for-byte the same shape. Validated by the caller re-parsing it.
init_write_config() {   # <dir> <stack> <harness> [components, canonical, space-separated] [local model]
  local dir="$1" stack="$2" harness="$3" comps="${4:-}" lm="${5:-off}" comps_line llm_lines
  if [[ -n "$comps" ]] && kit_comps_extras_only "$comps"; then
    comps_line="COMPONENTS=$(printf '%s' "$comps" | tr ' ' ',')"
    comps_line="$comps_line   # added to STACK's components (extras: $(echo $KIT_EXTRAS | sed 's/ / | /g'))"
  elif [[ -n "$comps" ]]; then
    comps_line="COMPONENTS=$(printf '%s' "$comps" | tr ' ' ',')"
    comps_line="$comps_line   # overrides STACK's components ($(echo $KIT_COMPONENTS | sed 's/ / | /g'); node required; + playwright)"
  else
    comps_line="# COMPONENTS=node,python      # overrides STACK's components (build + egress); node required
# COMPONENTS=playwright       # alone: STACK's components + Playwright and headless Chromium"
  fi
  # The LLM backend: what the wizard picked, or `off` (init off a terminal, and
  # `init --stack`) — a door to a host port is opened only when someone said so.
  if [[ "$lm" == endpoint ]]; then
    llm_lines="LLM_HOST=${INIT_LLM_HOST:-host.docker.internal}
LLM_PORT=${INIT_LLM_PORT}
LLM_MODEL=${INIT_LLM_MODEL}                # the id the server lists on /v1/models
# LLM_CONTEXT=131072          # keep at or below what the server was started with
# LLM_OUTPUT=16384"
  else
    llm_lines="# LLM_HOST=host.docker.internal   # LOCAL_MODEL=endpoint: your OpenAI-compatible server
# LLM_PORT=11434
# LLM_MODEL=llama3.1:8b"
  fi
  cat > "$CTL/config" <<EOF
# ${NAME} config for $dir — parsed (never sourced) by \`${NAME}\`.
# It lives here, outside the project, because the project is mounted read-write
# in the sandbox. Edit with '${NAME} config --edit'.
STACK=$stack                  # $(kit_stack_list | sed 's/ / | /g')
$comps_line
HARNESS=$harness              # $(kit_harness_list | sed 's/ / | /g') — ONE per project, the only CLI installed
# GH=on                       # mount the gh login (off by default: a token + a
#                             #   whitelisted .github.com is an upload path)
# WHITELIST="artifactory.corp.com pypi.internal"   # extra egress domains
# ANTHROPIC_MODEL=            # Claude Code model; empty = its default
LOCAL_MODEL=$lm              # $(local_model_names | sed 's/ / | /g') — the LLM door
$llm_lines
EOF
  cat >> "$CTL/config" <<'EOF'
# Credentials live in the `env` file next to this one, not here — edit it with the
# 'config --secrets' verb so that sharing this config can never carry a key.
# Tool state (Claude/codex/gh/copilot logins) lives in state/ next to this file.
# Only the selected HARNESS's state dir is mounted; the rest get empty placeholders.
# Override to share an identity across projects (absolute path or ~/…):
# CLAUDE_STATE=~/clients/acme/state/claude
# CODEX_STATE=
# GH_STATE=
# COPILOT_STATE=
EOF
  chmod 600 "$CTL/config" 2>/dev/null || true
}

# The endpoint's key goes to the secrets file, never the config: a config is the
# kind of thing that gets shared or imported. Replaces an LLM_KEY already there.
init_write_key() {   # <key>
  local f="$CTL/env" rest=""
  [[ -f "$f" ]] && rest="$(grep -v '^[[:space:]]*LLM_KEY=' "$f" || true)"
  ( umask 077
    { if [[ -n "$rest" ]]; then printf '%s\n' "$rest"
      else printf '# %s credentials for %s — parsed as data, never sourced.\n' "$NAME" "$PWD"; fi
      printf 'LLM_KEY=%s\n' "$1"; } > "$f.tmp" && mv "$f.tmp" "$f" )
  chmod 600 "$f" 2>/dev/null || true
}

# ── the wizard ───────────────────────────────────────────────────────────────
# Reads answers from stdin, writes prompts to stderr (stdout stays clean for the
# verb that follows). The caller has checked both are a terminal; the function itself
# does not, so the tests can drive it with a pipe. EOF on any question aborts with
# status 1 and nothing written.
_wiz_ask() {   # <prompt> → the answer in WIZ_ANS, or status 1 on EOF
  printf '%s' "$1" >&2
  WIZ_ANS=""
  IFS= read -r WIZ_ANS || return 1
  WIZ_ANS="${WIZ_ANS#"${WIZ_ANS%%[![:space:]]*}"}"
  WIZ_ANS="${WIZ_ANS%"${WIZ_ANS##*[![:space:]]}"}"
}

_wiz_pick() {   # <default number> <count> <prompt> → WIZ_PICK (1-based)
  local def="$1" n="$2" prompt="$3" tries=0
  while :; do
    _wiz_ask "$prompt [$def]: " || return 1
    [[ -z "$WIZ_ANS" ]] && WIZ_ANS="$def"
    case "$WIZ_ANS" in
      *[!0-9]*) : ;;
      *) if [[ "$WIZ_ANS" -ge 1 && "$WIZ_ANS" -le "$n" ]]; then WIZ_PICK="$WIZ_ANS"; return 0; fi ;;
    esac
    tries=$((tries+1))
    echo "  enter a number from 1 to $n (or press Enter for $def)" >&2
    [[ "$tries" -ge 5 ]] && return 1
  done
}

_wiz_yn() {   # <prompt> → status 0 for yes; WIZ_EOF=1 on EOF (answer counts as no)
  WIZ_EOF=0
  _wiz_ask "$1 [y/N]: " || { WIZ_EOF=1; return 1; }
  case "$WIZ_ANS" in y|Y|yes|YES|Yes) return 0 ;; esac
  return 1
}

init_wizard() {   # <dir> [the harness to pre-select — the verb typed, e.g. `airlock claude`]
  local dir="$1" want="${2:-}" det sug reason stacks s i n def h harnesses c comps
  WIZ_STACK=""; WIZ_HARNESS=""; WIZ_COMPONENTS=""
  kit_load
  det="$(detect_project_stack "$dir")"
  sug="${det%%|*}"; reason="${det#*|}"
  stacks="$(kit_stack_list)"

  {
    echo
    echo "$NAME: first launch for $dir — no config yet. A few questions, then it continues."
    echo "  (written to $CTL/config; change it later with '$NAME config --edit')"
    echo
    echo "Stack — what gets installed into the sandbox image:"
  } >&2
  i=0; def=1
  for s in $stacks; do
    i=$((i+1))
    [[ "$s" == "$sug" ]] && def=$i
    printf '  %d) %-14s %s\n' "$i" "$s" "$(kit_comps_label $(kit_stack_comps "$s"))" >&2
  done
  n=$((i+1))
  printf '  %d) %-14s %s\n' "$n" "custom" "— pick components one by one" >&2
  echo "  suggested: $def ($sug) — $reason" >&2
  _wiz_pick "$def" "$n" "  stack" || { echo "$NAME: no answer — nothing written." >&2; return 1; }

  if [[ "$WIZ_PICK" -lt "$n" ]]; then
    i=0
    for s in $stacks; do i=$((i+1)); [[ "$i" == "$WIZ_PICK" ]] && WIZ_STACK="$s"; done
  else
    # custom: STACK still names the recipe (base when the kit has one); COMPONENTS
    # carries the actual set and wins over it.
    WIZ_STACK=base
    kit_stack_known base || { WIZ_STACK="${stacks%% *}"; }
    echo >&2
    echo "Components — custom stack (Enter = no):" >&2
    echo "  $(kit_comp_label node): yes — always on (the harness CLIs are npm packages)" >&2
    comps="node"
    for c in python java angular dotnet; do
      if _wiz_yn "  $(kit_comp_label "$c")?"; then
        comps="$comps $c"
      elif [[ "$WIZ_EOF" == 1 ]]; then
        echo "$NAME: no answer — nothing written." >&2; return 1
      fi
    done
    WIZ_COMPONENTS="$(kit_comps_normalize "$comps")" || { echo "$NAME: $WIZ_COMPONENTS" >&2; return 1; }
  fi

  # Playwright is a per-project extra, off unless asked for: ~1 GB of Chromium is
  # dead weight in an image that never drives a browser. With a predefined stack it
  # is written as COMPONENTS=playwright (added to the stack's set); with custom it
  # joins the list.
  echo >&2
  if _wiz_yn "Bake Playwright + Chromium into this project's image?"; then
    WIZ_COMPONENTS="${WIZ_COMPONENTS:+$WIZ_COMPONENTS }playwright"
  elif [[ "$WIZ_EOF" == 1 ]]; then
    echo "$NAME: no answer — nothing written." >&2; return 1
  fi

  harnesses="$(kit_harness_list)"
  echo >&2
  if [[ -n "$want" ]] && printf '%s\n' $harnesses | grep -qx -- "$want"; then
    # The verb typed already names the harness: say so instead of asking.
    WIZ_HARNESS="$want"
    echo "Harness: $want — from the verb you typed (only it is installed; 'airlock config --edit' changes it)." >&2
  else
    echo "Harness — the ONE agent CLI this project runs (only it is installed):" >&2
    i=0; def=1
    for h in $harnesses; do
      i=$((i+1))
      printf '  %d) %-9s — %s\n' "$i" "$h" "$(harness_blurb "$h")" >&2
    done
    _wiz_pick "$def" "$i" "  harness" || { echo "$NAME: no answer — nothing written." >&2; return 1; }
    i=0
    for h in $harnesses; do i=$((i+1)); [[ "$i" == "$WIZ_PICK" ]] && WIZ_HARNESS="$h"; done
  fi
  _wiz_backend || { echo "$NAME: no answer — nothing written." >&2; return 1; }
  return 0
}

# The LLM backend: the one host port the sandbox may reach, or none. Claude Code and
# the Copilot CLI talk to their own vendor through the whitelist and use no door, so
# for them `off` is the default; opencode and codex default to `endpoint`. A backends
# plugin's pickers (and `ask`, the per-launch menu) are offered when one is loaded.
_wiz_backend() {
  local names="endpoint off" plugin b i def=1 lbl tries
  WIZ_LOCAL_MODEL=""; WIZ_LLM_KEY=""; INIT_LLM_HOST=""; INIT_LLM_PORT=""; INIT_LLM_MODEL=""
  plugin="$(plugin_backends)"
  [[ -n "$plugin" ]] && names="$names $plugin ask"
  echo >&2
  echo "LLM backend — the one model server the sandbox may reach (LOCAL_MODEL):" >&2
  i=0
  for b in $names; do
    i=$((i+1))
    case "$b" in
      endpoint) lbl="a local/LAN OpenAI-compatible server (Ollama, LM Studio, vLLM, llama-server…)" ;;
      off)      lbl="none — cloud APIs only, through the harness's own login" ;;
      ask)      lbl="ask at every launch" ;;
      *)        lbl="$(_wiz_plugin_label "$b")" ;;
    esac
    printf '  %d) %-9s — %s\n' "$i" "$b" "$lbl" >&2
  done
  case "$WIZ_HARNESS" in claude|copilot) def=2 ;; esac
  [[ -n "$plugin" ]] && def="$i"            # with a plugin, keep the per-launch menu
  _wiz_pick "$def" "$i" "  backend" || return 1
  i=0
  for b in $names; do i=$((i+1)); [[ "$i" == "$WIZ_PICK" ]] && WIZ_LOCAL_MODEL="$b"; done
  [[ "$WIZ_LOCAL_MODEL" == endpoint ]] || return 0

  echo "  The sandbox reaches it through the LLM door; host.docker.internal is this machine." >&2
  _wiz_ask "  host [host.docker.internal]: " || return 1
  INIT_LLM_HOST="${WIZ_ANS:-host.docker.internal}"
  printf '%s' "$INIT_LLM_HOST" | grep -Eq '^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$' \
    || { echo "  '$INIT_LLM_HOST' is not a hostname or IP." >&2; return 1; }
  tries=0
  while :; do
    _wiz_ask "  port (e.g. 11434 Ollama, 1234 LM Studio, 8080 llama-server): " || return 1
    case "$WIZ_ANS" in ''|*[!0-9]*) : ;; *) [[ "$WIZ_ANS" -ge 1 && "$WIZ_ANS" -le 65535 ]] && break ;; esac
    tries=$((tries+1)); [[ "$tries" -ge 5 ]] && return 1
    echo "  enter a port number (1-65535)" >&2
  done
  INIT_LLM_PORT="$WIZ_ANS"
  tries=0
  while :; do
    _wiz_ask "  model id (as the server lists it on /v1/models): " || return 1
    case "$WIZ_ANS" in ''|*[!A-Za-z0-9._:/@+-]*) : ;; *) break ;; esac
    tries=$((tries+1)); [[ "$tries" -ge 5 ]] && return 1
    echo "  enter the model id: letters, digits and . _ : / @ + - only" >&2
  done
  INIT_LLM_MODEL="$WIZ_ANS"
  if _wiz_yn "  does the server need an API key?"; then
    printf '  key (stored in the secrets file, not the config): ' >&2
    IFS= read -rs WIZ_LLM_KEY || return 1
    echo >&2
    case "$WIZ_LLM_KEY" in ''|*[!A-Za-z0-9._:+/=~-]*) echo "  that key has characters an API key does not have." >&2; return 1 ;; esac
  elif [[ "$WIZ_EOF" == 1 ]]; then
    return 1
  fi
  return 0
}

_wiz_plugin_label() {   # <name> → the plugin's BK_LABEL, read in a subshell
  ( f="$(backends_file)"; . "$f" >/dev/null 2>&1
    BK_LABEL="$1"; "backend_$1" >/dev/null 2>&1; printf '%s' "$BK_LABEL (backends plugin)" )
}

# One line for after the write: what the image will carry, in the menu's words.
wizard_summary() {   # <stack> <harness> [components] [local model]
  local comps
  comps="$(kit_effective_comps "$1" "${3:-}")"
  printf 'STACK=%s%s HARNESS=%s%s → image: %s + %s' "$1" "${3:+ COMPONENTS=$(printf '%s' "$3" | tr ' ' ',')}" \
    "$2" "${4:+ LOCAL_MODEL=$4}" "$(kit_comps_label $comps)" "$2"
}
