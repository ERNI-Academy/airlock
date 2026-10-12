#!/usr/bin/env bash
#
# test-airlock-config.sh — offline tests for the `airlock` config path.
#
# No docker, no model, no network, and nothing outside a temp tree: a copy of
# bin/airlock is pointed at a fake HOME, a fake AIRLOCK_HOME and a fake
# bin/sandbox-run that only dumps the environment it was handed. What is under
# test is the security seam: a project file is never read as configuration and
# never executed, the control-dir config is parsed (not sourced) against the key
# allow list, and the mounts can only point where they are allowed to.
#
#   bin/test-airlock-config.sh            run them all
set -uo pipefail

HARNESS_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0

# Physical path: the control dir is keyed by the project's absolute path, and `cd`
# normalizes (TMPDIR often ends in a slash), so the temp root has to be normalized
# too or the test would compute a different control dir than airlock does.
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/airlock-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$T"' EXIT

# ── the fake harness ──────────────────────────────────────────────────────────
H="$T/harness"                      # the fake harness repo, kept out of the fake HOME
mkdir -p "$H/bin" "$H/dev" "$T/home"
cp "$HARNESS_SRC/bin/airlock" "$H/bin/airlock"
cp -R "$HARNESS_SRC/bin/lib" "$H/bin/lib"
# The kit config decides which stacks and harnesses exist at all, so the tests run
# against the one that ships. There is one parametrised dev/Dockerfile now; a second
# recipe in dev/ stays selectable by DEV_DOCKERFILE (the fake one below).
cp "$HARNESS_SRC/airlock.json" "$H/airlock.json"
for f in Dockerfile Dockerfile.alt; do : > "$H/dev/$f"; done
# The proxy side, copied from the real repo: squid.conf carries no domains at all,
# and the whitelist BLOCKS are what airlock composes a project's list from — so the
# tests assert against the same files that ship.
mkdir -p "$H/proxy"
cp "$HARNESS_SRC/proxy/squid.conf" "$H/proxy/squid.conf"
cp "$HARNESS_SRC/proxy/extra-whitelist.txt" "$H/proxy/extra-whitelist.txt"
cp -R "$HARNESS_SRC/proxy/whitelist.d" "$H/proxy/whitelist.d"
cat > "$H/bin/sandbox-run" <<'EOF'
#!/usr/bin/env bash
# Fake: record the environment airlock handed us, then exit.
env | sort > "$ENV_OUT"
echo "ARGS:$*" >> "$ENV_OUT"
EOF
chmod +x "$H/bin/sandbox-run"

# A fake `docker` (and `colima`) on PATH, FIRST: every launch verb now runs the
# image sweep (bin/lib/airlock-gc.sh), and the real daemon must never see a test —
# least of all a `docker rmi` decided against a temp AIRLOCK_HOME, under which every
# real sandbox image would look orphaned. The fake answers from files and logs every
# call; with the files empty, the sweep finds nothing.
FB="$T/gcbin"; mkdir -p "$FB"   # not fakebin: section 9 writes its own docker there
export DOCKER_LOG="$T/docker.log" FAKE_IMAGES="$T/fake-images" FAKE_DANGLING="$T/fake-dangling" \
       FAKE_INSPECT="$T/fake-inspect" FAKE_INUSE="$T/fake-inuse" FAKE_DF="$T/fake-df"
fake_docker_reset() {
  : > "$DOCKER_LOG"; : > "$FAKE_IMAGES"; : > "$FAKE_DANGLING"; : > "$FAKE_INSPECT"; : > "$FAKE_INUSE"; : > "$FAKE_DF"
}
fake_docker_reset
cat > "$FB/docker" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$DOCKER_LOG"
case "$1 $2" in
  "images -f")       cat "$FAKE_DANGLING" ;;
  "images --format") cat "$FAKE_IMAGES" ;;
  "image inspect")   cat "$FAKE_INSPECT" ;;
  "system df")       cat "$FAKE_DF" ;;
  "context show")    echo default ;;
  "ps -a")           a="$*"; id="${a##*ancestor=}"; grep -qx "$id" "$FAKE_INUSE" && echo "c0ffee$id" ;;
esac
exit 0
EOF
printf '#!/bin/sh\necho "colima $*" >> "$DOCKER_LOG"; exit 1\n' > "$FB/colima"
chmod +x "$FB/docker" "$FB/colima"
export PATH="$FB:$PATH"

export HOME="$T/home"
export AIRLOCK_HOME="$T/home/.airlock"
# No backends plugin unless a test points at its own fixture: the real
# plugin file of whoever runs this must not change what passes.
unset AIRLOCK_BACKENDS
export ENV_OUT="$T/env.out"
AIRLOCK="$H/bin/airlock"

ctl_for() {  # same recipe as bin/airlock / bin/harness
  local p="$1" slug hash
  slug="$(basename "$p" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/-*$//')"
  hash="$(printf '%s' "$p" | shasum | cut -c1-6)"
  printf '%s/%s-%s' "$AIRLOCK_HOME" "$slug" "$hash"
}

new_project() {  # <name> → echoes the project dir, with a .git so the guard passes
  local d="$T/$1"
  mkdir -p "$d"; : > "$d/.git"
  printf '%s' "$d"
}

# run <dir> <args…> → stdout+stderr in $OUT, status in $ST
run() {
  local d="$1"; shift
  : > "$ENV_OUT"
  OUT="$( cd "$d" && "$AIRLOCK" "$@" 2>&1 )"; ST=$?
}

ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1"; [[ -n "${2:-}" ]] && echo "$2" | sed 's/^/         /'; }
check(){ if [[ "$1" == 1 ]]; then ok "$2"; else bad "$2" "${3:-}"; fi }

has()   { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

echo "airlock config tests (temp tree: $T)"

# ── 1. a project .airlock is inert: not sourced, not read, not obeyed ─────────
echo "1. project .airlock is ignored and never executed"
P="$(new_project proj-inject)"
CTL="$(ctl_for "$P")"; mkdir -p "$CTL"
# A control-dir config with no STACK line: what is under test is that the stray
# file's values lose to the built-in defaults, not the no-config path (section 8).
printf 'HARNESS=opencode\n' > "$CTL/config"
cat > "$P/.airlock" <<'EOF'
STACK=$(touch /tmp/AIRLOCK_CANARY_SUB)
WHITELIST="evil.com"
CLAUDE_STATE=/etc
LLM_HOST=`touch CANARY_TICK`
EOF
printf '%s\n' '; touch CANARY_SEMI' >> "$P/.airlock"
run "$P" shell
check "$([[ $ST -eq 0 ]] && echo 1 || echo 0)" "launch still succeeds with a stray .airlock" "$OUT"
check "$(has "is NOT read" "$OUT" && echo 1 || echo 0)" "prints the one-line ignore notice" "$OUT"
canary=0
for c in CANARY_SEMI CANARY_TICK; do [[ -e "$P/$c" ]] && canary=1; done
[[ -e /tmp/AIRLOCK_CANARY_SUB ]] && canary=1
check "$([[ $canary -eq 0 ]] && echo 1 || echo 0)" "no CANARY anywhere (nothing was executed)"
envdump="$(cat "$ENV_OUT")"
check "$(grep -q '^evil.com$' "$CTL/whitelist.txt" && echo 0 || echo 1)" "its WHITELIST never reaches the composed list" "$(cat "$CTL/whitelist.txt" 2>/dev/null)"
check "$(has "CLAUDE_STATE=$CTL/state/unused/claude" "$envdump" && echo 1 || echo 0)" "its CLAUDE_STATE=/etc is not obeyed" "$envdump"
check "$(printf '%s\n' "$envdump" | grep -qx 'DEV_DOCKERFILE=Dockerfile' && has "AIRLOCK_WITH_JAVA=0" "$envdump" && has "AIRLOCK_WITH_PYTHON=1" "$envdump" && echo 1 || echo 0)" "defaults apply (STACK=base, the new default)" "$envdump"
check "$([[ ! -e "$P/.airlock-whitelist" ]] && echo 1 || echo 0)" "nothing whitelist-shaped is written into the project"

# ── 2. the control-dir config is honoured ────────────────────────────────────
echo "2. the control-dir config is honoured"
P="$(new_project proj-good)"
CTL="$(ctl_for "$P")"; mkdir -p "$CTL"
cat > "$CTL/config" <<'EOF'
# a comment
STACK=dotnet          # inline comment on a bare value
WHITELIST="artifactory.corp.com .pypi.internal"
export LOCAL_MODEL=off
ANTHROPIC_MODEL=
LLM_MODEL='quoted-model'
EOF
run "$P" shell
envdump="$(cat "$ENV_OUT")"
check "$([[ $ST -eq 0 ]] && echo 1 || echo 0)" "launch succeeds" "$OUT"
check "$(has "AIRLOCK_WITH_DOTNET=1" "$envdump" && has "AIRLOCK_WITH_PYTHON=0" "$envdump" && echo 1 || echo 0)" "STACK→build args reaches sandbox-run" "$envdump"
check "$(has "LOCAL_MODEL=off" "$envdump" && echo 1 || echo 0)" "export-prefixed key reaches sandbox-run"
check "$(has "LLM_MODEL=quoted-model" "$envdump" && echo 1 || echo 0)" "quoted value reaches sandbox-run"
check "$(has "EXTRA_WHITELIST=$CTL/whitelist.txt" "$envdump" && echo 1 || echo 0)" "EXTRA_WHITELIST points into the control dir" "$envdump"
check "$([[ -f "$CTL/whitelist.txt" && ! -e "$P/.airlock-whitelist" ]] && echo 1 || echo 0)" "whitelist lands in the control dir, not the project"
check "$(grep -q '^artifactory.corp.com$' "$CTL/whitelist.txt" && echo 1 || echo 0)" "whitelist content is the domain list"
check "$([[ -d "$CTL/state/claude" ]] && echo 1 || echo 0)" "state dirs live in the control dir"

# ── 3. bad configs are fatal ─────────────────────────────────────────────────
echo "3. the parser refuses what it cannot vouch for"
bad_cfg() {  # <label> <config line> <expected message fragment>
  local label="$1" line="$2" want="$3" p ctl
  p="$(new_project "proj-bad-$(printf '%s' "$label" | tr -c 'a-z0-9' '-')")"
  ctl="$(ctl_for "$p")"; mkdir -p "$ctl"
  printf '%s\n' "$line" > "$ctl/config"
  run "$p" shell
  if [[ $ST -ne 0 ]] && has "$want" "$OUT"; then ok "$label"; else bad "$label" "$OUT"; fi
  [[ -e "$p/CANARY" || -e "$T/CANARY" ]] && bad "$label: a CANARY appeared"
}
bad_cfg "command substitution"  'STACK=$(touch CANARY)'          "contains '\$'"
bad_cfg "backticks"             'STACK=`touch CANARY`'           "contains '\`'"
bad_cfg "command chaining"      'STACK=base; touch CANARY'       "contains ';'"
bad_cfg "backslash"             'ANTHROPIC_MODEL=a\b'            "contains '\\'"
bad_cfg "pipe"                  'ANTHROPIC_MODEL=a|b'            "contains '|'"
bad_cfg "double-quoted subst"   'WHITELIST="$(id)"'              "contains '\$'"
bad_cfg "unknown key"           'EXTRA_WHITELIST=/tmp/wl'        "is not an allowed config key"
bad_cfg "unknown key 2"         'COMPOSE_FILE=/tmp/x.yml'        "is not an allowed config key"
bad_cfg "not a KEY=VALUE line"  'rm -rf /'                       "not a KEY=VALUE line"
bad_cfg "unknown stack"         'STACK=hax'                      "is not a known stack"
bad_cfg "dockerfile escape"     'DEV_DOCKERFILE=../../etc/passwd' "must start with 'Dockerfile'"
bad_cfg "dockerfile missing"    'DEV_DOCKERFILE=Dockerfile.nope' "is not a file in"
bad_cfg "whitelist IP"          'WHITELIST=1.2.3.4'              "is not a plain domain"
bad_cfg "whitelist wildcard"    'WHITELIST=*.x.com'              "is not a plain domain"
bad_cfg "whitelist path"        'WHITELIST=a.com/path'           "is not a plain domain"
bad_cfg "whitelist injection"   'WHITELIST=evil.com;x'           "contains ';'"
bad_cfg "whitelist port"        'WHITELIST=a.com:3128'           "is not a plain domain"
bad_cfg "state relative"        'GH_STATE=relative/dir'          "must be an absolute path"
bad_cfg "state ~/.ssh"          'GH_STATE=~/.ssh'                "~/.ssh"
bad_cfg "state \$HOME"          "GH_STATE=$HOME"                 "your home directory"
bad_cfg "state harness repo"    "CODEX_STATE=$H/dev"             "inside the harness repo"
bad_cfg "numeric knob"          'GC_DAYS=six'                    "must be a whole number"

# ── 4. a symlinked state dir is refused ──────────────────────────────────────
echo "4. a symlinked mount source is refused"
P="$(new_project proj-symlink)"
CTL="$(ctl_for "$P")"; mkdir -p "$CTL"; printf 'STACK=base\n' > "$CTL/config"
run "$P" shell                       # first launch creates the state dirs
mkdir -p "$T/secret"
rm -rf "$CTL/state/gh"; ln -s "$T/secret" "$CTL/state/gh"
run "$P" shell
check "$([[ $ST -ne 0 ]] && has "is a symlink" "$OUT" && echo 1 || echo 0)" "GH_STATE symlink refused" "$OUT"

# ── 5. migration out of the project's .airlock-state/ ────────────────────────
echo "5. migration moves real dirs and never follows a symlink"
P="$(new_project proj-migrate)"
CTL="$(ctl_for "$P")"; mkdir -p "$CTL"; printf 'STACK=base\n' > "$CTL/config"
mkdir -p "$P/.airlock-state/claude" "$P/.airlock-state/codex" "$T/elsewhere"
echo token > "$P/.airlock-state/claude/creds.json"
ln -s "$T/elsewhere" "$P/.airlock-state/gh"
run "$P" shell
check "$([[ -f "$CTL/state/claude/creds.json" ]] && echo 1 || echo 0)" "real state dir moved into the control dir" "$OUT"
check "$([[ ! -e "$P/.airlock-state/claude" ]] && echo 1 || echo 0)" "old dir no longer in the project"
check "$([[ -L "$P/.airlock-state/gh" ]] && has "SKIPPED" "$OUT" && echo 1 || echo 0)" "symlinked state dir skipped, not followed" "$OUT"
check "$([[ ! -e "$T/elsewhere/config" && -d "$T/elsewhere" ]] && echo 1 || echo 0)" "the symlink target was not written into"
check "$(has "moved" "$OUT" && echo 1 || echo 0)" "says what it moved"

# ── 6. import ────────────────────────────────────────────────────────────────
echo "6. import is interactive-only and writes to the control dir"
P="$(new_project proj-import)"
CTL="$(ctl_for "$P")"
printf 'STACK=base\n' > "$P/.airlock"
run "$P" import < /dev/null
check "$([[ $ST -ne 0 ]] && has "refusing to import" "$OUT" && echo 1 || echo 0)" "refuses without a terminal" "$OUT"
check "$([[ ! -e "$CTL/config" ]] && echo 1 || echo 0)" "nothing was written"
printf 'OPENCODE_DIR=/etc\n' > "$P/.airlock"
run "$P" import < /dev/null
check "$([[ $ST -ne 0 ]] && has "not an allowed config key" "$OUT" && echo 1 || echo 0)" "validates before asking" "$OUT"

# ── 7. init / config ─────────────────────────────────────────────────────────
echo "7. init and config"
P="$(new_project proj-init)"
CTL="$(ctl_for "$P")"
run "$P" init --stack base
check "$([[ $ST -eq 0 && -f "$CTL/config" ]] && echo 1 || echo 0)" "init writes the config into the control dir" "$OUT"
check "$([[ ! -e "$P/.airlock" && ! -e "$P/.airlock-state" ]] && echo 1 || echo 0)" "init writes nothing into the project"
check "$(grep -q '^LOCAL_MODEL=off ' "$CTL/config" && echo 1 || echo 0)" "init off a terminal writes LOCAL_MODEL=off (no door until asked for)" "$(cat "$CTL/config")"
run "$P" config
check "$([[ $ST -eq 0 ]] && has "$CTL" "$OUT" && has "STACK=base" "$OUT" && echo 1 || echo 0)" "config prints the control dir and the settings" "$OUT"
run "$P" shell
envdump="$(cat "$ENV_OUT")"
check "$(has "DEV_DOCKERFILE=Dockerfile" "$envdump" && echo 1 || echo 0)" "the config init wrote is what launches" "$envdump"
run "$P" init
check "$([[ $ST -ne 0 ]] && has "already has a config" "$OUT" && echo 1 || echo 0)" "a second init refuses" "$OUT"
# init is fresh-only now: no --from, and no auto-detection of a legacy stub. A
# script in the project that happens to mention sandbox-run must not become config.
P="$(new_project proj-init-fresh)"
CTL="$(ctl_for "$P")"
printf '#!/bin/sh\nexport WHITELIST="evil.com"\nexec sandbox-run "$@"\n' > "$P/sandbox"
run "$P" init --from ./sandbox
check "$([[ $ST -ne 0 ]] && has "unknown arg" "$OUT" && echo 1 || echo 0)" "init --from is gone" "$OUT"
run "$P" init --stack base
check "$([[ $ST -eq 0 ]] && ! has "evil.com" "$(cat "$CTL/config")" && echo 1 || echo 0)" "init ignores a stub-shaped file in the project" "$OUT"

# ── 8. no config at all ──────────────────────────────────────────────────────
# A launch verb with no config used to build STACK=java-angular silently. Away from
# a terminal (this test's stderr is a pipe) it now refuses, naming the project and
# the init line; the lifecycle/introspection verbs keep a base fallback.
echo "8. a project with no config is refused off a terminal, never defaulted"
P="$(new_project proj-bare)"
CTL="$(ctl_for "$P")"
run "$P" shell
check "$([[ $ST -eq 1 ]] && has "no config for $P" "$OUT" && has "airlock init --stack <base|java-angular|dotnet|node>" "$OUT" && echo 1 || echo 0)" \
  "shell: exit 1, names the project dir and 'airlock init --stack <s>'" "$OUT"
check "$([[ ! -s "$ENV_OUT" && ! -e "$CTL/config" ]] && echo 1 || echo 0)" "…launches nothing and writes no config" "$(cat "$ENV_OUT")"
refused=""
for v in oc claude codex copilot "run ls" up; do
  run "$P" $v
  [[ $ST -eq 1 ]] && has "refusing to guess" "$OUT" || refused="$refused [$v: st=$ST]"
done
check "$([[ -z "$refused" ]] && echo 1 || echo 0)" "…and so does every other verb that builds or boots the sandbox" "$refused"
run "$P" down
check "$([[ $ST -eq 0 ]] && has "STACK=base" "$OUT" && echo 1 || echo 0)" "'down' still runs, on the base fallback" "$OUT"
run "$P" init
check "$([[ $ST -eq 0 ]] && grep -q '^STACK=base ' "$CTL/config" && grep -q '^HARNESS=opencode ' "$CTL/config" && echo 1 || echo 0)" \
  "'init' off a terminal writes the new default, STACK=base" "$(cat "$CTL/config" 2>/dev/null)"
check "$(grep -q '^# COMPONENTS=' "$CTL/config" && echo 1 || echo 0)" "…with COMPONENTS documented, commented out" "$(cat "$CTL/config")"
run "$P" shell
envdump="$(cat "$ENV_OUT")"
check "$([[ $ST -eq 0 ]] && has "AIRLOCK_WITH_JAVA=0" "$envdump" && has "AIRLOCK_WITH_ANGULAR=0" "$envdump" && echo 1 || echo 0)" \
  "…after which the launch goes through, with no JDK and no Angular" "$OUT"
P="$(new_project proj-node)"; CTL="$(ctl_for "$P")"
run "$P" init --stack node
run "$P" shell
envdump="$(cat "$ENV_OUT")"
check "$([[ $ST -eq 0 ]] && has "AIRLOCK_WITH_NODE=1" "$envdump" && has "AIRLOCK_WITH_PYTHON=0" "$envdump" && has "AIRLOCK_WITH_JAVA=0" "$envdump" && echo 1 || echo 0)" \
  "the node stack is node only" "$envdump"
check "$(has "via [stack-node harness-opencode]" "$OUT" && echo 1 || echo 0)" "…and opens only npm (+ its harness)" "$OUT"

# ── 9. one harness per project + the secrets file ────────────────────────────
echo "9. HARNESS, GH and the secrets file"
bad_cfg "unknown harness"       'HARNESS=aider'                  "opencode | claude | codex | copilot"
bad_cfg "gh not on/off"         'GH=yes'                         "must be on or off"

harness_project() {  # <name> <config lines…> → sets P/CTL, writes the config
  P="$(new_project "$1")"; shift
  CTL="$(ctl_for "$P")"; mkdir -p "$CTL"
  { echo "STACK=base"; printf '%s\n' "$@"; } > "$CTL/config"
}

# Default (no HARNESS line) = opencode: no harness state dir is mounted at all.
harness_project h-default
run "$P" shell
envdump="$(cat "$ENV_OUT")"
check "$(has "CLAUDE_STATE=$CTL/state/unused/claude" "$envdump" && has "CODEX_STATE=$CTL/state/unused/codex" "$envdump" && echo 1 || echo 0)" "default HARNESS=opencode mounts placeholders for the others" "$envdump"
check "$(has "GH_STATE=$CTL/state/unused/gh" "$envdump" && echo 1 || echo 0)" "GH is off by default" "$envdump"
check "$(has "harness=opencode" "$OUT" && has "gh: off" "$OUT" && echo 1 || echo 0)" "the launch line names the harness and gh" "$OUT"

harness_project h-claude 'HARNESS=claude' 'GH=on'
run "$P" shell
envdump="$(cat "$ENV_OUT")"
check "$(has "CLAUDE_STATE=$CTL/state/claude" "$envdump" && echo 1 || echo 0)" "HARNESS=claude mounts the real claude state" "$envdump"
check "$(has "CODEX_STATE=$CTL/state/unused/codex" "$envdump" && has "COPILOT_STATE=$CTL/state/unused/copilot" "$envdump" && echo 1 || echo 0)" "…and only that one" "$envdump"
check "$(has "GH_STATE=$CTL/state/gh" "$envdump" && echo 1 || echo 0)" "GH=on mounts the real gh state" "$envdump"
run "$P" oc
check "$([[ $ST -ne 0 ]] && has "configured for HARNESS=claude" "$OUT" && echo 1 || echo 0)" "the wrong harness verb is refused" "$OUT"
run "$P" claude
check "$([[ $ST -eq 0 ]] && echo 1 || echo 0)" "the right harness verb runs" "$OUT"
run "$P" shell
check "$([[ $ST -eq 0 ]] && echo 1 || echo 0)" "shell is unaffected by HARNESS" "$OUT"
run "$P" run ls
check "$([[ $ST -eq 0 ]] && echo 1 || echo 0)" "run is unaffected by HARNESS" "$OUT"
# GH=on plus a whitelist that reaches GitHub's API host = an upload path.
harness_project h-ghwarn 'HARNESS=claude' 'GH=on' 'WHITELIST=".github.com"'
run "$P" shell
check "$(has "upload path" "$OUT" && echo 1 || echo 0)" "warns when GH=on meets a .github.com whitelist" "$OUT"
harness_project h-nowarn 'HARNESS=claude' 'GH=on' 'WHITELIST="pypi.internal"'
run "$P" shell
check "$(has "upload path" "$OUT" && echo 0 || echo 1)" "…and stays quiet when it does not" "$OUT"

# The secrets file: its own allow list, its own mode, and only the selected
# harness's names carry a value.
P="$(new_project h-secrets)"; CTL="$(ctl_for "$P")"; mkdir -p "$CTL"
printf 'STACK=base\nHARNESS=claude\n' > "$CTL/config"
printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-TESTVALUE\nOPENROUTER_API_KEY=sk-or-TESTVALUE\n' > "$CTL/env"
chmod 644 "$CTL/env"
export OPENAI_API_KEY=ambient-key-from-the-users-shell
run "$P" shell
envdump="$(cat "$ENV_OUT")"
unset OPENAI_API_KEY
check "$(has "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-TESTVALUE" "$envdump" && echo 1 || echo 0)" "the harness's own credential is passed in" "$envdump"
check "$(has "OPENROUTER_API_KEY=" "$envdump" && has "sk-or-TESTVALUE" "$envdump" && echo 0 || echo 1)" "a credential for another harness is passed in EMPTY" "$envdump"
check "$(has "OPENAI_API_KEY=ambient" "$envdump" && echo 0 || echo 1)" "an ambient OPENAI_API_KEY is overridden to empty" "$envdump"
check "$([[ "$(stat -f '%Lp' "$CTL/env" 2>/dev/null || stat -c '%a' "$CTL/env")" == 600 ]] && echo 1 || echo 0)" "a loose-moded secrets file is tightened to 0600"
check "$(has "CLAUDE_CODE_OAUTH_TOKEN (project secrets)" "$OUT" && echo 1 || echo 0)" "the launch line names the credential" "$OUT"
check "$(has "sk-ant-oat-TESTVALUE" "$OUT" && echo 0 || echo 1)" "the launch line never prints a value" "$OUT"
run "$P" config
check "$(has "sk-ant-oat-TESTVALUE" "$OUT" && echo 0 || echo 1)" "'config' lists secret names, never values" "$OUT"
check "$(has "CLAUDE_CODE_OAUTH_TOKEN" "$OUT" && echo 1 || echo 0)" "…but does say which are set" "$OUT"
printf 'AWS_SECRET_ACCESS_KEY=x\n' > "$CTL/env"; chmod 600 "$CTL/env"
run "$P" shell
check "$([[ $ST -ne 0 ]] && has "is not a credential this sandbox passes in" "$OUT" && echo 1 || echo 0)" "a name off the credential list is refused" "$OUT"
printf 'CLAUDE_CODE_OAUTH_TOKEN=$(id)\n' > "$CTL/env"; chmod 600 "$CTL/env"
run "$P" shell
check "$([[ $ST -ne 0 ]] && has "contains '\$'" "$OUT" && echo 1 || echo 0)" "the secrets file gets the same metacharacter ban" "$OUT"
# import must never read or write the secrets file.
printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-KEEPME\n' > "$CTL/env"; chmod 600 "$CTL/env"
printf 'STACK=base\n' > "$P/.airlock"
run "$P" import < /dev/null
check "$([[ "$(cat "$CTL/env")" == "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-KEEPME" ]] && echo 1 || echo 0)" "import leaves the secrets file alone" "$OUT"

# ── 10. the generic `endpoint` backend ───────────────────────────────────────
# These need the REAL bin/sandbox-run (the picker renders the opencode config),
# so swap the fake one out for the rest of the file. No server is listening, so
# every launch ends at the health check — but the render happens before it, which
# is exactly the part worth asserting.
echo "10. LOCAL_MODEL=endpoint"
bad_cfg "endpoint port range"   'LLM_PORT=99999'                 "outside 1-65535"
bad_cfg "endpoint port words"   'LLM_PORT=eighty'                "must be a port number"
bad_cfg "endpoint host url"     'LLM_HOST=http:/example.com'     "is not a hostname or IP"
bad_cfg "endpoint key charset"  'LLM_KEY=abc def'                "characters an API key does not have"
bad_cfg "endpoint context"      'LLM_CONTEXT=lots'               "must be a number"
bad_cfg "endpoint unknown mode" 'LOCAL_MODEL=ollama'             "ask | endpoint | off"
bad_cfg "LOCAL_MODEL two words" 'LOCAL_MODEL="endpoint off"'     "ask | endpoint | off"
# The shipped pickers. The stub sandbox-run records the env, so no backend is
# health-checked or started.
for m in ask endpoint off; do
  P="$(new_project "proj-lm-$m")"
  CTL="$(ctl_for "$P")"; mkdir -p "$CTL"
  printf 'STACK=base\nHARNESS=opencode\nLOCAL_MODEL=%s\n' "$m" > "$CTL/config"
  run "$P" shell
  check "$([[ $ST -eq 0 ]] && grep -qx "LOCAL_MODEL=$m" "$ENV_OUT" && echo 1 || echo 0)" \
    "LOCAL_MODEL=$m is accepted and reaches sandbox-run" "$OUT"
done
# A plugin's picker is a valid value only while that plugin is loaded. The fixture
# plugin is a temp file; nothing in it runs anything.
PLUG="$T/backends-fixture.sh"
cat > "$PLUG" <<'EOF'
BACKENDS_EXTRA="fixture cold"
backend_fixture() { BK_PORT=18555; BK_MODEL=fixture-model; BK_LABEL="Fixture model"
  BK_HEALTH_URL="file://$FIXDIR/warm.json"; BK_CHECK_ID=1
  BK_STOP="rm -f $FIXDIR/warm.json"; BK_OPENCODE_DIR="$FIXDIR/oc-fixture"; }
backend_cold() { BK_PORT=18556; BK_MODEL=cold-model; BK_LABEL="Cold model"
  BK_HEALTH_URL="file://$FIXDIR/cold.json"
  BK_START="cp $FIXDIR/cold.src $FIXDIR/cold.json"; BK_STOP="rm -f $FIXDIR/cold.json"; BK_WAIT=5
  BK_OPENCODE_DIR="$FIXDIR/oc-cold"; BK_EXCLUSIVE_WITH="fixture"; }
EOF
export FIXDIR="$T/fix"; mkdir -p "$FIXDIR/oc-fixture" "$FIXDIR/oc-cold"
bad_cfg "plugin name without the plugin" 'LOCAL_MODEL=fixture'   "ask | endpoint | off"
P="$(new_project proj-lm-plugin)"; CTL="$(ctl_for "$P")"; mkdir -p "$CTL"
printf 'STACK=base\nHARNESS=opencode\nLOCAL_MODEL=fixture\n' > "$CTL/config"
AIRLOCK_BACKENDS="$PLUG" run "$P" shell
check "$([[ $ST -eq 0 ]] && grep -qx "LOCAL_MODEL=fixture" "$ENV_OUT" && echo 1 || echo 0)" \
  "LOCAL_MODEL=<plugin name> is accepted while AIRLOCK_BACKENDS points at the plugin" "$OUT"
printf 'STACK=base\nHARNESS=opencode\nLOCAL_MODEL=nosuch\n' > "$CTL/config"
AIRLOCK_BACKENDS="$PLUG" run "$P" shell
check "$([[ $ST -ne 0 ]] && has "ask | endpoint | off | fixture | cold" "$OUT" && echo 1 || echo 0)" \
  "…an unknown name is still refused, and the message lists the plugin's names" "$OUT"
# With AIRLOCK_BACKENDS unset, the default is backends.sh at the kit root — used only
# if it exists (the earlier unset-env cases ran with no such file).
printf 'STACK=base\nHARNESS=opencode\nLOCAL_MODEL=fixture\n' > "$CTL/config"
cp "$PLUG" "$H/backends.sh"
run "$P" shell
check "$([[ $ST -eq 0 ]] && grep -qx "LOCAL_MODEL=fixture" "$ENV_OUT" && echo 1 || echo 0)" \
  "…with AIRLOCK_BACKENDS unset, backends.sh at the kit root is the plugin" "$OUT"
rm -f "$H/backends.sh"
run "$P" shell
check "$([[ $ST -ne 0 ]] && echo 1 || echo 0)" \
  "…and with no backends.sh there, the plugin's name is refused again" "$OUT"
# The endpoint's key may live in the secrets file, and wins over the config's.
P="$(new_project proj-lm-seckey)"; CTL="$(ctl_for "$P")"; mkdir -p "$CTL"
printf 'STACK=base\nHARNESS=opencode\nLOCAL_MODEL=endpoint\nLLM_PORT=1\nLLM_MODEL=m\nLLM_KEY=from-config\n' > "$CTL/config"
( umask 077; printf 'LLM_KEY=sk-from-secrets\n' > "$CTL/env" )
run "$P" shell
check "$([[ $ST -eq 0 ]] && grep -qx "LLM_KEY=sk-from-secrets" "$ENV_OUT" && echo 1 || echo 0)" \
  "LLM_KEY in the secrets file reaches sandbox-run and wins over the config" "$OUT"
check "$(has "sk-from-secrets" "$OUT" && echo 0 || echo 1)" "…and its value is never printed" "$OUT"

cp "$HARNESS_SRC/bin/sandbox-run" "$H/bin/sandbox-run"
mkdir -p "$H/dev/opencode-endpoint"
cp "$HARNESS_SRC/dev/opencode-endpoint/opencode.json.tmpl" "$H/dev/opencode-endpoint/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$H/bin/harness"; chmod +x "$H/bin/harness"

endpoint_project() {  # <name> <extra config lines…> → sets P/CTL, runs `shell`
  P="$(new_project "$1")"; shift
  CTL="$(ctl_for "$P")"; mkdir -p "$CTL"
  { echo "STACK=base"; echo "LOCAL_MODEL=endpoint"; printf '%s\n' "$@"; } > "$CTL/config"
  run "$P" shell
}

endpoint_project ep-nokey 'LLM_PORT=1' 'LLM_MODEL=my-local-model' 'LLM_KEY='
J="$CTL/opencode-endpoint/opencode.json"
check "$([[ -f "$J" ]] && echo 1 || echo 0)" "renders opencode.json into the control dir" "$OUT"
check "$(python3 -m json.tool "$J" >/dev/null 2>&1 && echo 1 || echo 0)" "the rendered config is valid JSON" "$(cat "$J" 2>/dev/null)"
check "$(grep -q '"apiKey": "none"' "$J" && echo 1 || echo 0)" "an empty LLM_KEY becomes the placeholder" "$(cat "$J" 2>/dev/null)"
check "$(grep -q '"model": "endpoint/my-local-model"' "$J" && echo 1 || echo 0)" "the model id is wired into provider + default model"
check "$(grep -q '"auto": false' "$J" && echo 1 || echo 0)" "compaction matches the default config"
check "$([[ $ST -ne 0 ]] && has "no answer from" "$OUT" && echo 1 || echo 0)" "a dead endpoint fails with a clear message, not a hang" "$OUT"
check "$(has "auto-started" "$OUT" && echo 1 || echo 0)" "says nothing is auto-started for this backend" "$OUT"

endpoint_project ep-key 'LLM_PORT=11434' 'LLM_MODEL=llama3.1:8b' 'LLM_KEY=sk-local-1' 'LLM_CONTEXT=32768' 'LLM_OUTPUT=4096'
J="$CTL/opencode-endpoint/opencode.json"
check "$(python3 -m json.tool "$J" >/dev/null 2>&1 && echo 1 || echo 0)" "a colon in the model id still renders valid JSON" "$(cat "$J" 2>/dev/null)"
check "$(grep -q '"apiKey": "sk-local-1"' "$J" && echo 1 || echo 0)" "the configured key reaches opencode"
check "$(grep -q '"context": 32768' "$J" && grep -q '"output": 4096' "$J" && echo 1 || echo 0)" "the limits are the configured ones"
check "$([[ "$(stat -f '%Lp' "$J" 2>/dev/null || stat -c '%a' "$J")" == 600 ]] && echo 1 || echo 0)" "the rendered config (it holds the key) is 0600"

endpoint_project ep-missing 'LLM_PORT=11434'
check "$([[ $ST -ne 0 ]] && has "needs LLM_PORT and LLM_MODEL" "$OUT" && echo 1 || echo 0)" "endpoint without LLM_MODEL refuses" "$OUT"

# ── 11. the composed egress whitelist ────────────────────────────────────────
# squid.conf carries no domains; the list is built per project from the blocks in
# proxy/whitelist.d/ — the STACK's, the HARNESS's, the project's own — so what is
# under test is that a project gets ITS domains and nobody else's.
echo "11. the egress whitelist is composed per project"
# Back to the environment-dumping stand-in: section 10 swapped the REAL sandbox-run
# in, and that one picks a backend and health-checks a host LLM server. What is under
# test here happens entirely in airlock, before the exec — and a test suite has no
# business poking at whatever model the machine is serving.
cat > "$H/bin/sandbox-run" <<'EOF'
#!/usr/bin/env bash
env | sort > "$ENV_OUT"
echo "ARGS:$*" >> "$ENV_OUT"
EOF
chmod +x "$H/bin/sandbox-run"

wl_project() {  # <name> <config lines…> → sets P/CTL, launches, reads the list into $WL
  P="$(new_project "$1")"; shift
  CTL="$(ctl_for "$P")"; mkdir -p "$CTL"
  printf '%s\n' "$@" > "$CTL/config"
  run "$P" shell
  WL="$(grep -vE '^[[:space:]]*(#|$)' "$CTL/whitelist.txt" 2>/dev/null || true)"
}
wl_has()  { printf '%s\n' "$WL" | grep -Fqx "$1"; }

check "$(grep -Eq '^[[:space:]]*acl[[:space:]]+allowed[[:space:]]+dstdomain[[:space:]]+[^"]' "$HARNESS_SRC/proxy/squid.conf" && echo 0 || echo 1)" \
  "squid.conf declares no domain of its own" "$(grep -n 'dstdomain' "$HARNESS_SRC/proxy/squid.conf")"

wl_project wl-base 'STACK=base' 'HARNESS=opencode'
check "$(wl_has '.npmjs.org' && wl_has '.pypi.org' && wl_has '.pythonhosted.org' && wl_has '.models.dev' && echo 1 || echo 0)" \
  "STACK=base + HARNESS=opencode → node + python + models.dev" "$WL"
check "$(wl_has '.maven.org' || wl_has '.nuget.org' || wl_has '.anthropic.com' && echo 0 || echo 1)" \
  "…and nothing from the other stacks or harnesses" "$WL"
check "$(has "egress: 4 domain(s)" "$OUT" && has "stack-node stack-python harness-opencode" "$OUT" && echo 1 || echo 0)" \
  "the launch line names the count and the blocks" "$OUT"
check "$(has "EXTRA_WHITELIST=$CTL/whitelist.txt" "$(cat "$ENV_OUT")" && echo 1 || echo 0)" \
  "EXTRA_WHITELIST is exported even with no WHITELIST= set" "$(cat "$ENV_OUT")"

wl_project wl-java 'STACK=java-angular' 'HARNESS=claude'
check "$(wl_has '.maven.org' && wl_has 'repo.maven.apache.org' && wl_has '.adoptium.net' && wl_has '.gradle.org' && echo 1 || echo 0)" \
  "STACK=java-angular pulls in the Java block" "$WL"
check "$(wl_has '.anthropic.com' && wl_has '.claude.ai' && wl_has '.claude.com' && echo 1 || echo 0)" \
  "HARNESS=claude pulls in the Anthropic block" "$WL"
check "$(wl_has '.models.dev' && echo 0 || echo 1)" "…and NOT opencode's model catalog" "$WL"
check "$(wl_has 'github.com' && wl_has 'codeload.github.com' && echo 1 || echo 0)" \
  "the exact GitHub download hosts survive (Gradle wrapper)" "$WL"
check "$(wl_has '.github.com' && echo 0 || echo 1)" "…while .github.com (the API host) stays shut" "$WL"

wl_project wl-dotnet 'STACK=dotnet' 'HARNESS=codex'
check "$(wl_has '.nuget.org' && wl_has '.npmjs.org' && wl_has '.openai.com' && wl_has '.chatgpt.com' && echo 1 || echo 0)" \
  "STACK=dotnet + HARNESS=codex → nuget + node + OpenAI" "$WL"
check "$(wl_has '.pypi.org' && echo 0 || echo 1)" "…and no PyPI" "$WL"

# Overlap is normal (stack-java and harness-copilot both list .githubusercontent.com,
# and .github.com covers the exact hosts): squid refuses duplicates and warns on
# covered entries, so the composer has to reduce them away.
wl_project wl-dedup 'STACK=java-angular' 'HARNESS=copilot'
dupes="$(printf '%s\n' "$WL" | sort | uniq -d)"
check "$([[ -z "$dupes" ]] && echo 1 || echo 0)" "no duplicate entry survives" "$dupes"
check "$(wl_has '.github.com' && ! wl_has 'github.com' && ! wl_has 'codeload.github.com' && echo 1 || echo 0)" \
  "an entry a broader .domain already covers is dropped" "$WL"
check "$(printf '%s\n' "$WL" | grep -c '\.githubusercontent\.com' | tr -d ' ' | grep -qx 1 && echo 1 || echo 0)" \
  "a domain listed by two blocks appears once" "$WL"

wl_project wl-extra 'STACK=base' 'HARNESS=opencode' 'WHITELIST="artifactory.corp.com .pypi.internal"'
check "$(wl_has 'artifactory.corp.com' && wl_has '.pypi.internal' && echo 1 || echo 0)" \
  "the project's own WHITELIST= is appended" "$WL"
check "$(has "harness-opencode project" "$OUT" && echo 1 || echo 0)" "…and shows up as a block on the launch line" "$OUT"

# A changed list has to reach a running squid; an unchanged one must not churn it.
wl_project wl-reload 'STACK=base' 'HARNESS=opencode'
check "$(has "AIRLOCK_PROXY_RELOAD=1" "$(cat "$ENV_OUT")" && echo 1 || echo 0)" \
  "a first launch asks for a proxy reload" "$(cat "$ENV_OUT")"
cp "$CTL/whitelist.txt" "$CTL/whitelist.applied"     # pretend the proxy loaded it
run "$P" shell
check "$(has "AIRLOCK_PROXY_RELOAD" "$(cat "$ENV_OUT")" && echo 0 || echo 1)" \
  "an unchanged list does not ask again" "$(cat "$ENV_OUT")"
printf 'STACK=base\nHARNESS=opencode\nWHITELIST="new.example.com"\n' > "$CTL/config"
run "$P" shell
check "$(has "AIRLOCK_PROXY_RELOAD=1" "$(cat "$ENV_OUT")" && echo 1 || echo 0)" \
  "a changed list asks again" "$(cat "$ENV_OUT")"

# ── 12. one LLM door, and none when not needed ───────────────────────────────
# The door is one compose service forwarding to ONE host port, profile-gated so it
# can be absent. Nothing here may touch a real backend: `off` is the only picker
# value whose path starts no server, so the end-to-end assertion uses that one and
# the port map is read off the source.
echo "12. the LLM door"
cp "$HARNESS_SRC/bin/sandbox-run" "$H/bin/sandbox-run"

P="$(new_project llm-off)"; CTL="$(ctl_for "$P")"; mkdir -p "$CTL"
printf 'STACK=base\nHARNESS=opencode\nLOCAL_MODEL=off\n' > "$CTL/config"
: > "$ENV_OUT"
cat > "$H/bin/harness" <<'EOF'
#!/usr/bin/env bash
env | sort > "$ENV_OUT"
echo "ARGS:$*" >> "$ENV_OUT"
EOF
chmod +x "$H/bin/harness"
OUT="$( cd "$P" && "$AIRLOCK" shell 2>&1 )"; ST=$?
envdump="$(cat "$ENV_OUT")"
check "$(has "LLM_DOOR=0" "$envdump" && echo 1 || echo 0)" "LOCAL_MODEL=off disables the door" "$envdump"
check "$(has "LLM_TARGET_PORT" "$envdump" && echo 0 || echo 1)" "…and names no host port at all" "$envdump"
check "$(has "no host port reachable" "$OUT" && echo 1 || echo 0)" "…and says so" "$OUT"

# The plugin picker, driven for real against the fixture plugin from section 10:
# its "servers" are files (curl reads file:// URLs), so nothing listens and
# nothing real starts or stops.
plug_run() {  # <LOCAL_MODEL> <verb> → $OUT/$ST, env in $ENV_OUT
  P="$(new_project "plug-$1-$2")"; CTL="$(ctl_for "$P")"; mkdir -p "$CTL"
  printf 'STACK=base\nHARNESS=opencode\nLOCAL_MODEL=%s\n' "$1" > "$CTL/config"
  : > "$ENV_OUT"
  OUT="$( cd "$P" && AIRLOCK_BACKENDS="$PLUG" OPENCODE_AUTOUPDATE=0 CLAUDE_CODE_AUTOUPDATE=0 "$AIRLOCK" "$2" </dev/null 2>&1 )"; ST=$?
}
printf '{"data":[{"id":"fixture-model"}]}' > "$FIXDIR/warm.json"
printf '{"data":[{"id":"cold-model"}]}' > "$FIXDIR/cold.src"; rm -f "$FIXDIR/cold.json"
plug_run fixture shell
envdump="$(cat "$ENV_OUT")"
check "$([[ $ST -eq 0 ]] && has "LLM_TARGET_PORT=18555" "$envdump" && has "LLM_MODEL=fixture-model" "$envdump" \
        && has "OPENCODE_DIR=$FIXDIR/oc-fixture" "$envdump" && has "fixture-model" "$(grep '^LLM_MODEL=' "$ENV_OUT")" \
        && has "Fixture model: up." "$OUT" && ! has "starting via" "$OUT" && echo 1 || echo 0)" \
  "a plugin picker sets the door port, the model and its opencode dir (already up → not started)" "$OUT
$envdump"
check "$(has "LLM_DOOR=0" "$envdump" && echo 0 || echo 1)" "…and opens the door" "$envdump"
plug_run cold shell
envdump="$(cat "$ENV_OUT")"
check "$([[ $ST -eq 0 ]] && has "starting via: cp" "$OUT" && [[ -f "$FIXDIR/cold.json" ]] && has "LLM_TARGET_PORT=18556" "$envdump" && echo 1 || echo 0)" \
  "a plugin backend that is down is started and waited for" "$OUT"
check "$(has "cold exclusive: stopping fixture" "$OUT" && [[ ! -f "$FIXDIR/warm.json" ]] && echo 1 || echo 0)" \
  "…after stopping the backend it is exclusive with" "$OUT"
printf '{"data":[{"id":"fixture-model"}]}' > "$FIXDIR/warm.json"; rm -f "$FIXDIR/cold.json"
plug_run ask shell
check "$([[ $ST -eq 0 ]] && has "with no terminal — using 'fixture'" "$OUT" && grep -qx "LLM_TARGET_PORT=18555" "$ENV_OUT" && echo 1 || echo 0)" \
  "ask with no terminal uses a plugin backend that is already serving" "$OUT"
rm -f "$FIXDIR/warm.json"
plug_run ask shell
check "$([[ $ST -eq 0 ]] && has "using 'off'" "$OUT" && grep -qx "LLM_DOOR=0" "$ENV_OUT" && echo 1 || echo 0)" \
  "…and with nothing serving, no default and no endpoint: off" "$OUT"
printf '{"data":[{"id":"fixture-model"}]}' > "$FIXDIR/warm.json"
plug_run fixture stop
check "$([[ $ST -eq 0 && ! -f "$FIXDIR/warm.json" ]] && has "fixture: stopping via" "$OUT" && echo 1 || echo 0)" \
  "stop stops the plugin backends that are running" "$OUT"
P="$(new_project plug-noplugin)"; CTL="$(ctl_for "$P")"; mkdir -p "$CTL"
printf 'STACK=base\nHARNESS=opencode\nLOCAL_MODEL=ask\n' > "$CTL/config"
OUT="$( cd "$P" && "$AIRLOCK" deps 2>&1 )"
OUT2="$( cd "$P" && AIRLOCK_BACKENDS="$PLUG" "$AIRLOCK" deps 2>&1 )"
check "$(has "no backends plugin" "$OUT" && ! has "fixture" "$OUT" && has "fixture          Fixture model (:18555)" "$OUT2" && echo 1 || echo 0)" \
  "deps lists endpoint/off, plus the plugin's pickers only when it is loaded" "$OUT
$OUT2"
pm="$(sed -n '/^apply_local_model/,/^}/p' "$HARNESS_SRC/bin/sandbox-run")"
check "$(has 'export LLM_TARGET_PORT="$LLM_PORT"' "$pm" && echo 1 || echo 0)" "endpoint → LLM_PORT" "$pm"
check "$(has 'export LLM_DOOR=0' "$pm" && echo 1 || echo 0)" "off → no door" "$pm"

# bin/harness turns LLM_DOOR into the compose profile. Driven against a fake `docker`
# that only records what it was asked to do.
mkdir -p "$T/fakebin"
cat > "$T/fakebin/docker" <<'EOF'
#!/usr/bin/env bash
{ echo "PROFILES=${COMPOSE_PROFILES:-} ARGS:$*"; } >> "$DOCKER_LOG"
exit 0
EOF
chmod +x "$T/fakebin/docker"
export DOCKER_LOG="$T/docker.log"
harness_run() {  # <LLM_DOOR value> <args…> → the fake docker's log in $DLOG
  : > "$DOCKER_LOG"
  local door="$1"; shift
  ( export LLM_DOOR="$door" PATH="$T/fakebin:$PATH"
    bash "$HARNESS_SRC/bin/harness" "$@" >/dev/null 2>&1 ) || true
  DLOG="$(cat "$DOCKER_LOG")"
}
harness_run 1 up "$P"
check "$(has "PROFILES=llm ARGS:compose" "$DLOG" && echo 1 || echo 0)" "a raw harness caller gets the door by default" "$DLOG"
harness_run 0 up "$P"
check "$(has "rm -sf llm" "$DLOG" && echo 1 || echo 0)" "LLM_DOOR=0 removes a door left from an earlier launch" "$DLOG"
check "$(printf '%s\n' "$DLOG" | grep -v 'rm -sf llm' | grep -q 'PROFILES=llm ' && echo 0 || echo 1)" \
  "…and brings the stack up without the llm profile" "$DLOG"
harness_run 1 down "$P"
check "$(has "PROFILES=llm ARGS:compose" "$DLOG" && has " down" "$DLOG" && echo 1 || echo 0)" \
  "down takes the profile-gated door with it" "$DLOG"

# The compose file itself: one service, one target, three names.
py="$(python3 - "$HARNESS_SRC/docker-compose.yml" <<'PYEOF'
import re, sys
s = open(sys.argv[1]).read()
svc = re.findall(r'^  (llm\d*):', s, re.M)
tgt = set(re.findall(r'TCP:\$\{LLM_HOST[^}]*\}:(\$\{[A-Z_]+[^}]*\})', s))
lis = re.findall(r'TCP-LISTEN:(\d+)', s)
print("services=%s targets=%d listeners=%s aliases=%s" % (
    ",".join(svc), len(tgt), ",".join(sorted(lis)),
    "yes" if "aliases: [llm2, llm3]" in s else "no"))
PYEOF
)"
check "$(has "services=llm " "$py" && echo 1 || echo 0)" "compose declares exactly one llm service" "$py"
check "$(has "targets=1" "$py" && echo 1 || echo 0)" "…forwarding to exactly one host port" "$py"
check "$(has "listeners=8000,8080,8090" "$py" && echo 1 || echo 0)" "…listening on all three door ports (8080, 8000, 8090)" "$py"
check "$(has "aliases=yes" "$py" && echo 1 || echo 0)" "…under the llm2/llm3 aliases" "$py"
check "$(grep -q 'depends_on: \[proxy\]' "$HARNESS_SRC/docker-compose.yml" && echo 1 || echo 0)" \
  "dev does not hard-depend on the door" "$(grep -n depends_on "$HARNESS_SRC/docker-compose.yml")"

# ── 13. no opencode provider config for a non-opencode harness ───────────────
# compose mounts /etc/opencode unconditionally; the question is what lands there.
# A provider config names a base URL, a model and an API key — nothing a Claude Code
# or Codex project can use, so it gets an empty directory instead.
echo "13. /etc/opencode for a harness that is not opencode"
cat > "$H/bin/sandbox-run" <<'EOF'
#!/usr/bin/env bash
env | sort > "$ENV_OUT"
echo "ARGS:$*" >> "$ENV_OUT"
EOF
chmod +x "$H/bin/sandbox-run"

P="$(new_project oc-claude)"; CTL="$(ctl_for "$P")"; mkdir -p "$CTL"
printf 'STACK=base\nHARNESS=claude\nLOCAL_MODEL=off\n' > "$CTL/config"
run "$P" claude
envdump="$(cat "$ENV_OUT")"
check "$(has "OPENCODE_DIR=$CTL/opencode-none" "$envdump" && echo 1 || echo 0)" \
  "HARNESS=claude gets a placeholder, not the provider config" "$envdump"
check "$([[ -d "$CTL/opencode-none" && -z "$(ls -A "$CTL/opencode-none")" ]] && echo 1 || echo 0)" \
  "…and the placeholder is an empty directory"

# An opencode project is untouched: the picker in sandbox-run still chooses the dir.
P="$(new_project oc-opencode)"; CTL="$(ctl_for "$P")"; mkdir -p "$CTL"
printf 'STACK=base\nHARNESS=opencode\nLOCAL_MODEL=off\n' > "$CTL/config"
run "$P" oc
envdump="$(cat "$ENV_OUT")"
check "$(has "OPENCODE_DIR_PINNED" "$envdump" && echo 0 || echo 1)" \
  "HARNESS=opencode pins nothing" "$envdump"
check "$([[ ! -e "$CTL/opencode-none" ]] && echo 1 || echo 0)" "…and no placeholder is created"

# The picker must honour the pin rather than exporting a real config over it.
pk="$(sed -n '/^apply_local_model/,/^}/p' "$HARNESS_SRC/bin/sandbox-run")"
check "$(has 'oc_dir "$BK_OPENCODE_DIR"' "$pk" && ! has 'export OPENCODE_DIR' "$pk" && echo 1 || echo 0)" \
  "the picker sets OPENCODE_DIR through the pin-aware helper" "$pk"
check "$(has 'OPENCODE_DIR_PINNED" == "1" ]] || oc_dir "$(render_endpoint_config)' "$pk" && echo 1 || echo 0)" \
  "…and skips rendering the endpoint config (it holds a key) when pinned" "$pk"

# ── 14. `verify` asserts the configuration, not only the boundary ────────────
# The real bin/sandbox-run verify path, driven against a FAKE bin/harness: every
# probe it runs is an exec into the sandbox, so a stub that answers those execs
# exercises the whole assertion logic with no docker and no container. What is under
# test is the judgement — which domains count as another harness's, which credentials
# are out of place — not docker's behaviour.
echo "14. verify's configuration assertions"
cp "$HARNESS_SRC/bin/sandbox-run" "$H/bin/sandbox-run"
export FAKE_OK="$T/fake-ok"          # probe scripts the fake sandbox should ANSWER YES to
export FAKE_TARGETS="$T/fake-targets"
cat > "$H/bin/harness" <<'EOF'
#!/usr/bin/env bash
# Fake sandbox: answers `verify`'s probes from two files, so the assertions above
# them can be tested without docker.
cmd="$1"; shift
case "$cmd" in
  up|down) exit 0 ;;
  config)  cat "$FAKE_TARGETS"; exit 0 ;;
  run)     shift; shift; shift            # <dir> bash -lc
           script="${1:-}"
           case "$script" in
             *mountinfo*) echo "1 1 0:1 / /workspace rw,x - t t rw"; exit 0 ;;
           esac
           grep -Fqx -- "$script" "$FAKE_OK" && exit 0
           exit 1 ;;
esac
exit 1
EOF
chmod +x "$H/bin/harness"
printf 'command: socat TCP-LISTEN:8080 TCP:host.docker.internal:8000\n' > "$FAKE_TARGETS"
: > "$FAKE_OK"

verify_run() {  # <config lines…> → verify's output in $OUT
  P="$(new_project "verify-$1")"; shift
  CTL="$(ctl_for "$P")"; mkdir -p "$CTL"
  printf '%s\n' "$@" > "$CTL/config"
  OUT="$( cd "$P" && "$AIRLOCK" verify 2>&1 )"; ST=$?
}
v_line() { printf '%s\n' "$OUT" | grep -F "$1"; }

# Clean posture: a claude project whose whitelist carries only its own blocks.
verify_run clean 'STACK=base' 'HARNESS=claude' 'LOCAL_MODEL=off'
check "$(v_line "PASS  the whitelist carries no other harness's vendor domains" >/dev/null && echo 1 || echo 0)" \
  "a matching whitelist passes" "$OUT"
check "$(v_line "PASS  no credential for an unselected harness is set inside" >/dev/null && echo 1 || echo 0)" \
  "no stray credential passes" "$OUT"
check "$(v_line "PASS  no gh login is mounted while GH=off" >/dev/null && echo 1 || echo 0)" \
  "no gh login passes" "$OUT"
check "$(has "the effective egress whitelist" "$OUT" && has ".anthropic.com" "$OUT" && echo 1 || echo 0)" \
  "the effective whitelist is printed" "$OUT"
check "$(v_line "PASS  with no backend selected, llm does not resolve" >/dev/null && echo 1 || echo 0)" \
  "LOCAL_MODEL=off is verified as no door at all" "$OUT"
check "$(v_line "PASS  the LLM door forwards to exactly one host port" >/dev/null && echo 1 || echo 0)" \
  "one door target passes" "$OUT"

# Two targets in the rendered stack = two host ports reachable = a FAIL.
printf 'command: socat TCP:host.docker.internal:8000 TCP:host.docker.internal:8090\n' > "$FAKE_TARGETS"
verify_run twodoors 'STACK=base' 'HARNESS=claude' 'LOCAL_MODEL=off'
check "$([[ $ST -ne 0 ]] && v_line "FAIL  the LLM door forwards to exactly one host port" >/dev/null && echo 1 || echo 0)" \
  "two door targets FAIL" "$OUT"
printf 'command: socat TCP-LISTEN:8080 TCP:host.docker.internal:8000\n' > "$FAKE_TARGETS"

# Blocks overlap on purpose: stack-java and harness-copilot both list
# .githubusercontent.com. A java project on Claude Code must not be accused of
# carrying copilot's domains because of it.
verify_run overlap 'STACK=java-angular' 'HARNESS=claude' 'LOCAL_MODEL=off'
check "$(has ".githubusercontent.com" "$OUT" && v_line "PASS  the whitelist carries no other harness's vendor domains" >/dev/null && echo 1 || echo 0)" \
  "a domain the project's own stack block contributes is not a stray" "$OUT"

# A list the project's blocks did NOT compose — here a hand-made one with opencode's
# block in it — carries .models.dev, which belongs to a harness this project does not run.
P="$(new_project verify-stray)"
cat "$H/proxy/extra-whitelist.txt" "$H/proxy/whitelist.d/harness-opencode.txt" > "$T/stray-whitelist.txt"
OUT="$( cd "$P" && env PROJECT="$P" LOCAL_MODEL=off \
          AIRLOCK_HARNESS=claude AIRLOCK_GH=off AIRLOCK_WHITELIST="" \
          AIRLOCK_WL_BLOCKS="stack-node stack-python harness-claude" \
          EXTRA_WHITELIST="$T/stray-whitelist.txt" \
          "$H/bin/sandbox-run" verify 2>&1 )"; ST=$?
check "$([[ $ST -ne 0 ]] && v_line "FAIL  the whitelist carries no other harness's vendor domains" >/dev/null && echo 1 || echo 0)" \
  "a domain from another harness's block FAILs" "$OUT"
check "$(has ".models.dev(harness-opencode)" "$OUT" && echo 1 || echo 0)" "…naming it and the block it came from" "$OUT"

# …and a WARN when the project asked for it explicitly.
verify_run stray-ok 'STACK=base' 'HARNESS=claude' 'LOCAL_MODEL=off' 'WHITELIST=".models.dev"'
check "$(has "WARN  another harness's domain is open" "$OUT" && has ".models.dev" "$OUT" && echo 1 || echo 0)" \
  "…but only WARNs when the project's own WHITELIST asked for it" "$OUT"
check "$(v_line "FAIL  the whitelist carries no other harness's vendor domains" >/dev/null && echo 0 || echo 1)" \
  "…and does not FAIL on it" "$OUT"

# A credential the selected harness cannot use, non-empty inside.
printf 'test -n "$OPENROUTER_API_KEY"\n' > "$FAKE_OK"
verify_run cred 'STACK=base' 'HARNESS=claude' 'LOCAL_MODEL=off'
check "$([[ $ST -ne 0 ]] && v_line "FAIL  no credential for an unselected harness is set inside" >/dev/null && echo 1 || echo 0)" \
  "a credential for an unselected harness FAILs" "$OUT"
check "$(has "OPENROUTER_API_KEY" "$OUT" && echo 1 || echo 0)" "…naming it" "$OUT"

# A gh login present while GH=off.
printf 'test -s /home/dev/.config/gh/hosts.yml\n' > "$FAKE_OK"
verify_run gh 'STACK=base' 'HARNESS=claude' 'LOCAL_MODEL=off'
check "$([[ $ST -ne 0 ]] && v_line "FAIL  no gh login is mounted while GH=off" >/dev/null && echo 1 || echo 0)" \
  "a gh login while GH=off FAILs" "$OUT"
verify_run gh-on 'STACK=base' 'HARNESS=claude' 'GH=on' 'LOCAL_MODEL=off'
check "$(v_line "SKIP  no gh login is mounted while GH=off" >/dev/null && echo 1 || echo 0)" \
  "…and is skipped when the project asked for GH=on" "$OUT"
: > "$FAKE_OK"

# ── 15. the OpenAI-compatible env only reaches a harness that uses it ────────
# OPENAI_BASE_URL/OPENAI_API_KEY describe the local backend; Claude Code and the
# Copilot CLI read neither, and the key is a credential (0014). The backend must
# still be started/health-checked and the door still opened — only the env stays
# out. Driven through the `endpoint` backend, the one the picker never starts or
# stops, with a stand-in `curl` on PATH answering its health check: no host LLM
# server is touched and nothing listens on a port.
echo "15. the OpenAI-compatible env per harness"
cp "$HARNESS_SRC/bin/sandbox-run" "$H/bin/sandbox-run"
export OPENCODE_AUTOUPDATE=0 CLAUDE_CODE_AUTOUPDATE=0   # no npm registry lookups
cat > "$H/bin/harness" <<'EOF'
#!/usr/bin/env bash
env | sort > "$ENV_OUT"
echo "ARGS:$*" >> "$ENV_OUT"
EOF
chmod +x "$H/bin/harness"

EP_PORT=11434
mkdir -p "$T/fakebin"
cat > "$T/fakebin/curl" <<'EOF'
#!/usr/bin/env bash
# Stand-in for the endpoint health check: answers GET /v1/models, refuses the rest.
for a in "$@"; do
  case "$a" in */v1/models) printf '{"data": [{"id": "test-model"}]}\n'; exit 0 ;; esac
done
exit 7
EOF
chmod +x "$T/fakebin/curl"
PATH_SAVED="$PATH"; export PATH="$T/fakebin:$PATH"

ep_harness() {  # <name> <HARNESS> [verb…] → launches against the stand-in endpoint
  local name="$1" h="$2"; shift 2
  P="$(new_project "$name")"; CTL="$(ctl_for "$P")"; mkdir -p "$CTL"
  { echo "STACK=base"; echo "HARNESS=$h"; echo "LOCAL_MODEL=endpoint"
    echo "LLM_PORT=$EP_PORT"; echo "LLM_MODEL=test-model"; } > "$CTL/config"
  run "$P" "${@:-shell}"
  envdump="$(cat "$ENV_OUT")"
}

ep_harness f1-opencode opencode
check "$(has "OPENAI_BASE_URL=http://llm:8080/v1" "$envdump" && echo 1 || echo 0)" \
  "HARNESS=opencode gets the endpoint URL" "$OUT"
check "$(has "OPENAI_API_KEY=none" "$envdump" && echo 1 || echo 0)" "…and the key" "$envdump"

ep_harness f1-codex codex
check "$(has "OPENAI_BASE_URL=http://llm:8080/v1" "$envdump" && echo 1 || echo 0)" \
  "HARNESS=codex gets it too" "$OUT"

ep_harness f1-claude claude
check "$(printf '%s\n' "$envdump" | grep -q '^OPENAI_BASE_URL=' && echo 0 || echo 1)" \
  "HARNESS=claude gets no OPENAI_BASE_URL" "$envdump"
check "$(printf '%s\n' "$envdump" | grep -qx 'OPENAI_API_KEY=' && echo 1 || echo 0)" \
  "…and OPENAI_API_KEY stays empty (nothing for verify to flag)" "$envdump"
check "$(has "does not use an OpenAI-compatible endpoint" "$OUT" && echo 1 || echo 0)" \
  "…and one line says so" "$OUT"
check "$(has "endpoint: checking" "$OUT" && has "LLM_TARGET_PORT=$EP_PORT" "$envdump" && echo 1 || echo 0)" \
  "…while the backend is still health-checked and the door still opened" "$OUT"

ep_harness f1-copilot copilot
check "$(printf '%s\n' "$envdump" | grep -q '^OPENAI_BASE_URL=' && echo 0 || echo 1)" \
  "HARNESS=copilot gets none either" "$envdump"

export PATH="$PATH_SAVED"

# ── 16. the kit config: airlock.json ─────────────────────────────────────────
# It decides what gets BUILT into the sandbox image (harness CLIs, components,
# which STACK names exist) and, through the components, which egress blocks a
# stack gets. It is validated strictly: it is the file that says what is installed.
echo "16. the kit config (airlock.json)"
cat > "$H/bin/sandbox-run" <<'EOF'
#!/usr/bin/env bash
env | sort > "$ENV_OUT"
echo "ARGS:$*" >> "$ENV_OUT"
EOF
chmod +x "$H/bin/sandbox-run"

KIT="$H/airlock.json"
kit_write() {  # <name> <json> → AIRLOCK_KIT_CONFIG for the next kit_run
  printf '%s\n' "$2" > "$T/$1.json"; KIT="$T/$1.json"
}
kit_run() {    # <name> <config lines…> → $OUT/$ST/$envdump/$WL
  P="$(new_project "$1")"; CTL="$(ctl_for "$P")"; mkdir -p "$CTL"; shift
  printf '%s\n' "$@" > "$CTL/config"
  : > "$ENV_OUT"
  OUT="$( cd "$P" && AIRLOCK_KIT_CONFIG="$KIT" "$AIRLOCK" shell 2>&1 )"; ST=$?
  envdump="$(cat "$ENV_OUT")"
  WL="$(grep -vE '^[[:space:]]*(#|$)' "$CTL/whitelist.txt" 2>/dev/null || true)"
}

# The tracked default: four harnesses on offer, Playwright off unless the project asks.
kit_run kit-default 'STACK=base' 'HARNESS=opencode'
check "$(printf '%s\n' "$envdump" | grep -qx 'AIRLOCK_HARNESSES=opencode' && echo 1 || echo 0)" \
  "the shipped airlock.json offers four harnesses, but only the project's is built" "$envdump"
check "$(has "AIRLOCK_WITH_PLAYWRIGHT=0" "$envdump" && has "AIRLOCK_WITH_NODE=1" "$envdump" \
        && has "AIRLOCK_WITH_PYTHON=1" "$envdump" && has "AIRLOCK_WITH_JAVA=0" "$envdump" && echo 1 || echo 0)" \
  "…and STACK=base is node+python, no Playwright (default off)" "$envdump"

# A trimmed kit, reached through the override the tests and the docs both use.
kit_write kit-trim '{"harnesses": ["opencode"],
  "stacks": {"base": {"node": true, "python": true}}}'
kit_run kit-trimmed 'STACK=base' 'HARNESS=opencode'
check "$([[ $ST -eq 0 ]] && has "AIRLOCK_HARNESSES=opencode" "$envdump" \
        && ! has "AIRLOCK_HARNESSES=opencode claude" "$envdump" && echo 1 || echo 0)" \
  "AIRLOCK_KIT_CONFIG picks a different kit, and it trims the harness list" "$envdump"
kit_run kit-trimmed-harness 'STACK=base' 'HARNESS=claude'
check "$([[ $ST -ne 0 ]] && has "airlock.json" "$OUT" && echo 1 || echo 0)" \
  "a HARNESS the kit does not build is refused, naming airlock.json" "$OUT"
kit_run kit-trimmed-stack 'STACK=java-angular' 'HARNESS=opencode'
check "$([[ $ST -ne 0 ]] && has "is not a known stack" "$OUT" && echo 1 || echo 0)" \
  "…and so is a STACK it does not define" "$OUT"

# A stack the kit invents: its components decide both the build args and the blocks.
kit_write kit-custom '{"stacks": {"svc": {"node": true, "java": true}}}'
kit_run kit-custom-stack 'STACK=svc' 'HARNESS=opencode'
check "$(has "AIRLOCK_WITH_JAVA=1" "$envdump" && has "AIRLOCK_WITH_PYTHON=0" "$envdump" \
        && has "AIRLOCK_WITH_NODE=1" "$envdump" && echo 1 || echo 0)" \
  "a kit-defined stack maps its components to build args" "$envdump"
check "$(has "stack-node stack-java harness-opencode" "$OUT" && echo 1 || echo 0)" \
  "…and to the whitelist blocks, with no stack-python it did not ask for" "$OUT"
check "$(printf '%s\n' "$WL" | grep -Fqx '.maven.org' && ! printf '%s\n' "$WL" | grep -Fqx '.pypi.org' && echo 1 || echo 0)" \
  "…which is what actually lands in the composed list" "$WL"

# Strict validation: this file decides what gets installed, so nothing is guessed.
bad_kit() {  # <label> <json> <expected fragment>
  local label="$1" p
  kit_write "kit-bad-$(printf '%s' "$label" | tr -c 'a-z0-9' '-')" "$2"
  p="$(new_project "kitbad-$(printf '%s' "$label" | tr -c 'a-z0-9' '-')")"
  OUT="$( cd "$p" && AIRLOCK_KIT_CONFIG="$KIT" "$AIRLOCK" shell 2>&1 )"; ST=$?
  if [[ $ST -ne 0 ]] && has "$3" "$OUT"; then ok "$label"; else bad "$label" "$OUT"; fi
}
bad_kit "not JSON"          'stacks: base'                                    "not valid JSON"
bad_kit "top level list"    '["base"]'                                        "must be a JSON object"
bad_kit "unknown key"       '{"harness": ["opencode"], "stacks": {"base": {"node": true}}}' "unknown key"
bad_kit "unknown harness"   '{"harnesses": ["aider"], "stacks": {"base": {"node": true}}}'  "is not one of"
bad_kit "harness twice"     '{"harnesses": ["claude", "claude"], "stacks": {"base": {"node": true}}}' "listed twice"
bad_kit "kit-wide playwright" '{"playwright": true, "stacks": {"base": {"node": true}}}'     "COMPONENTS=playwright"
bad_kit "playwright in stack" '{"stacks": {"base": {"node": true, "playwright": true}}}'    "unknown component"
bad_kit "no stacks"         '{"harnesses": ["opencode"]}'                     "no 'stacks'"
bad_kit "empty stacks"      '{"stacks": {}}'                                  "non-empty object"
bad_kit "unknown component" '{"stacks": {"base": {"node": true, "rust": true}}}' "unknown component"
bad_kit "component string"  '{"stacks": {"base": {"node": "yes"}}}'           "must be true or false"
bad_kit "stack name shape"  '{"stacks": {"My Stack": {"node": true}}}'        "lowercase letters"
bad_kit "node needed"       '{"stacks": {"base": {"python": true}}}'          "need node"
KIT="$H/airlock.json"

# A missing kit config is fatal and says which file.
P="$(new_project kit-missing)"
OUT="$( cd "$P" && AIRLOCK_KIT_CONFIG="$T/nope.json" "$AIRLOCK" shell 2>&1 )"; ST=$?
check "$([[ $ST -ne 0 ]] && has "no kit config at $T/nope.json" "$OUT" && echo 1 || echo 0)" \
  "a missing kit config is fatal and names the path" "$OUT"

# The shipped file has to satisfy its own parser, and compose's defaults have to be
# what it says — that equality is what keeps raw callers on today's image.
check "$(python3 -m json.tool "$HARNESS_SRC/airlock.json" >/dev/null 2>&1 && echo 1 || echo 0)" \
  "the tracked airlock.json is valid JSON"
check "$(grep -q 'HARNESSES: ${AIRLOCK_HARNESSES:-opencode claude codex copilot}' "$HARNESS_SRC/docker-compose.yml" \
        && grep -q 'WITH_PLAYWRIGHT: ${AIRLOCK_WITH_PLAYWRIGHT:-0}' "$HARNESS_SRC/docker-compose.yml" \
        && grep -q 'WITH_JAVA: ${AIRLOCK_WITH_JAVA:-0}' "$HARNESS_SRC/docker-compose.yml" && echo 1 || echo 0)" \
  "compose defaults the build args to today's base image" \
  "$(grep -n 'AIRLOCK_WITH\|AIRLOCK_HARNESSES' "$HARNESS_SRC/docker-compose.yml")"

# ── 17. COMPONENTS= overrides the stack's component set ──────────────────────
# Per-component opt-in: the build args AND the whitelist blocks follow COMPONENTS
# when it is set, STACK when it is not. node is required (the harness CLIs are npm).
echo "17. COMPONENTS="
cat > "$H/bin/sandbox-run" <<'EOF'
#!/usr/bin/env bash
env | sort > "$ENV_OUT"
echo "ARGS:$*" >> "$ENV_OUT"
EOF
chmod +x "$H/bin/sandbox-run"

wl_project comp-py 'STACK=dotnet' 'HARNESS=opencode' 'COMPONENTS=python,node'
envdump="$(cat "$ENV_OUT")"
check "$([[ $ST -eq 0 ]] && has "AIRLOCK_WITH_PYTHON=1" "$envdump" && has "AIRLOCK_WITH_NODE=1" "$envdump" \
        && has "AIRLOCK_WITH_DOTNET=0" "$envdump" && echo 1 || echo 0)" \
  "COMPONENTS overrides STACK's build args (comma list, any order)" "$OUT"
check "$(has "via [stack-node stack-python harness-opencode]" "$OUT" && wl_has '.pypi.org' && ! wl_has '.nuget.org' && echo 1 || echo 0)" \
  "…and its whitelist blocks" "$OUT
$WL"
wl_project comp-java 'STACK=base' 'HARNESS=opencode' 'COMPONENTS="node java"'
envdump="$(cat "$ENV_OUT")"
check "$(has "AIRLOCK_WITH_JAVA=1" "$envdump" && has "AIRLOCK_WITH_PYTHON=0" "$envdump" && wl_has '.maven.org' && ! wl_has '.pypi.org' && echo 1 || echo 0)" \
  "a space-separated list works too, and drops what the stack had (python)" "$envdump"
wl_project comp-empty 'STACK=dotnet' 'HARNESS=opencode' 'COMPONENTS='
envdump="$(cat "$ENV_OUT")"
check "$([[ $ST -eq 0 ]] && has "AIRLOCK_WITH_DOTNET=1" "$envdump" && echo 1 || echo 0)" "an empty COMPONENTS= means the stack's set" "$OUT"
run "$P" config
check "$(has "COMPONENTS=   (empty" "$OUT" && echo 1 || echo 0)" "…and 'config' says so" "$OUT"
bad_cfg "components no node"    'COMPONENTS=python,java'         "node is required"
bad_cfg "components unknown"    'COMPONENTS=node,rust'           "unknown component 'rust'"

# Playwright is a per-project extra, default off: alone in COMPONENTS= it ADDS to the
# stack's set; in a list with base components it rides along with them. No egress.
wl_project comp-pw-default 'STACK=base' 'HARNESS=opencode'
check "$(has "AIRLOCK_WITH_PLAYWRIGHT=0" "$(cat "$ENV_OUT")" && echo 1 || echo 0)" "no COMPONENTS= → WITH_PLAYWRIGHT=0 (default off)" "$(cat "$ENV_OUT")"
wl_project comp-pw 'STACK=base' 'HARNESS=opencode' 'COMPONENTS=playwright'
envdump="$(cat "$ENV_OUT")"
check "$([[ $ST -eq 0 ]] && has "AIRLOCK_WITH_PLAYWRIGHT=1" "$envdump" && echo 1 || echo 0)" "COMPONENTS=playwright → WITH_PLAYWRIGHT=1" "$OUT"
check "$(has "AIRLOCK_WITH_NODE=1" "$envdump" && has "AIRLOCK_WITH_PYTHON=1" "$envdump" && has "AIRLOCK_WITH_JAVA=0" "$envdump" && echo 1 || echo 0)" \
  "…on top of the stack's own components (python kept)" "$envdump"
check "$(has "via [stack-node stack-python harness-opencode]" "$OUT" && echo 1 || echo 0)" "…and it adds no whitelist block" "$OUT"
run "$P" config
check "$(has "added to STACK's components: playwright" "$OUT" && echo 1 || echo 0)" "…and 'config' says it adds" "$OUT"
wl_project comp-pw-list 'STACK=base' 'HARNESS=opencode' 'COMPONENTS=node,java,playwright'
envdump="$(cat "$ENV_OUT")"
check "$(has "AIRLOCK_WITH_PLAYWRIGHT=1" "$envdump" && has "AIRLOCK_WITH_JAVA=1" "$envdump" && has "AIRLOCK_WITH_PYTHON=0" "$envdump" && echo 1 || echo 0)" \
  "in a list with base components it rides along with them" "$envdump"
bad_cfg "components pw no node" 'COMPONENTS=python,playwright'   "node is required"

# ── 18. only THE harness is built into the image ─────────────────────────────
echo "18. AIRLOCK_HARNESSES is the project's one harness"
hp() { P="$(new_project "$1")"; CTL="$(ctl_for "$P")"; mkdir -p "$CTL"; printf 'STACK=base\nHARNESS=%s\n' "$2" > "$CTL/config"; }
hp img-claude claude
run "$P" shell
check "$(grep -qx 'AIRLOCK_HARNESSES=claude' "$ENV_OUT" && echo 1 || echo 0)" "HARNESS=claude → only claude is installed" "$(grep HARNESSES "$ENV_OUT")"
hp img-oc opencode
run "$P" oc
check "$(grep -qx 'AIRLOCK_HARNESSES=opencode' "$ENV_OUT" && echo 1 || echo 0)" "HARNESS=opencode → only opencode" "$(grep HARNESSES "$ENV_OUT")"
hp img-copilot copilot
run "$P" copilot
check "$(grep -qx 'AIRLOCK_HARNESSES=copilot' "$ENV_OUT" && echo 1 || echo 0)" "HARNESS=copilot → only copilot" "$(grep HARNESSES "$ENV_OUT")"
# The Dockerfile's install loop takes a one-item list, and sandbox-run skips the npm
# version lookup for a CLI that is not going in (it would only bust the layer cache).
df="$(sed -n '/^ARG HARNESSES=/,/npm install -g \$pkgs/p' "$HARNESS_SRC/dev/Dockerfile")"
check "$(has 'for h in ${HARNESSES}; do' "$df" && has '[ -z "$pkgs" ] || npm install -g $pkgs' "$df" && echo 1 || echo 0)" \
  "dev/Dockerfile loops over HARNESSES (one item is fine)" "$df"
rv="$(sed -n '/^resolve_opencode_version()/,/^}/p;/^resolve_claude_version()/,/^}/p' "$HARNESS_SRC/bin/sandbox-run")"
check "$(has 'in_image opencode || return 0' "$rv" && has 'in_image claude || return 0' "$rv" && echo 1 || echo 0)" \
  "sandbox-run resolves a CLI's version only when that CLI is in the image" "$rv"
ii="$(sed -n '/^in_image()/,/^}/p' "$HARNESS_SRC/bin/sandbox-run")"
check "$(bash -c "$ii"'; AIRLOCK_HARNESSES=claude; in_image claude && ! in_image opencode && unset AIRLOCK_HARNESSES && in_image codex' && echo 1 || echo 0)" \
  "…and raw callers (no AIRLOCK_HARNESSES) still get every lookup" "$ii"

# ── 19. project-type detection ───────────────────────────────────────────────
# A pure function of a directory: it only SUGGESTS (the wizard's default), and the
# non-interactive path never reads it — the tree it reads is agent-writable.
echo "19. detect_project_stack"
cp "$HARNESS_SRC/dev/Dockerfile" "$H/dev/Dockerfile"   # the menu reads its pins from here
libs() { HARNESS_DIR="$H"; NAME=airlock
         . "$H/bin/lib/airlock-kit.sh"; . "$H/bin/lib/airlock-backends.sh"; . "$H/bin/lib/airlock-config.sh"
         . "$H/bin/lib/airlock-init.sh"; }
det() { ( libs; detect_project_stack "$1" ); }
dproj() { local d="$T/det-$1"; mkdir -p "$d"; shift
          for f in "$@"; do mkdir -p "$d/$(dirname "$f")"; : > "$d/$f"; done; printf '%s' "$d"; }
check "$([[ "$(det "$(dproj java pom.xml package.json)")" == "java-angular|found pom.xml" ]] && echo 1 || echo 0)" \
  "pom.xml → java-angular, with the reason" "$(det "$T/det-java")"
check "$(det "$(dproj gradle build.gradle.kts)" | grep -q '^java-angular|found build.gradle.kts$' && echo 1 || echo 0)" "build.gradle.kts → java-angular"
check "$(det "$(dproj net src/App/App.csproj)" | grep -q '^dotnet|found src/App/App.csproj' && echo 1 || echo 0)" \
  "a .csproj two levels down → dotnet" "$(det "$T/det-net")"
check "$(det "$(dproj sln App.sln)" | grep -q '^dotnet|' && echo 1 || echo 0)" "a .sln → dotnet"
check "$(det "$(dproj deep a/b/c/App.csproj)" | grep -q '^base|no project file' && echo 1 || echo 0)" \
  "…but not three directories down (depth ≤ 2)" "$(det "$T/det-deep")"
check "$(det "$(dproj deepjava a/b/pom.xml)" | grep -q '^base|' && echo 1 || echo 0)" "a pom.xml two directories down is not the project's"
check "$(det "$(dproj pyreact backend/pyproject.toml frontend/package.json)" | grep -q '^base|found backend/pyproject.toml' && echo 1 || echo 0)" \
  "Python + React → base (node + python)" "$(det "$T/det-pyreact")"
check "$(det "$(dproj req requirements-dev.txt)" | grep -q '^base|found requirements-dev.txt' && echo 1 || echo 0)" "requirements*.txt → base"
check "$(det "$(dproj js package.json)" | grep -q '^node|found package.json' && echo 1 || echo 0)" \
  "package.json alone → node" "$(det "$T/det-js")"
check "$(det "$(dproj nm node_modules/package.json)" | grep -q '^base|' && echo 1 || echo 0)" "node_modules is not looked into"
check "$(det "$(dproj empty)" | grep -q '^base|no project file recognised$' && echo 1 || echo 0)" "nothing → base"
kit_write kit-nonode '{"stacks": {"base": {"node": true, "python": true}}}'
check "$(AIRLOCK_KIT_CONFIG="$KIT" det "$T/det-js" | grep -q "^base|found package.json.*airlock.json has no 'node' stack" && echo 1 || echo 0)" \
  "a suggestion the kit does not define falls back to base, and says why" "$(AIRLOCK_KIT_CONFIG="$KIT" det "$T/det-js")"
KIT="$H/airlock.json"

# ── 20. the first-launch wizard ──────────────────────────────────────────────
# Driven through a pipe: bin/airlock only calls it when stdin AND stderr are a
# terminal, so the function itself reads stdin and is testable as-is.
echo "20. the wizard"
printf 'JDK_VERSION=21\n' > "$H/.env"     # the menu must read the pin, not hardcode it
wiz() {  # <project dir> <answers> → $OUT (menu + messages), $ST; writes the config
  OUT="$( cd "$1" && printf '%b' "$2" | ( libs; ctl_init "$PWD"
            init_wizard "$PWD" && init_write_config "$PWD" "$WIZ_STACK" "$WIZ_HARNESS" "$WIZ_COMPONENTS" "$WIZ_LOCAL_MODEL" \
            && { [[ -z "$WIZ_LLM_KEY" ]] || init_write_key "$WIZ_LLM_KEY"; } \
            && wizard_summary "$WIZ_STACK" "$WIZ_HARNESS" "$WIZ_COMPONENTS" ) 2>&1 )"; ST=$?
}
P="$(new_project wiz-java)"; : > "$P/pom.xml"; CTL="$(ctl_for "$P")"
wiz "$P" '\n\n\n2\n'
check "$([[ $ST -eq 0 ]] && grep -q '^STACK=java-angular ' "$CTL/config" && grep -q '^HARNESS=opencode ' "$CTL/config" && echo 1 || echo 0)" \
  "Enter, Enter → the suggested stack and opencode" "$OUT"
check "$(has "suggested: 2 (java-angular) — found pom.xml" "$OUT" && echo 1 || echo 0)" "the suggestion is pre-selected, with its reason" "$OUT"
check "$(printf '%s\n' "$OUT" | grep -Eq '^  2\) java-angular +node [0-9]+, python, java \(JDK 21\), angular \(CLI latest\)$' && echo 1 || echo 0)" \
  "stack lines show components + pins read from .env / dev/Dockerfile" "$OUT"
check "$(printf '%s\n' "$OUT" | grep -Eq '^  3\) dotnet +node [0-9]+, dotnet \(SDK [0-9.]+\)$' && printf '%s\n' "$OUT" | grep -Eq '^  5\) custom +— pick components one by one$' && echo 1 || echo 0)" \
  "…every stack, then 'custom' last" "$OUT"
check "$(has "Bake Playwright + Chromium into this project's image? [y/N]" "$OUT" && ! grep -q '^COMPONENTS=' "$CTL/config" && echo 1 || echo 0)" \
  "the Playwright question is asked, and Enter (no) writes no COMPONENTS=" "$OUT"
check "$(printf '%s\n' "$OUT" | grep -n 'Stack —\|Bake Playwright\|Harness —' | cut -d: -f2 | cut -c1-10 | tr '\n' '|' | grep -q '^Stack — .*|Bake Playw|Harness — |$' && echo 1 || echo 0)" \
  "…asked after the stack and before the harness" "$OUT"
check "$(has "1) opencode  — local/cloud models via opencode.json" "$OUT" && has "2) claude    — Claude Code" "$OUT" \
        && has "3) codex     — OpenAI Codex CLI" "$OUT" && has "4) copilot   — GitHub Copilot CLI" "$OUT" && echo 1 || echo 0)" \
  "the harness step lists each harness with a one-line description" "$OUT"
check "$(printf '%s\n' "$OUT" | grep -n 'Stack —\|Harness —' | cut -d: -f2 | tr '\n' ' ' | grep -q '^Stack — .*Harness — ' && echo 1 || echo 0)" \
  "…after the stack step" "$OUT"
check "$(has "STACK=java-angular HARNESS=opencode → image: node" "$OUT" && echo 1 || echo 0)" "the one-line summary" "$OUT"
run "$P" shell
envdump="$(cat "$ENV_OUT")"
check "$([[ $ST -eq 0 ]] && has "AIRLOCK_WITH_JAVA=1" "$envdump" && grep -qx 'AIRLOCK_HARNESSES=opencode' "$ENV_OUT" && echo 1 || echo 0)" \
  "the wizard's config is what launches" "$OUT"

P="$(new_project wiz-custom)"; CTL="$(ctl_for "$P")"
wiz "$P" '5\nn\ny\n\nn\n\n2\n\n'
check "$([[ $ST -eq 0 ]] && grep -q '^STACK=base ' "$CTL/config" && grep -q '^COMPONENTS=node,java ' "$CTL/config" && grep -q '^HARNESS=claude ' "$CTL/config" && echo 1 || echo 0)" \
  "custom → STACK=base + COMPONENTS=node,java, then harness 2 = claude" "$(cat "$CTL/config" 2>/dev/null)
$OUT"
check "$(has "node 2" "$OUT" && has "always on" "$OUT" && echo 1 || echo 0)" "node is forced on, with the reason" "$OUT"
run "$P" shell
envdump="$(cat "$ENV_OUT")"
check "$([[ $ST -eq 0 ]] && has "AIRLOCK_WITH_JAVA=1" "$envdump" && has "AIRLOCK_WITH_PYTHON=0" "$envdump" \
        && grep -qx 'AIRLOCK_HARNESSES=claude' "$ENV_OUT" && has "via [stack-node stack-java harness-claude]" "$OUT" && echo 1 || echo 0)" \
  "…and it launches with exactly those components and that harness" "$OUT"

P="$(new_project wiz-pw)"; CTL="$(ctl_for "$P")"
wiz "$P" '\ny\n\n2\n'
check "$([[ $ST -eq 0 ]] && grep -q '^STACK=base ' "$CTL/config" && grep -q '^COMPONENTS=playwright ' "$CTL/config" && echo 1 || echo 0)" \
  "a stack + 'y' → COMPONENTS=playwright, added to the stack" "$(cat "$CTL/config" 2>/dev/null)
$OUT"
check "$(has "playwright + chromium" "$OUT" && has "python" "$OUT" && echo 1 || echo 0)" "…and the summary shows the stack's set plus Playwright" "$OUT"
run "$P" shell
check "$([[ $ST -eq 0 ]] && grep -qx 'AIRLOCK_WITH_PLAYWRIGHT=1' "$ENV_OUT" && grep -qx 'AIRLOCK_WITH_PYTHON=1' "$ENV_OUT" && echo 1 || echo 0)" \
  "…and it launches with WITH_PLAYWRIGHT=1" "$OUT"
P="$(new_project wiz-pw-custom)"; CTL="$(ctl_for "$P")"
wiz "$P" '5\nn\nn\n\nn\ny\n\n2\n'
check "$([[ $ST -eq 0 ]] && grep -q '^COMPONENTS=node,playwright ' "$CTL/config" && echo 1 || echo 0)" \
  "custom + 'y' → Playwright joins the component list" "$(cat "$CTL/config" 2>/dev/null)"

P="$(new_project wiz-want)"; CTL="$(ctl_for "$P")"
OUT="$( cd "$P" && printf '\n\n2\n' | ( libs; ctl_init "$PWD"; init_wizard "$PWD" codex \
          && init_write_config "$PWD" "$WIZ_STACK" "$WIZ_HARNESS" "$WIZ_COMPONENTS" ) 2>&1 )"; ST=$?
check "$([[ $ST -eq 0 ]] && grep -q '^HARNESS=codex ' "$CTL/config" && has "Harness: codex" "$OUT" && ! has "harness [" "$OUT" && echo 1 || echo 0)" \
  "the harness the verb named (airlock codex) is taken as the answer, not asked" "$OUT"

P="$(new_project wiz-retry)"; CTL="$(ctl_for "$P")"
wiz "$P" '9\nabc\n4\n\n\n2\n'
check "$([[ $ST -eq 0 ]] && has "enter a number from 1 to 5" "$OUT" && grep -q '^STACK=node ' "$CTL/config" && echo 1 || echo 0)" \
  "a bad answer is asked again, not guessed" "$OUT"
P="$(new_project wiz-eof)"; CTL="$(ctl_for "$P")"
wiz "$P" ''
check "$([[ $ST -ne 0 && ! -e "$CTL/config" ]] && has "nothing written" "$OUT" && echo 1 || echo 0)" \
  "no answer (EOF) aborts and writes nothing" "$OUT"
P="$(new_project wiz-eof2)"; CTL="$(ctl_for "$P")"
wiz "$P" '5\ny\n'
check "$([[ $ST -ne 0 && ! -e "$CTL/config" ]] && echo 1 || echo 0)" "…also halfway through the custom questions" "$OUT"

# The LLM backend step: endpoint asks for the server, the key goes to the secrets file.
P="$(new_project wiz-endpoint)"; CTL="$(ctl_for "$P")"
wiz "$P" '\n\n\n1\n\n11434\nllama3.1:8b\ny\nsk-wiz-1\n'
check "$([[ $ST -eq 0 ]] && grep -q '^LOCAL_MODEL=endpoint ' "$CTL/config" && grep -qx 'LLM_HOST=host.docker.internal' "$CTL/config" \
        && grep -qx 'LLM_PORT=11434' "$CTL/config" && grep -q '^LLM_MODEL=llama3.1:8b ' "$CTL/config" && echo 1 || echo 0)" \
  "backend 1 = endpoint: host (default), port and model land in the config" "$(cat "$CTL/config" 2>/dev/null)
$OUT"
check "$(has "1) endpoint  — a local/LAN OpenAI-compatible server" "$OUT" && has "2) off       — none" "$OUT" && has "backend [1]" "$OUT" && echo 1 || echo 0)" \
  "…the step offers endpoint and off, endpoint pre-selected for opencode" "$OUT"
check "$(grep -q 'sk-wiz-1' "$CTL/config" && echo 0 || echo 1)" "…the key is NOT in the config" "$(cat "$CTL/config")"
check "$(grep -qx 'LLM_KEY=sk-wiz-1' "$CTL/env" 2>/dev/null && [[ "$(stat -f '%Lp' "$CTL/env" 2>/dev/null || stat -c '%a' "$CTL/env")" == 600 ]] && echo 1 || echo 0)" \
  "…it is in the secrets file, mode 0600"
run "$P" shell
check "$([[ $ST -eq 0 ]] && grep -qx 'LLM_KEY=sk-wiz-1' "$ENV_OUT" && grep -qx 'LOCAL_MODEL=endpoint' "$ENV_OUT" && echo 1 || echo 0)" \
  "…and the wizard's endpoint config launches with that key" "$OUT"
P="$(new_project wiz-claude-off)"; CTL="$(ctl_for "$P")"
wiz "$P" '\n\n2\n\n'
check "$([[ $ST -eq 0 ]] && grep -q '^HARNESS=claude ' "$CTL/config" && grep -q '^LOCAL_MODEL=off ' "$CTL/config" && has "backend [2]" "$OUT" && echo 1 || echo 0)" \
  "for Claude Code the pre-selected backend is off" "$OUT"
P="$(new_project wiz-plugin)"; CTL="$(ctl_for "$P")"
OUT="$( cd "$P" && printf '\n\n\n\n' | ( AIRLOCK_BACKENDS="$PLUG"; libs; ctl_init "$PWD"; init_wizard "$PWD" \
          && init_write_config "$PWD" "$WIZ_STACK" "$WIZ_HARNESS" "$WIZ_COMPONENTS" "$WIZ_LOCAL_MODEL" ) 2>&1 )"; ST=$?
check "$([[ $ST -eq 0 ]] && has "3) fixture   — Fixture model (backends plugin)" "$OUT" && has "5) ask" "$OUT" \
        && grep -q '^LOCAL_MODEL=ask ' "$CTL/config" && echo 1 || echo 0)" \
  "with a backends plugin the step lists its pickers and defaults to ask" "$OUT"
rm -f "$H/.env"

# bin/airlock's gate: the wizard needs BOTH stdin and stderr on a terminal, and
# init and the first launch share one writer.
check "$(grep -q 'if \[\[ -t 0 && -t 2 \]\]; then' "$H/bin/airlock" && grep -q 'if \[\[ -z "$stack" && -t 0 && -t 2 \]\]; then' "$H/bin/airlock" && echo 1 || echo 0)" \
  "bin/airlock runs the wizard only with stdin and stderr on a terminal"
check "$([[ "$(grep -c 'init_write_config "$PWD"' "$H/bin/airlock")" == 2 ]] && ! grep -q 'cat > "$CTL/config"' "$H/bin/airlock" && echo 1 || echo 0)" \
  "init and the first launch write the config through one function"

# ── 21. gc: the classification is a pure function ─────────────────────────────
echo "21. gc: candidate classification (pure: a fake listing + a temp AIRLOCK_HOME)"
GCH="$T/gchome"; mkdir -p "$GCH"
now="$(date +%s)"; day=86400
gc_ctl() { mkdir -p "$GCH/$1"; [[ -n "${2:-}" ]] && echo "$2" > "$GCH/$1/last-launch"; return 0; }
gc_ctl fresh-bbbbbb   $((now - 1*day))
gc_ctl stale-cccccc   $((now - 40*day))
gc_ctl pin-dddddd     $((now - 400*day)); printf 'STACK=base\nGC_DAYS=0\n' > "$GCH/pin-dddddd/config"
gc_ctl short-abcabc   $((now - 10*day));  printf 'GC_DAYS="7"   # a week\n' > "$GCH/short-abcabc/config"
gc_ctl rebuilt-c3c3c3 $((now - 100*day))
gc_ctl new-nostamp-b2b2b2
gc_ctl old-nostamp-a1a1a1; : > "$GCH/old-nostamp-a1a1a1/whitelist.applied"
touch -t 202501010000 "$GCH/old-nostamp-a1a1a1/whitelist.applied" "$GCH/old-nostamp-a1a1a1"
GCL="harness-orph-aaaaaa-dev:latest|i01|0|0|airlock|$GCH|
harness-fresh-bbbbbb-dev:latest|i02|0|0|airlock|$GCH|
harness-stale-cccccc-dev:latest|i03|0|0|airlock|$GCH|
harness-pin-dddddd-dev:latest|i04|0|0|airlock|$GCH|
harness-cur-eeeeee-dev:latest|i05|0|0|airlock|$GCH|
harness-inuse-f0f0f0-dev:latest|i06|2|0|airlock|$GCH|
harness-gamma-111111-dev:latest|i07|0|0|harness||
harness-other-222222-dev:latest|i08|0|0|airlock|/elsewhere|
harness-legacy-333333-dev:latest|i09|0|0|||
harness-alpha-dev:latest|i10|0|0|||
other-tool-image:fix|i11|0|0|||
harness-beta-dev:latest|i12|0|0|||
<none>:<none>|i13|0|0|airlock|$GCH|
<none>:<none>|i14|0|0|||
<none>:<none>|i15|0|0|||harness-old-444444
harness-short-abcabc-dev:latest|i16|0|0|airlock|$GCH|
harness-old-nostamp-a1a1a1-dev:latest|i17|0|0|airlock|$GCH|
harness-new-nostamp-b2b2b2-dev:latest|i18|0|0|airlock|$GCH|
harness-rebuilt-c3c3c3-dev:latest|i19|0|$((now - day))|airlock|$GCH|
<none>:<none>|i20|1|0|airlock|$GCH|
sample-run1-dev:latest|i21|0|0|||"
gc_cls() { printf '%s\n' "$GCL" | ( AIRLOCK_HOME="$GCH"; NAME=airlock; . "$H/bin/lib/airlock-gc.sh"; gc_classify "$@" ); }
gc_expect() {   # <plan> <label> <id=action|kind or id=- for no line>…
  local plan="$1" label="$2" e id want got bad_=""; shift 2
  for e in "$@"; do
    id="${e%%=*}"; want="${e#*=}"
    got="$(printf '%s\n' "$plan" | awk -F'|' -v id="$id" '$4==id{print $1"|"$2}')"
    [[ "$want" == "-" ]] && want=""
    [[ "$got" == "$want" ]] || bad_="$bad_ $id: want '${want}' got '${got}';"
  done
  check "$([[ -z "$bad_" ]] && echo 1 || echo 0)" "$label" "$bad_"
}
M="$(gc_cls manual "$now" 30 0 harness-cur-eeeeee-dev)"
gc_expect "$M" "manual: orphaned removed, stale removed, fresh/pinned kept" \
  i01=remove\|orphaned i02=skip\|stale i03=remove\|stale i04=skip\|stale i16=remove\|stale
gc_expect "$M" "manual: the exempt current project, an image with a container, a raw-harness build and another AIRLOCK_HOME are kept" \
  i05=skip\|orphaned i06=skip\|orphaned i07=skip\|orphaned i08=skip\|orphaned
gc_expect "$M" "manual: non-matching names (no hash, other repos) produce no line at all" \
  i10=- i11=- i12=- i21=- i14=-
gc_expect "$M" "manual: a pre-label image is judged by name; airlock + pre-label dangling leftovers removed, one with a container kept" \
  i09=remove\|orphaned i13=remove\|dangling i15=remove\|dangling i20=skip\|dangling
gc_expect "$M" "no stamp: old signs of life → stale, recent → kept; a recent image build counts as a launch" \
  i17=remove\|stale i18=skip\|stale i19=skip\|stale
check "$(printf '%s\n' "$M" | grep '|i04|' | grep -q 'GC_DAYS=0' && printf '%s\n' "$M" | grep '|i05|' | grep -q 'current project' && echo 1 || echo 0)" \
  "each skip says why" "$M"
A="$(gc_cls auto "$now" 30 0 harness-cur-eeeeee-dev)"
gc_expect "$A" "auto: orphaned + stale labelled images removed, current exempt" \
  i01=remove\|orphaned i03=remove\|stale i05=skip\|orphaned
gc_expect "$A" "auto: never a pre-label image, never a dangling one" \
  i09=skip\|orphaned i13=- i15=- i20=-
D0="$(gc_cls manual "$now" 0 0)"
gc_expect "$D0" "--days 0 turns the age rule off (orphaned still removed)" \
  i03=skip\|stale i16=skip\|stale i17=skip\|stale i01=remove\|orphaned
AS="$(gc_cls manual "$now" 30 1 harness-cur-eeeeee-dev)"
gc_expect "$AS" "--all-stale: every unpinned project's image regardless of age; GC_DAYS=0 and current still kept" \
  i02=remove\|stale i18=remove\|stale i04=skip\|stale i05=skip\|orphaned

# ── 22. GC / GC_DAYS config keys ─────────────────────────────────────────────
echo "22. GC and GC_DAYS are validated config keys"
P="$(new_project gc-keys)"; CTL="$(ctl_for "$P")"; mkdir -p "$CTL"
printf 'STACK=base\nGC=maybe\n' > "$CTL/config"; run "$P" shell
check "$([[ $ST -ne 0 ]] && has "GC='maybe' must be on or off" "$OUT" && echo 1 || echo 0)" "GC=maybe is refused" "$OUT"
printf 'STACK=base\nGC_DAYS=two\n' > "$CTL/config"; run "$P" shell
check "$([[ $ST -ne 0 ]] && has "GC_DAYS='two'" "$OUT" && echo 1 || echo 0)" "GC_DAYS=two is refused" "$OUT"
printf 'STACK=base\nGC=off\nGC_DAYS=0\n' > "$CTL/config"; rm -f "$CTL/last-launch"; run "$P" shell
check "$([[ $ST -eq 0 ]] && echo 1 || echo 0)" "GC=off GC_DAYS=0 are accepted" "$OUT"

# ── 23. the launch stamp ─────────────────────────────────────────────────────
echo "23. a launch stamps <ctl>/last-launch; lifecycle verbs do not"
stamp="$(cat "$CTL/last-launch" 2>/dev/null)"
check "$([[ "$stamp" =~ ^[0-9]+$ ]] && (( $(date +%s) - stamp < 120 )) && echo 1 || echo 0)" "shell wrote last-launch (epoch seconds)" "$stamp"
envdump="$(cat "$ENV_OUT")"
check "$(has "AIRLOCK_LAUNCHER=airlock" "$envdump" && has "AIRLOCK_IMAGE_HOME=$AIRLOCK_HOME" "$envdump" && echo 1 || echo 0)" \
  "a launch hands compose the image labels (launcher=airlock, home)" "$envdump"
for v in down deps; do
  rm -f "$CTL/last-launch"
  # shellcheck disable=SC2086
  run "$P" $v
  check "$([[ ! -e "$CTL/last-launch" ]] && echo 1 || echo 0)" "'$v' leaves no stamp"
done
for v in run up; do
  rm -f "$CTL/last-launch"; run "$P" $v true
  check "$([[ -s "$CTL/last-launch" ]] && echo 1 || echo 0)" "'$v' stamps"
done

# ── 24. the gc verb, against the fake docker ─────────────────────────────────
echo "24. airlock gc: --dry-run never removes; the real run removes exactly the plan"
P="$(new_project gc-here)"; CTL="$(ctl_for "$P")"
here="harness-$(basename "$CTL")-dev"
fake_docker_reset
printf '%s\n' "harness-gone-aaaaaa-dev|latest|aaa111" "$here|latest|bbb222" "harness-alpha-dev|latest|ccc333" "other-tool-image|fix|ddd444" > "$FAKE_IMAGES"
printf '%s\n' "<none>|<none>|eee555" "<none>|<none>|fff666" > "$FAKE_DANGLING"
printf '%s\n' "sha256:aaa111|2026-01-01T00:00:00Z|airlock|$AIRLOCK_HOME||" \
              "sha256:bbb222|2026-01-01T00:00:00Z|airlock|$AIRLOCK_HOME||" \
              "sha256:ccc333|2026-01-01T00:00:00Z||||" \
              "sha256:eee555|2026-01-01T00:00:00Z|airlock|$AIRLOCK_HOME|harness-gone-aaaaaa|dev" \
              "sha256:fff666|2026-01-01T00:00:00Z||||" > "$FAKE_INSPECT"
printf '%s\n' "sha256:aaa111|5.2GB" "sha256:eee555|300MB" "sha256:bbb222|4GB" > "$FAKE_DF"
run "$P" gc --dry-run
check "$([[ $ST -eq 0 ]] && has "would remove 2 image(s), ~5.5 GB" "$OUT" && echo 1 || echo 0)" "--dry-run lists the plan with sizes and a total" "$OUT"
check "$(has "remove  orphaned  harness-gone-aaaaaa-dev:latest (aaa111, 5.2 GB)" "$OUT" && has "remove  dangling  <none>:<none> (eee555" "$OUT" && echo 1 || echo 0)" \
  "…an orphaned image and an airlock dangling leftover" "$OUT"
check "$(has "the current project's image" "$OUT" && ! has "ccc333" "$OUT" && ! has "ddd444" "$OUT" && echo 1 || echo 0)" \
  "…the cwd project is exempt; non-airlock images are not even listed" "$OUT"
check "$(has "1 other dangling image(s)" "$OUT" && echo 1 || echo 0)" "…other dangling images are reported, not planned" "$OUT"
check "$(! grep -q '^rmi' "$DOCKER_LOG" && echo 1 || echo 0)" "--dry-run never calls docker rmi" "$(cat "$DOCKER_LOG")"
check "$([[ ! -d "$CTL" ]] && echo 1 || echo 0)" "gc creates no control dir"
: > "$DOCKER_LOG"; run "$P" gc
rmis="$(grep '^rmi' "$DOCKER_LOG")"
check "$([[ $ST -eq 0 && "$rmis" == "$(printf 'rmi harness-gone-aaaaaa-dev:latest\nrmi eee555')" ]] && echo 1 || echo 0)" \
  "the real run removes exactly the planned images (tag by ref, dangling by id)" "$rmis
$OUT"
check "$(has "removed 2 image(s), ~5.5 GB" "$OUT" && echo 1 || echo 0)" "…and says what it freed" "$OUT"
echo aaa111 > "$FAKE_INUSE"; : > "$DOCKER_LOG"; run "$P" gc
check "$(! grep -q '^rmi harness-gone' "$DOCKER_LOG" && has "1 container(s) still use it" "$OUT" && echo 1 || echo 0)" \
  "an image with a container (running or stopped) is kept" "$OUT"
: > "$FAKE_INUSE"
run "$T" gc --dry-run
check "$([[ $ST -eq 0 ]] && has "harness-gone-aaaaaa-dev" "$OUT" && echo 1 || echo 0)" "gc runs from any dir (no project, no launch guard)" "$OUT"
run "$P" gc --days x
check "$([[ $ST -ne 0 ]] && has "--days needs a number" "$OUT" && echo 1 || echo 0)" "--days x is refused" "$OUT"
run "$P" gc --bogus
check "$([[ $ST -ne 0 ]] && echo 1 || echo 0)" "an unknown gc arg is refused" "$OUT"

# ── 25. the launch-time sweep ────────────────────────────────────────────────
echo "25. the launch-time sweep: labelled orphaned/stale only, current exempt, GC=off disables"
P="$(new_project gc-auto)"; CTL="$(ctl_for "$P")"; mkdir -p "$CTL"; printf 'STACK=base\n' > "$CTL/config"
here="harness-$(basename "$CTL")-dev"
mkdir -p "$AIRLOCK_HOME/oldproj-dddddd"; echo $((now - 60*day)) > "$AIRLOCK_HOME/oldproj-dddddd/last-launch"
gc_auto_fake() {
  fake_docker_reset
  printf '%s\n' "harness-gone2-bbbbbb-dev|latest|aaa111" "harness-legacy-cccccc-dev|latest|bbb222" \
                "$here|latest|ccc333" "harness-oldproj-dddddd-dev|latest|ddd444" > "$FAKE_IMAGES"
  printf '%s\n' "<none>|<none>|eee555" > "$FAKE_DANGLING"
  printf '%s\n' "sha256:aaa111|2026-01-01T00:00:00Z|airlock|$AIRLOCK_HOME||" \
                "sha256:bbb222|2026-01-01T00:00:00Z||||" \
                "sha256:ccc333|2026-01-01T00:00:00Z|airlock|$AIRLOCK_HOME||" \
                "sha256:ddd444|2026-01-01T00:00:00Z|airlock|$AIRLOCK_HOME||" \
                "sha256:eee555|2026-01-01T00:00:00Z|airlock|$AIRLOCK_HOME||" > "$FAKE_INSPECT"
  printf '%s\n' "sha256:aaa111|5GB" "sha256:ddd444|5.4GB" > "$FAKE_DF"
}
gc_auto_fake; run "$P" shell
rmis="$(grep '^rmi' "$DOCKER_LOG" | sort)"
check "$([[ $ST -eq 0 && "$rmis" == "$(printf 'rmi harness-gone2-bbbbbb-dev:latest\nrmi harness-oldproj-dddddd-dev:latest')" ]] && echo 1 || echo 0)" \
  "removes the labelled orphan and the 60-day-stale project; not the pre-label image, the current one or a dangling layer" "$rmis"
check "$(has "gc removed 2 orphaned/stale sandbox image(s) (10.4 GB)" "$OUT" && echo 1 || echo 0)" "prints one line when it removed something" "$OUT"
fake_docker_reset; run "$P" shell
check "$([[ $ST -eq 0 ]] && ! has "gc removed" "$OUT" && echo 1 || echo 0)" "silent when there is nothing to remove" "$OUT"
printf 'STACK=base\nGC=off\n' > "$CTL/config"
gc_auto_fake; run "$P" shell
check "$([[ $ST -eq 0 ]] && ! grep -q '^rmi' "$DOCKER_LOG" && ! grep -q '^images' "$DOCKER_LOG" && echo 1 || echo 0)" \
  "GC=off: no sweep at all (docker not even asked)" "$(cat "$DOCKER_LOG")"
fake_docker_reset

# ── 26. help and unknown verbs, before anything starts ───────────────────────
echo "26. airlock help / an unknown verb: answered before any config, kit or control dir"
P="$(new_project help-here)"; CTL="$(ctl_for "$P")"
for v in help --help -h; do
  run "$P" $v
  check "$([[ $ST -eq 0 ]] && has "verify" "$OUT" && has "reload-proxy" "$OUT" && echo 1 || echo 0)" "'$v' exits 0 and lists the verbs" "$OUT"
done
check "$([[ ! -e "$CTL" ]] && echo 1 || echo 0)" "help creates no control dir"
run "$P" bogus
check "$([[ $ST -eq 2 ]] && has "unknown verb 'bogus' — try 'airlock help'" "$OUT" && echo 1 || echo 0)" "an unknown verb exits 2 with the hint" "$OUT"
check "$([[ ! -e "$CTL" ]] && echo 1 || echo 0)" "…and creates no control dir"

echo
echo "passed: $PASS   failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
