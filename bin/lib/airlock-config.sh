#!/usr/bin/env bash
#
# airlock-config.sh — owns everything about ONE PROJECT'S posture on the host: the
# control dir it lives in, the config and secrets files (parsed as data, never
# sourced), the key allow lists and per-key validation, the four tool-state mount
# sources, and which credentials the selected harness is handed.
#
# It answers "what is this project allowed to be", where airlock-kit.sh answers
# "what can the image be at all" and airlock-whitelist.sh composes the egress list.
#
# Sourced, defines functions only. Callers provide $NAME, $HARNESS_DIR and $CTL
# (via ctl_init); the variables below are the parse's own state.

# ── the control dir ───────────────────────────────────────────────────────────
# Per-project, HOST-side, and outside every path the sandbox can mount: the agent
# owns /workspace, so nothing that decides how the sandbox is built may live there.
# Keyed by the absolute path of the project dir, with the same slug + path-hash
# recipe bin/harness uses for COMPOSE_PROJECT_NAME — a project's stack and its
# control dir therefore carry the same name.
AIRLOCK_HOME="${AIRLOCK_HOME:-$HOME/.airlock}"
CTL=""

ctl_dir_for() {
  local p="$1" slug hash
  slug="$(basename "$p" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/-*$//')"
  hash="$(printf '%s' "$p" | shasum | cut -c1-6)"
  printf '%s/%s-%s' "$AIRLOCK_HOME" "$slug" "$hash"
}

ctl_init() {
  CTL="$(ctl_dir_for "$1")"
  mkdir -p "$CTL/state"
  chmod 700 "$AIRLOCK_HOME" "$CTL" 2>/dev/null || true
}

# Best-effort realpath (macOS bash 3.2 has no `realpath`): resolve the deepest
# EXISTING ancestor with `cd -P`, then re-attach the missing tail. Symlinks in the
# existing part are resolved — which is the whole point of every caller here.
abs_real() {
  local p="$1" tail=""
  while [[ -n "$p" && "$p" != "/" && ! -e "$p" ]]; do
    tail="$(basename "$p")${tail:+/$tail}"
    p="$(dirname "$p")"
  done
  if [[ -d "$p" ]]; then
    p="$(cd "$p" 2>/dev/null && pwd -P)"
  else
    p="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)/$(basename "$p")"
  fi
  printf '%s' "${p%/}${tail:+/$tail}"
}

# ── LOCAL_MODEL names ────────────────────────────────────────────────────────
# The kit ships ask | endpoint | off; a backends plugin (the shell file
# bin/sandbox-run sources: backends_file, bin/lib/airlock-backends.sh) registers
# more in BACKENDS_EXTRA. Read here in a subshell so nothing it
# sets leaks into this process — sandbox-run is where it is actually loaded. The
# plugin path comes from the host (env or the harness checkout), never from the
# config: it is code.
plugin_backends() {
  local f; f="$(backends_file)"
  [[ -f "$f" ]] || return 0
  ( BACKENDS_EXTRA=""; . "$f" >/dev/null 2>&1; printf '%s' "${BACKENDS_EXTRA:-}" )
}
local_model_names() { local p; p="$(plugin_backends)"; echo "ask endpoint off${p:+ $p}"; }
local_model_known() {
  case "$1" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac   # one word, or "endpoint off" would match
  case " $(local_model_names) " in *" $1 "*) return 0 ;; esac
  return 1
}

# ── the config: parsed, never sourced ────────────────────────────────────────
# The config sits on the host now, but it is still read as DATA against a fixed key
# allow list: `source` would make any typo a shell command, and the file also comes
# in from elsewhere via `import`, which reads a file the sandbox could have written.
# It is read ONCE into $conf_content; the parse works on that string.
conf_file=""; conf_content=""
CFG_KEYS=(); CFG_VALS=()
CFG_MODE=config          # 'config' or 'secrets' — which allow list the parse uses

conf_read() {   # <file> — read it into $conf_content, or return 1
  conf_file="$1"; conf_content=""
  [[ -f "$conf_file" ]] || return 1
  conf_content="$(cat "$conf_file")"
  return 0
}

cfg_die() {
  echo "$NAME: $conf_file line $1: $2" >&2
  if [[ "$CFG_MODE" == "secrets" ]]; then
    echo "  the secrets file is parsed as data, not shell: NAME=value only, one of $SEC_NAMES." >&2
  else
    echo "  the config is parsed as data, not shell — see templates/airlock.example." >&2
  fi
  exit 1
}

# The allow list is a security boundary, not a convenience. Deliberately NOT
# allowed, and why:
#   EXTRA_WHITELIST             point squid at a list from somewhere else
#   OPENCODE_DIR, WORKSPACE, PROJECT   choose what gets mounted
#   COMPOSE_*, HARNESS_*, PATH, AIRLOCK_HOME   the control plane
#   OPENAI_API_KEY & every other credential   those live in `env` next to this
#                               file (0600), so a shared config never carries a key
cfg_allowed() {
  case "$1" in
    STACK|COMPONENTS|DEV_DOCKERFILE|WHITELIST|HARNESS|GH)           return 0 ;;
    GC|GC_DAYS)                                                     return 0 ;;
    CLAUDE_STATE|CODEX_STATE|GH_STATE|COPILOT_STATE)                return 0 ;;
    LOCAL_MODEL|ANTHROPIC_MODEL|LLM_MODEL)                          return 0 ;;
    LLM_HOST|LLM_PORT|LLM_KEY|LLM_CONTEXT|LLM_OUTPUT)               return 0 ;;
    ANGULAR_VERSION|JDK_VERSION)                                    return 0 ;;
  esac
  return 1
}

# ── the secrets file ──────────────────────────────────────────────────────────
# `<control dir>/env`, mode 0600, same strict parser, its OWN allow list: exactly
# the credential variables docker-compose.yml passes into the `dev` service. It is
# a separate file from `config` on purpose — a config is the kind of thing you send
# a teammate or keep in a template repo, and `import` must never carry a key along
# with it (it reads and writes `config`, and nothing else).
CRED_NAMES="OPENAI_API_KEY OPENROUTER_API_KEY ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN"

# LLM_KEY may live here too: the `endpoint` server's key. It is not a compose
# credential (the sandbox only ever sees it as the endpoint's OPENAI_API_KEY, and
# only for a harness that uses one — sandbox-run decides that), so it is not on
# CRED_NAMES; it overrides an LLM_KEY in the config, where older configs kept it.
SEC_NAMES="$CRED_NAMES LLM_KEY"

sec_allowed() {
  local n
  for n in $SEC_NAMES; do [[ "$1" == "$n" ]] && return 0; done
  return 1
}

# Which of those belong to which harness. A credential the selected harness cannot
# use has no business being in the container: `copilot` authenticates through its
# own device flow and needs none of these at all.
creds_for_harness() {
  case "$1" in
    opencode) echo "OPENAI_API_KEY OPENROUTER_API_KEY" ;;
    claude)   echo "ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN" ;;
    codex)    echo "OPENAI_API_KEY" ;;
    copilot)  echo "" ;;
  esac
}

# Where a *_STATE mount may never point. $STATE_WHY carries the reason out.
STATE_WHY=""
state_path_ok() {
  local p bad home_real ah
  p="$(abs_real "$1")"
  home_real="$(abs_real "$HOME")"
  ah="$(abs_real "$AIRLOCK_HOME")"
  STATE_WHY=""
  case "$p" in
    /|"$home_real") STATE_WHY="it is / or your home directory" ;;
    "$HARNESS_DIR"|"$HARNESS_DIR"/*) STATE_WHY="it is inside the harness repo" ;;
  esac
  if [[ -z "$STATE_WHY" ]]; then
    case "$p" in
      "$ah") STATE_WHY="it is the control-dir root" ;;
      "$ah"/*)
        case "$p" in
          */state|*/state/*) : ;;
          *) STATE_WHY="it is inside the control dir but is not a state/ directory" ;;
        esac ;;
    esac
  fi
  if [[ -z "$STATE_WHY" ]]; then
    for bad in .ssh .aws .gnupg .config .kube .docker Library; do
      case "$p" in
        "$home_real/$bad"|"$home_real/$bad"/*) STATE_WHY="it is inside ~/$bad" ;;
      esac
    done
  fi
  [[ -z "$STATE_WHY" ]]
}

# Per-key value checks. The character ban in parse_config already rules out shell
# metacharacters; these narrow each key to the shape it is documented to have, so
# a value cannot be smuggled through as a flag or a path.
cfg_validate() {
  local key="$1" val="$2" ln="$3" d rest
  case "$key" in
    STACK)
      kit_stack_known "$val" \
        || cfg_die "$ln" "STACK='$val' is not a known stack (airlock.json defines: $(kit_stack_list))" ;;
    COMPONENTS)
      # Overrides the stack's component set (build args AND whitelist blocks); STACK
      # stays the recipe's name. Extras alone (COMPONENTS=playwright) add to it. Validated here so a typo is a config error, not a
      # surprise image.
      # Empty = not set: the stack's own set applies.
      kit_load
      local why
      if [[ -n "$val" ]]; then
        why="$(kit_comps_normalize "$val")" || cfg_die "$ln" "COMPONENTS $why"
      fi ;;
    DEV_DOCKERFILE)
      case "$val" in
        Dockerfile) : ;;
        Dockerfile*)
          rest="${val#Dockerfile}"
          case "$rest" in *[!A-Za-z0-9._-]*) cfg_die "$ln" "DEV_DOCKERFILE='$val' may only contain letters, digits, '.', '_' and '-'" ;; esac ;;
        *) cfg_die "$ln" "DEV_DOCKERFILE='$val' must start with 'Dockerfile'" ;;
      esac
      [[ -f "$HARNESS_DIR/dev/$val" ]] \
        || cfg_die "$ln" "DEV_DOCKERFILE='$val' is not a file in $HARNESS_DIR/dev/" ;;
    WHITELIST)
      set -f
      for d in $val; do
        printf '%s' "$d" | grep -Eq '^\.?([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z][a-z-]+$' || {
          set +f
          cfg_die "$ln" "WHITELIST entry '$d' is not a plain domain (optional leading dot, lowercase labels, at least one dot; no IPs, wildcards, ports, paths or credentials)"
        }
      done
      set +f ;;
    CLAUDE_STATE|CODEX_STATE|GH_STATE|COPILOT_STATE)
      [[ "$val" == /* ]] || cfg_die "$ln" "$key must be an absolute path (or start with ~/)"
      state_path_ok "$val" \
        || cfg_die "$ln" "$key='$val' resolves somewhere the sandbox must never be handed: $STATE_WHY" ;;
    LOCAL_MODEL)
      local_model_known "$val" \
        || cfg_die "$ln" "LOCAL_MODEL='$val' ($(local_model_names | sed 's/ / | /g'))" ;;
    LLM_PORT)
      case "$val" in ''|*[!0-9]*) cfg_die "$ln" "LLM_PORT='$val' must be a port number" ;; esac
      [[ "$val" -ge 1 && "$val" -le 65535 ]] || cfg_die "$ln" "LLM_PORT='$val' is outside 1-65535" ;;
    LLM_HOST)
      # A hostname or an IP, nothing else: this value becomes the far end of the
      # socat pipe, i.e. the one host:port the sandbox can reach. A LAN GPU box is
      # a legitimate answer; a URL, a port suffix or a path is not.
      printf '%s' "$val" | grep -Eq '^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$' \
        || cfg_die "$ln" "LLM_HOST='$val' is not a hostname or IP (no scheme, port, path or credentials)" ;;
    LLM_KEY)
      # MAY BE EMPTY — most local servers want no key at all, and an absent key is
      # the common case rather than a mistake.
      case "$val" in *[!A-Za-z0-9._:+/=~-]*) cfg_die "$ln" "LLM_KEY has characters an API key does not have" ;; esac ;;
    LLM_CONTEXT|LLM_OUTPUT)
      case "$val" in ''|*[!0-9]*) cfg_die "$ln" "$key='$val' must be a number (tokens)" ;; esac ;;
    HARNESS)
      case "$val" in opencode|claude|codex|copilot) ;; *) cfg_die "$ln" "HARNESS='$val' (opencode | claude | codex | copilot)" ;; esac
      # A harness airlock.json does not build into the image cannot be started, so
      # this is a config error rather than a mystery at the first `airlock <verb>`.
      kit_harness_known "$val" \
        || cfg_die "$ln" "HARNESS='$val' is not built into the sandbox image — airlock.json lists: $(kit_harness_list). Add it there (the next launch rebuilds), or pick one of those" ;;
    GH)
      case "$val" in on|off) ;; *) cfg_die "$ln" "GH='$val' must be on or off" ;; esac ;;
    GC)
      case "$val" in on|off) ;; *) cfg_die "$ln" "GC='$val' must be on or off (off = no image sweep on this project's launches)" ;; esac ;;
    GC_DAYS)
      case "$val" in ''|*[!0-9]*) cfg_die "$ln" "GC_DAYS='$val' must be a whole number of days (0 = this project's image is never swept as stale)" ;; esac ;;
    ANGULAR_VERSION|JDK_VERSION)
      case "$val" in ''|*[!A-Za-z0-9._-]*) cfg_die "$ln" "$key='$val' is not a version string" ;; esac ;;
    ANTHROPIC_MODEL|LLM_MODEL)
      case "$val" in *[!A-Za-z0-9._:/@-]*) cfg_die "$ln" "$key='$val' is not a model name" ;; esac ;;
  esac
}

# Accepts exactly: blank lines, `#` comments, and `[export ]KEY=VALUE` where VALUE
# is bare, 'single'- or "double"-quoted. No expansion of any kind happens — not
# even inside double quotes — except a leading `~/` on the path keys.
parse_config() {
  local lineno=0 line t key rest val body tail c
  CFG_KEYS=(); CFG_VALS=()
  [[ -n "$conf_content" ]] || return 0
  while IFS= read -r line; do
    lineno=$((lineno+1))
    line="${line%$'\r'}"                          # tolerate CRLF checkouts
    t="${line#"${line%%[![:space:]]*}"}"          # ltrim
    [[ -z "$t" ]] && continue
    case "$t" in '#'*) continue ;; esac
    case "$t" in
      export[[:space:]]*) t="${t#export}"; t="${t#"${t%%[![:space:]]*}"}" ;;
    esac
    case "$t" in
      *=*) : ;;
      *) cfg_die "$lineno" "not a KEY=VALUE line: $line" ;;
    esac
    key="${t%%=*}"; rest="${t#*=}"
    case "$key" in
      ''|[0-9]*|*[!A-Za-z0-9_]*) cfg_die "$lineno" "'$key' is not a valid key name" ;;
    esac

    case "$rest" in
      "'"*)
        body="${rest#\'}"
        case "$body" in
          *"'"*) val="${body%%\'*}"; tail="${body#*\'}" ;;
          *) cfg_die "$lineno" "unterminated single quote" ;;
        esac ;;
      '"'*)
        body="${rest#\"}"
        case "$body" in
          *'"'*) val="${body%%\"*}"; tail="${body#*\"}" ;;
          *) cfg_die "$lineno" "unterminated double quote" ;;
        esac ;;
      *)
        val="$rest"; tail=""
        case "$val" in *[[:space:]]#*) val="${val%%[[:space:]]#*}" ;; esac   # inline comment
        val="${val%"${val##*[![:space:]]}"}"                                 # rtrim
        ;;
    esac
    if [[ -n "$tail" ]]; then
      tail="${tail#"${tail%%[![:space:]]*}"}"
      case "$tail" in
        ''|'#'*) : ;;
        *) cfg_die "$lineno" "trailing text after the quoted value: $tail" ;;
      esac
    fi

    # Nothing here is ever expanded or run, so a value that LOOKS like shell is a
    # mistake at best and an escape attempt at worst. Refuse either way.
    for c in '$' '`' '\' ';' '&' '|' '<' '>' '(' ')'; do
      case "$val" in
        *"$c"*) cfg_die "$lineno" "value of $key contains '$c'; config values are literal text" ;;
      esac
    done

    if [[ "$CFG_MODE" == "secrets" ]]; then
      sec_allowed "$key" \
        || cfg_die "$lineno" "'$key' is not a credential this sandbox passes in. Allowed: $SEC_NAMES. Anything else belongs in your shell or the harness .env"
      # One shape check for all of them; the metacharacter ban above did the rest.
      case "$val" in *[!A-Za-z0-9._:+/=~-]*) cfg_die "$lineno" "$key has characters a credential does not have" ;; esac
      CFG_KEYS[${#CFG_KEYS[@]}]="$key"
      CFG_VALS[${#CFG_VALS[@]}]="$val"
      continue
    fi

    cfg_allowed "$key" \
      || cfg_die "$lineno" "'$key' is not an allowed config key. Allowed: STACK COMPONENTS DEV_DOCKERFILE WHITELIST HARNESS GH GC GC_DAYS *_STATE LOCAL_MODEL ANTHROPIC_MODEL LLM_HOST LLM_PORT LLM_MODEL LLM_KEY LLM_CONTEXT LLM_OUTPUT ANGULAR_VERSION JDK_VERSION. Host/mount/secret settings belong in the harness .env or your shell"

    case "$key" in
      CLAUDE_STATE|CODEX_STATE|GH_STATE|COPILOT_STATE)
        case "$val" in '~/'*) val="$HOME/${val#'~/'}" ;; esac ;;
    esac
    cfg_validate "$key" "$val" "$lineno"

    CFG_KEYS[${#CFG_KEYS[@]}]="$key"
    CFG_VALS[${#CFG_VALS[@]}]="$val"
  done <<EOF
$conf_content
EOF
}

# Config values win over inherited environment, exactly as `set -a; source` did.
apply_config() {
  local i=0
  while [[ $i -lt ${#CFG_KEYS[@]} ]]; do
    export "${CFG_KEYS[$i]}=${CFG_VALS[$i]}"
    i=$((i+1))
  done
}

show_effective() {
  local i=0 k v
  echo "  control dir: $CTL"
  if [[ ${#CFG_KEYS[@]} -eq 0 ]]; then
    echo "    (no settings — built-in defaults apply)"
  fi
  while [[ $i -lt ${#CFG_KEYS[@]} ]]; do
    k="${CFG_KEYS[$i]}"; v="${CFG_VALS[$i]}"
    case "$k" in
      *_STATE) echo "    $k=$v   → mounts $(abs_real "$v")" ;;
      STACK)   echo "    $k=$v   → stack components: $(kit_stack_comps "$v" 2>/dev/null)" ;;
      COMPONENTS)
        if [[ -n "$v" ]] && kit_comps_extras_only "$(kit_comps_normalize "$v" 2>/dev/null)"; then
          echo "    $k=$v   → added to STACK's components: $(kit_comps_normalize "$v" 2>/dev/null)"
        elif [[ -n "$v" ]]; then
          echo "    $k=$v   → image components: $(kit_comps_normalize "$v" 2>/dev/null) (overrides STACK's)"
        else
          echo "    $k=   (empty — STACK's components apply)"
        fi ;;
      # Even a local server's key is a credential: show that it is set, not what it is.
      LLM_KEY) echo "    $k=${v:+<set, ${#v} chars>}" ;;
      *)       echo "    $k=$v" ;;
    esac
    i=$((i+1))
  done
}

# ── reading the secrets file ──────────────────────────────────────────────────
SEC_KEYS=(); SEC_VALS=()

# `<control dir>/env` → SEC_KEYS/SEC_VALS. No file = no secrets, which is the
# normal case (a local model needs none). The mode is enforced, not assumed: this
# is a key file, and it sits in a dir the user may well have copied around.
read_secrets() {
  SEC_KEYS=(); SEC_VALS=()
  local f="$CTL/env" mode i
  [[ -f "$f" ]] || return 0
  mode="$(stat -f '%Lp' "$f" 2>/dev/null || stat -c '%a' "$f" 2>/dev/null || echo 600)"
  if [[ "$mode" != "600" ]]; then
    if chmod 600 "$f" 2>/dev/null; then
      echo "$NAME: tightened $f to 0600 — it holds credentials." >&2
    else
      echo "$NAME: refusing — $f is mode $mode and could not be tightened to 0600." >&2
      exit 1
    fi
  fi
  conf_read "$f" || return 0
  CFG_MODE=secrets
  parse_config
  CFG_MODE=config
  i=0
  while [[ $i -lt ${#CFG_KEYS[@]} ]]; do
    SEC_KEYS[${#SEC_KEYS[@]}]="${CFG_KEYS[$i]}"
    SEC_VALS[${#SEC_VALS[@]}]="${CFG_VALS[$i]}"
    i=$((i+1))
  done
  CFG_KEYS=(); CFG_VALS=()
}

sec_get() {   # <NAME> → its value, or the empty string
  local i=0
  while [[ $i -lt ${#SEC_KEYS[@]} ]]; do
    [[ "${SEC_KEYS[$i]}" == "$1" ]] && { printf '%s' "${SEC_VALS[$i]}"; return 0; }
    i=$((i+1))
  done
  printf ''
}

sec_names() {  # the names present in the file — never the values
  local i=0 out=""
  while [[ $i -lt ${#SEC_KEYS[@]} ]]; do
    out="${out:+$out }${SEC_KEYS[$i]}"; i=$((i+1))
  done
  printf '%s' "$out"
}

# The verb that runs each harness. opencode is the odd one out ('oc').
harness_verb() {
  case "$1" in opencode) echo "oc" ;; *) echo "$1" ;; esac
}

# A `.airlock` inside the project is inert now. Say so once per launch rather than
# letting someone edit a file that has no effect — or assume it still has one.
stray_conf_dir() {
  local d="$PWD"
  while :; do
    if [[ -f "$d/.airlock" ]]; then printf '%s' "$d"; return 0; fi
    [[ "$d" == "/" || "$d" == "$HOME" ]] && break
    d="$(dirname "$d")"
  done
  return 1
}

# One-time migration out of the old in-project .airlock-state/. Symlinks are never
# followed and never moved — one of them is exactly the attack this move closes.
migrate_state() {
  local old="$1" sub src dst moved=0
  [[ -d "$old" && ! -L "$old" ]] || return 0
  for sub in claude codex gh copilot; do
    src="$old/$sub"; dst="$state_root/$sub"
    [[ -e "$src" || -L "$src" ]] || continue
    if [[ -L "$src" ]]; then
      echo "$NAME: migration SKIPPED $src — it is a symlink (never followed). Delete it yourself." >&2
      continue
    fi
    if [[ ! -d "$src" ]]; then
      echo "$NAME: migration skipped $src — not a directory." >&2
      continue
    fi
    if [[ -n "$(ls -A "$dst" 2>/dev/null || true)" ]]; then
      echo "$NAME: migration skipped $sub — $dst already has content." >&2
      continue
    fi
    rmdir "$dst" 2>/dev/null || true       # the empty dir we may have just created
    if [[ -e "$dst" ]]; then
      echo "$NAME: migration skipped $sub — $dst is in the way." >&2
      continue
    fi
    mv "$src" "$dst" && { echo "$NAME: moved $src → $dst"; moved=$((moved+1)); }
  done
  [[ "$moved" -gt 0 ]] || return 0
  [[ "$(ls -A "$old" 2>/dev/null || true)" == ".gitignore" ]] && rm -f "$old/.gitignore"
  if rmdir "$old" 2>/dev/null; then
    echo "$NAME: removed the now-empty $old"
  else
    echo "$NAME: $old still has files in it — left in place; delete it once you've checked." >&2
  fi
}

# Every launch re-checks the four mount sources. A bind mount follows symlinks on
# the HOST, so a symlink here is a hole even when the path looks innocent.
state_check() {
  local k p real root_real
  root_real="$(abs_real "$state_root")"
  for k in CLAUDE_STATE CODEX_STATE GH_STATE COPILOT_STATE; do
    p="${!k}"
    mkdir -p "$p" 2>/dev/null || true
    if [[ -L "$p" ]]; then
      echo "$NAME: refusing — $k=$p is a symlink; a mount source must be a real directory." >&2
      exit 1
    fi
    if [[ ! -d "$p" ]]; then
      echo "$NAME: refusing — $k=$p is not a directory." >&2
      exit 1
    fi
    real="$(abs_real "$p")"
    case "$p" in
      "$state_root"/*)
        case "$real" in
          "$root_real"/*) : ;;
          *) echo "$NAME: refusing — $k resolves to $real, outside the control dir $root_real." >&2
             exit 1 ;;
        esac ;;
      *)
        state_path_ok "$real" || {
          echo "$NAME: refusing — $k=$real: $STATE_WHY" >&2
          exit 1
        } ;;
    esac
  done
}

# Swap every state mount the selected harness does not own for an empty
# placeholder. The real dirs are still created, migrated and symlink-checked above
# — they hold logins the user made and will want again after flipping HARNESS —
# they simply are not handed to this container.
select_state_mounts() {
  local unused="$state_root/unused" slot var keep
  mkdir -p "$unused/claude" "$unused/codex" "$unused/gh" "$unused/copilot" 2>/dev/null || true
  for slot in claude codex gh copilot; do
    case "$slot" in
      gh) [[ "$GH" == "on" ]] && keep=1 || keep=0 ;;
      *)  [[ "$HARNESS" == "$slot" ]] && keep=1 || keep=0 ;;
    esac
    [[ "$keep" == 1 ]] && continue
    case "$slot" in
      claude)  export CLAUDE_STATE="$unused/claude" ;;
      codex)   export CODEX_STATE="$unused/codex" ;;
      gh)      export GH_STATE="$unused/gh" ;;
      copilot) export COPILOT_STATE="$unused/copilot" ;;
    esac
  done
}

# Every credential compose can pass into `dev` is EXPORTED here, even when it is
# empty. That is the point: compose prefers an exported variable over the harness
# repo's .env, so an OPENAI_API_KEY sitting in the user's ~/.zshrc for some other
# tool cannot ride into a sandbox just because it happened to be in the shell.
# Only the ones the selected harness can actually use get a value, and that value
# comes from the project's own secrets file or from nowhere.
export_credentials() {
  local n a v allowed used=""
  read_secrets
  allowed="$(creds_for_harness "$HARNESS")"
  for n in $CRED_NAMES; do
    v=""
    for a in $allowed; do
      [[ "$n" == "$a" ]] && v="$(sec_get "$n")"
    done
    export "$n=$v"
    [[ -n "$v" ]] && used="${used:+$used, }$n (project secrets)"
  done
  v="$(sec_get LLM_KEY)"
  if [[ -n "$v" ]]; then
    export "LLM_KEY=$v"
    used="${used:+$used, }LLM_KEY (project secrets, endpoint)"
  fi
  # Names only, never values — this line is printed on every launch. The egress
  # half names the BLOCKS and counts the domains; the domains themselves are one
  # '$NAME verify' away and would bury the credential half.
  echo "$NAME: into sandbox → harness=$HARNESS, credentials: ${used:-none}, gh: $GH, egress: $WL_COUNT domain(s) via [$WL_BLOCKS]"
}

# Called after the project whitelist has been written, so it sees the list that
# will actually be in force.
gh_warn() {
  [[ "$GH" == "on" ]] || return 0
  gh_egress_open || return 0
  echo "$NAME: WARNING — GH=on and the whitelist allows api.github.com/.github.com." >&2
  echo "  A gh token plus that domain is an upload path (gh api, gist create): the agent can" >&2
  echo "  push data out of the sandbox through it. Keep one or the other, or give the sandbox" >&2
  echo "  a read-only token." >&2
}

# Does the EFFECTIVE whitelist reach GitHub's API host? Token-exact on purpose:
# `codeload.github.com` CONTAINS the string ".github.com" without opening it — only
# an entry that IS `.github.com` (or `api.github.com`) unlocks the API host.
gh_egress_open() {
  [[ -f "$CTL/whitelist.txt" ]] || return 1
  grep -vE '^[[:space:]]*(#|$)' "$CTL/whitelist.txt" 2>/dev/null \
    | grep -Fqx -e '.github.com' -e 'api.github.com'
}
