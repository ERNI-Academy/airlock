#!/usr/bin/env bash
#
# airlock-kit.sh — owns `airlock.json`, the KIT-level build config: which harness
# CLIs, which optional components and which STACK names exist at all. Everything
# in here answers questions about the IMAGE (what gets built into the sandbox),
# never about one project's posture — that is airlock-config.sh's job.
#
# Sourced, defines functions only. Callers must have HARNESS_DIR set; $NAME is
# used for messages and defaults to `airlock`.
#
# Exposes:
#   kit_file                        the path in force (AIRLOCK_KIT_CONFIG overrides)
#   kit_load                        parse + validate once, into the KIT_* variables
#   kit_stack_list                  the stack names, in file order
#   kit_stack_known <stack>
#   kit_stack_comps <stack>         its components, canonical order
#   kit_harness_list                the harness CLIs a project may pick from
#   kit_harness_known <harness>
#   kit_comps_normalize <list>      a COMPONENTS= value → canonical list (or why not)
#   kit_effective_comps <stack> [components]   COMPONENTS wins over the stack's set;
#                                   an extra (playwright) alone adds to the stack's set
#   kit_image_harnesses <harness…>  the kit's harnesses filtered to these, kit order
#   kit_export_build_args <stack> [components] [harnesses]
#                                   → the AIRLOCK_* build args compose passes
#   kit_stack_blocks <stack> [components]      → its egress whitelist blocks
#   kit_pin <VAR>                   a version pin: harness .env, else dev/Dockerfile ARG
#   kit_comp_label <comp> / kit_comps_label <comps…>   "java (JDK 25)" etc., for menus

KIT_LOADED=0
KIT_HARNESSES=""
KIT_STACK_NAMES=()
KIT_STACK_COMPS=()
KIT_COMPONENTS="node python java angular dotnet"   # canonical order, = kit_parse's
# Per-project EXTRAS: valid in a project's COMPONENTS= but not in an airlock.json
# stack, and additive — `COMPONENTS=playwright` is the stack's set plus Playwright,
# while a list that names any base component replaces the stack's set as before.
# Off unless a project asks; an extra brings no whitelist block (Playwright drives
# the app on localhost and is baked in at build time, so it needs no runtime egress).
KIT_EXTRAS="playwright"

kit_file() { printf '%s' "${AIRLOCK_KIT_CONFIG:-$HARNESS_DIR/airlock.json}"; }

# The parse + the validation, in python3 because the file is JSON and this repo
# already needs python3 to validate its JSON. Output is one flat record per line —
# `harnesses <names…>`, `stack <name> <components…>` — so the
# shell side never touches JSON. Every rejection prints why and which file.
kit_parse() {   # <file> → the records on stdout, or a message on stderr + status 1
  python3 - "$1" <<'PYEOF'
import json, re, sys

path = sys.argv[1]
HARNESSES = ("opencode", "claude", "codex", "copilot")
COMPONENTS = ("node", "python", "java", "angular", "dotnet")   # canonical order
STACK_RE = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")

def die(msg):
    sys.stderr.write("airlock: %s: %s\n" % (path, msg))
    sys.exit(1)

try:
    with open(path) as fh:
        kit = json.load(fh)
except ValueError as e:
    die("not valid JSON (%s)" % e)
except OSError as e:
    die("cannot be read (%s)" % e)

if not isinstance(kit, dict):
    die("the top level must be a JSON object")
for key in kit:
    if key.startswith("_"):
        continue            # _comment and friends: JSON has no comment syntax
    if key == "playwright":
        die("'playwright' is no longer a kit-wide switch: a project opts in with "
            "COMPONENTS=playwright in its own config (the wizard asks)")
    if key not in ("harnesses", "stacks"):
        die("unknown key '%s' (harnesses | stacks)" % key)

harnesses = kit.get("harnesses", list(HARNESSES))
if not isinstance(harnesses, list):
    die("'harnesses' must be a list, e.g. [\"opencode\"]")
seen = []
for h in harnesses:
    if not isinstance(h, str) or h not in HARNESSES:
        die("harness '%s' is not one of %s" % (h, " | ".join(HARNESSES)))
    if h in seen:
        die("harness '%s' is listed twice" % h)
    seen.append(h)
harnesses = seen

stacks = kit.get("stacks")
if stacks is None:
    die("no 'stacks' — at least one stack has to exist for STACK= to name")
if not isinstance(stacks, dict) or not stacks:
    die("'stacks' must be a non-empty object of <name>: {<component>: true}")

out = ["harnesses " + " ".join(harnesses)]
for name, comps in stacks.items():
    if not STACK_RE.match(name):
        die("stack name '%s' may only be lowercase letters, digits and inner '-'" % name)
    if not isinstance(comps, dict):
        die("stack '%s' must be an object of <component>: true|false" % name)
    for c in comps:
        if c not in COMPONENTS:
            die("stack '%s': unknown component '%s' (%s)" % (name, c, " | ".join(COMPONENTS)))
        if not isinstance(comps[c], bool):
            die("stack '%s': component '%s' must be true or false" % (name, c))
    on = [c for c in COMPONENTS if comps.get(c)]
    # node is not decoration: the harness CLIs are npm packages and the Angular CLI is
    # one. A stack that needs any of those and
    # says node: false would build an image without the tool it was asked for.
    if "node" not in on:
        needs = []
        if harnesses:
            needs.append("the harness CLIs (%s)" % ", ".join(harnesses))
        if "angular" in on:
            needs.append("angular")
        if needs:
            die("stack '%s' has node: false, but %s need node" % (name, " and ".join(needs)))
    out.append(("stack %s " % name) + " ".join(on))

sys.stdout.write("\n".join(out) + "\n")
PYEOF
}

# Parse once per process. Any rejection is fatal: a kit config we cannot vouch for
# decides what gets installed into the sandbox, so guessing is not an option.
kit_load() {
  [[ "$KIT_LOADED" == 1 ]] && return 0
  local f out line key rest
  f="$(kit_file)"
  if [[ ! -f "$f" ]]; then
    echo "${NAME:-airlock}: no kit config at $f" >&2
    echo "  airlock.json says which harness CLIs, components and stacks are built into" >&2
    echo "  the sandbox image. Restore it from the repo, or point AIRLOCK_KIT_CONFIG elsewhere." >&2
    exit 1
  fi
  out="$(kit_parse "$f")" || exit 1
  KIT_STACK_NAMES=(); KIT_STACK_COMPS=()
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    key="${line%% *}"; rest="${line#* }"
    case "$key" in
      harnesses)  KIT_HARNESSES="$rest" ;;
      stack)      KIT_STACK_NAMES[${#KIT_STACK_NAMES[@]}]="${rest%% *}"
                  KIT_STACK_COMPS[${#KIT_STACK_COMPS[@]}]="${rest#* }" ;;
    esac
  done <<EOF
$out
EOF
  KIT_LOADED=1
}

kit_stack_list() {
  kit_load
  local i=0 out=""
  while [[ $i -lt ${#KIT_STACK_NAMES[@]} ]]; do
    out="${out:+$out }${KIT_STACK_NAMES[$i]}"; i=$((i+1))
  done
  printf '%s' "$out"
}

kit_stack_comps() {   # <stack> → its components, or nothing
  kit_load
  local i=0
  while [[ $i -lt ${#KIT_STACK_NAMES[@]} ]]; do
    if [[ "${KIT_STACK_NAMES[$i]}" == "$1" ]]; then
      printf '%s' "${KIT_STACK_COMPS[$i]}"; return 0
    fi
    i=$((i+1))
  done
  return 1
}

# kit_load first, OUTSIDE the redirection: a kit config that does not parse must
# still say so, not disappear into /dev/null with the lookup.
kit_stack_known() { kit_load; kit_stack_comps "$1" >/dev/null 2>&1; }

kit_harness_list() { kit_load; printf '%s' "$KIT_HARNESSES"; }

kit_harness_known() {
  kit_load
  local h
  for h in $KIT_HARNESSES; do [[ "$h" == "$1" ]] && return 0; done
  return 1
}

# COMPONENTS= (a project config key) → the canonical, de-duplicated component list
# on stdout. On a bad value: the reason on stdout and status 1 — callers run this in
# $(…), so the message has to travel the same way the answer does. Comma- or
# space-separated; node is required for the same reason kit_parse requires it of a
# stack: the harness CLIs are npm packages (and so are Angular and Playwright).
kit_comps_normalize() {   # <list>
  local raw c k ok base="" extras=""
  raw="$(printf '%s' "$1" | tr ',' ' ')"
  set -f
  for c in $raw; do
    ok=0
    for k in $KIT_COMPONENTS $KIT_EXTRAS; do [[ "$c" == "$k" ]] && ok=1; done
    if [[ "$ok" == 0 ]]; then
      set +f
      printf "unknown component '%s' (%s)" "$c" "$(echo $KIT_COMPONENTS $KIT_EXTRAS | sed 's/ / | /g')"
      return 1
    fi
  done
  for k in $KIT_COMPONENTS; do
    for c in $raw; do [[ "$c" == "$k" ]] && { base="${base:+$base }$k"; break; }; done
  done
  for k in $KIT_EXTRAS; do
    for c in $raw; do [[ "$c" == "$k" ]] && { extras="${extras:+$extras }$k"; break; }; done
  done
  set +f
  if [[ -z "$base$extras" ]]; then
    printf 'is empty — list the components, e.g. COMPONENTS=node,python'
    return 1
  fi
  # Extras alone add to the stack's set, so only a list that names base components
  # has to carry node.
  if [[ -n "$base" ]]; then
    case " $base " in
      *" node "*) : ;;
      *) printf "'%s' has no node — node is required: the harness CLIs, Angular and Playwright are npm packages" "$1"
         return 1 ;;
    esac
  fi
  printf '%s' "$base${base:+${extras:+ }}$extras"
}

kit_is_extra() {   # <component>
  local k
  for k in $KIT_EXTRAS; do [[ "$1" == "$k" ]] && return 0; done
  return 1
}

# True when a normalized COMPONENTS list names extras only (it then ADDS to the
# stack's set rather than replacing it).
kit_comps_extras_only() {   # <canonical list>
  local c
  for c in $1; do kit_is_extra "$c" || return 1; done
  return 0
}

# What actually gets installed: the project's COMPONENTS when it set one, otherwise
# the stack's own set. One function, so the build args and the whitelist blocks
# cannot disagree about which of the two won.
kit_effective_comps() {   # <stack> [components]
  kit_load
  local norm
  if [[ -n "${2:-}" ]]; then
    norm="$(kit_comps_normalize "$2")" || { printf '%s' "$norm"; return 1; }
    if kit_comps_extras_only "$norm"; then
      printf '%s %s' "$(kit_stack_comps "$1")" "$norm"
    else
      printf '%s' "$norm"
    fi
  else
    kit_stack_comps "$1"
  fi
}

# The harness CLIs to build in: the kit's list, filtered to the ones asked for, in
# the KIT's order — so `opencode claude` and `claude opencode` are the same build arg
# and the same cached layer.
kit_image_harnesses() {   # <harness…>
  kit_load
  local h w out=""
  for h in $KIT_HARNESSES; do
    for w in "$@"; do [[ "$h" == "$w" ]] && { out="${out:+$out }$h"; break; }; done
  done
  printf '%s' "$out"
}

# STACK (or COMPONENTS) → the build args compose hands the (single, parametrised)
# dev/Dockerfile. AIRLOCK_-prefixed so an ambient WITH_JAVA in someone's shell cannot
# decide what gets installed; compose's defaults reproduce the base image for raw
# callers. The third argument narrows the harness CLIs (bin/airlock passes the
# project's ONE harness); without it the whole kit list is installed.
kit_export_build_args() {   # <stack> [components] [harnesses]
  kit_load
  local c comps
  comps="$(kit_effective_comps "$1" "${2:-}")" || {
    echo "${NAME:-airlock}: COMPONENTS ${comps}" >&2; exit 1; }
  export AIRLOCK_HARNESSES="${3:-$KIT_HARNESSES}"
  export AIRLOCK_WITH_PLAYWRIGHT=0
  export AIRLOCK_WITH_NODE=0 AIRLOCK_WITH_PYTHON=0 AIRLOCK_WITH_JAVA=0 \
         AIRLOCK_WITH_ANGULAR=0 AIRLOCK_WITH_DOTNET=0
  for c in $comps; do
    case "$c" in
      node)    export AIRLOCK_WITH_NODE=1 ;;
      python)  export AIRLOCK_WITH_PYTHON=1 ;;
      java)    export AIRLOCK_WITH_JAVA=1 ;;
      angular) export AIRLOCK_WITH_ANGULAR=1 ;;
      dotnet)  export AIRLOCK_WITH_DOTNET=1 ;;
      playwright) export AIRLOCK_WITH_PLAYWRIGHT=1 ;;
    esac
  done
}

# STACK (or COMPONENTS) → its egress whitelist blocks, derived from the SAME
# components that decide what is installed (0015 kept a second hard-coded table; it
# could drift from the images, and now cannot). `angular` resolves through npm, so
# stack-node covers it.
kit_stack_blocks() {   # <stack> [components]
  kit_load
  local c out=""
  for c in $(kit_effective_comps "$1" "${2:-}" 2>/dev/null); do
    case "$c" in
      node)   out="${out:+$out }stack-node" ;;
      python) out="${out:+$out }stack-python" ;;
      java)   out="${out:+$out }stack-java" ;;
      dotnet) out="${out:+$out }stack-dotnet" ;;
    esac
  done
  printf '%s' "$out"
}

# ── labels for the first-launch menu ──────────────────────────────────────────
# The versions a component will be built at, READ from where the build takes them —
# the harness .env first (compose passes those as build args), then the ARG default
# in dev/Dockerfile — so the menu cannot drift from the image. Nothing found = no
# version shown, never a guess.
kit_pin() {   # <VAR>
  local v=""
  if [[ -f "$HARNESS_DIR/.env" ]]; then
    v="$(sed -nE "s/^[[:space:]]*(export[[:space:]]+)?$1=[\"']?([^\"'#[:space:]]+).*/\2/p" \
          "$HARNESS_DIR/.env" 2>/dev/null | tail -1)"
  fi
  if [[ -z "$v" && -f "$HARNESS_DIR/dev/Dockerfile" ]]; then
    v="$(sed -nE "s/^ARG[[:space:]]+$1=[\"']?([^\"'[:space:]]+).*/\1/p" \
          "$HARNESS_DIR/dev/Dockerfile" 2>/dev/null | head -1)"
  fi
  printf '%s' "$v"
}

# Node has no pin: dev/Dockerfile installs a NodeSource major (setup_<N>.x).
kit_node_major() {
  sed -nE 's/.*setup_([0-9]+)\.x.*/\1/p' "$HARNESS_DIR/dev/Dockerfile" 2>/dev/null | head -1
}

kit_comp_label() {   # <component>
  local v
  case "$1" in
    node)    v="$(kit_node_major)"; printf 'node%s' "${v:+ $v}" ;;
    java)    v="$(kit_pin JDK_VERSION)"; printf 'java%s' "${v:+ (JDK $v)}" ;;
    angular) v="$(kit_pin ANGULAR_VERSION)"; printf 'angular%s' "${v:+ (CLI $v)}" ;;
    dotnet)  v="$(kit_pin DOTNET_VERSION)"; printf 'dotnet%s' "${v:+ (SDK $v)}" ;;
    playwright) v="$(kit_pin PLAYWRIGHT_VERSION)"; printf 'playwright + chromium%s' "${v:+ ($v)}" ;;
    *)       printf '%s' "$1" ;;
  esac
}

kit_comps_label() {   # <component…> → "node 22, python, java (JDK 25)"
  local c out=""
  for c in "$@"; do out="${out:+$out, }$(kit_comp_label "$c")"; done
  printf '%s' "$out"
}
