#!/usr/bin/env bash
#
# airlock-verify.sh — owns `airlock verify`: the probes that prove the sandbox is
# holding what it claims. Two halves, in one function:
#
#   the BOUNDARY   what the container can reach — egress, the LLM door, the env
#                  handed in, the bind mounts — asked of the container itself, one
#                  `harness run` per probe.
#   the POSTURE    whether the configuration it was launched with is the one the
#                  project asked for — no other harness's vendor domains on the
#                  whitelist, no unselected harness's credential non-empty inside,
#                  no gh login while GH=off, exactly one LLM door target.
#
# Sourced by bin/sandbox-run, defines functions only. Callers provide $HARNESS_DIR,
# $HARNESS (the path to bin/harness), $PROJECT, the `wl_file`, `ask_default` and
# `pick_backend` helpers, and the AIRLOCK_* posture variables `bin/airlock` exports.
#
# Exposes:
#   airlock_verify    run every probe; PASS/FAIL per line, exits with 0 or 1

airlock_verify() {
  VERIFY_FAIL=0
  export HARNESS_BUILD=""          # build once below, then reuse the image
  # A variable exported HERE that must not turn up inside. Its name is fixed so
  # the probe can look for it; its value is irrelevant.
  export AIRLOCK_VERIFY_CANARY="canary-$$"

  v_pass() { echo "PASS  $1"; }
  v_fail() { echo "FAIL  $1${2:+ — $2}"; VERIFY_FAIL=1; }
  v_skip() { echo "SKIP  $1${2:+ — $2}"; }

  # Run one shell command inside `dev`; status is the probe's answer.
  v_run()  { "$HARNESS" run "$PROJECT" bash -lc "$1" >/dev/null 2>&1; }
  v_out()  { "$HARNESS" run "$PROJECT" bash -lc "$1" 2>/dev/null; }

  v_expect_fail() {   # <label> <command> — the sandbox is right when this FAILS
    if v_run "$2"; then v_fail "$1" "it succeeded, and it must not"; else v_pass "$1"; fi
  }
  v_expect_ok() {     # <label> <command>
    if v_run "$2"; then v_pass "$1"; else v_fail "$1" "it failed"; fi
  }

  # The LLM door's shape is part of the boundary now (one target port, or no door at
  # all), and that is the picker's decision — so resolve it. Never prompt, and never
  # start a backend: verify is about what the sandbox can reach, not about which
  # model is loaded.
  if [[ "${LOCAL_MODEL:-}" == "ask" ]]; then
    LOCAL_MODEL="$(ask_default)"
    echo "verify: LOCAL_MODEL=ask — verifying the non-interactive default ($LOCAL_MODEL)."
  fi
  pick_backend

  echo "verify: building + starting the sandbox for $PROJECT"
  HARNESS_BUILD="--build" "$HARNESS" up "$PROJECT" >/dev/null

  echo
  echo "── egress ───────────────────────────────────────────────────────────"
  v_expect_fail "a non-whitelisted domain is denied by the proxy" \
    "curl -sS -m 15 -o /dev/null https://example.com"
  # An offline host cannot prove the allow half; say so instead of failing.
  if curl -fsS -m 8 -o /dev/null https://registry.npmjs.org/ 2>/dev/null; then
    v_expect_ok "a whitelisted domain works through the proxy" \
      "curl -fsS -m 30 -o /dev/null https://registry.npmjs.org/"
  else
    v_skip "a whitelisted domain works through the proxy" "this machine is offline"
  fi
  v_expect_fail "a direct connection bypassing the proxy fails (domain)" \
    "curl -sS --noproxy '*' -m 10 -o /dev/null https://example.com"
  v_expect_fail "a direct connection bypassing the proxy fails (raw IP)" \
    "curl -sS --noproxy '*' -m 10 -o /dev/null http://1.1.1.1"
  v_expect_fail "there is no external DNS" "getent hosts example.com"
  v_expect_fail "host.docker.internal does not resolve" "getent hosts host.docker.internal"

  echo
  echo "── the LLM door ─────────────────────────────────────────────────────"
  # One door, one host port. `llm2`/`llm3` are network ALIASES of the same container,
  # so a plugin or opencode config may use a distinct hostname per backend — all three
  # names must answer, and all three must be the SAME container.
  door_ports="$("$HARNESS" config "$PROJECT" 2>/dev/null \
                | grep -oE 'TCP:[A-Za-z0-9._-]+:[0-9]+' | sed 's/.*://' | sort -u)"
  n_ports="$(printf '%s\n' "$door_ports" | grep -c . | tr -d ' ')"
  if [[ "$n_ports" == "1" ]]; then
    v_pass "the LLM door forwards to exactly one host port ($door_ports)"
  else
    v_fail "the LLM door forwards to exactly one host port" \
      "$n_ports distinct targets: $(printf '%s' "$door_ports" | tr '\n' ' ')"
  fi
  if [[ "${LLM_DOOR:-1}" == "1" ]]; then
    ips="$(v_out "getent hosts llm llm2 llm3 | awk '{print \$1}' | sort -u" || true)"
    n_ips="$(printf '%s\n' "$ips" | grep -c . | tr -d ' ')"
    if [[ "$n_ips" == "1" ]]; then
      v_pass "llm, llm2 and llm3 are one and the same door"
    else
      v_fail "llm, llm2 and llm3 are one and the same door" \
        "resolved to $n_ips address(es): $(printf '%s' "$ips" | tr '\n' ' ')"
    fi
  else
    v_expect_fail "with no backend selected, llm does not resolve"  "getent hosts llm"
    v_expect_fail "with no backend selected, llm2 does not resolve" "getent hosts llm2"
    v_expect_fail "with no backend selected, llm3 does not resolve" "getent hosts llm3"
  fi

  echo
  echo "── what got handed in ───────────────────────────────────────────────"
  v_expect_fail "a variable exported in the launching shell is absent inside" \
    "printenv AIRLOCK_VERIFY_CANARY"
  v_expect_fail "the opencode config dir is read-only" \
    "touch /etc/opencode/airlock-verify-probe"
  v_expect_fail "/Users does not exist inside" "test -e /Users"
  v_expect_fail "your host home directory does not exist inside" "test -e '$HOME'"
  # Only meaningful when the host user isn't literally 'dev' (the container user).
  host_user="$(id -un)"
  if [[ "$host_user" != "dev" ]]; then
    v_expect_fail "/home/$host_user does not exist inside" "test -e '/home/$host_user'"
  fi

  echo
  echo "── bind mounts ──────────────────────────────────────────────────────"
  # /proc/self/mountinfo, field 5 = mount point, field 6 = options. Everything the
  # container legitimately has is either a kernel filesystem or one of ours.
  mi="$(v_out "cat /proc/self/mountinfo" || true)"
  if [[ -z "$mi" ]]; then
    v_fail "the mount table is readable" "could not read /proc/self/mountinfo"
  else
    unexpected=""
    while read -r mp opts; do
      [[ -n "$mp" ]] || continue
      case "$mp" in
        /|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/run/*) continue ;;
        /etc/resolv.conf|/etc/hostname|/etc/hosts) continue ;;
        /workspace|/etc/opencode) continue ;;
        /home/dev/.claude|/home/dev/.codex|/home/dev/.config/gh|/home/dev/.copilot) continue ;;
      esac
      unexpected="${unexpected:+$unexpected }$mp"
    done <<EOF
$(printf '%s\n' "$mi" | awk '{print $5, $6}')
EOF
    if [[ -n "$unexpected" ]]; then
      v_fail "only the expected bind mounts are present" "also mounted: $unexpected"
    else
      v_pass "only the expected bind mounts are present"
    fi
    mp_opts() { printf '%s\n' "$mi" | awk -v m="$1" '$5 == m {print $6}' | head -1; }
    case ",$(mp_opts /workspace)," in *,rw,*) v_pass "/workspace is mounted read-write" ;;
      *) v_fail "/workspace is mounted read-write" "options: $(mp_opts /workspace)" ;; esac
    case ",$(mp_opts /etc/opencode)," in *,ro,*) v_pass "the opencode config is mounted read-only" ;;
      *) v_fail "the opencode config is mounted read-only" "options: $(mp_opts /etc/opencode)" ;; esac
    for d in /home/dev/.claude /home/dev/.codex /home/dev/.config/gh /home/dev/.copilot; do
      if [[ -n "$(mp_opts "$d")" ]]; then v_pass "state mount present: $d"
      else v_fail "state mount present: $d" "not in the mount table"; fi
    done
  fi

  echo
  echo "── the configuration ────────────────────────────────────────────────"
  # The probes above ask what the sandbox CAN do. These ask whether the posture it
  # was launched with is the one the project asked for — a boundary held perfectly
  # around the wrong configuration is still the wrong configuration. Only `airlock`
  # exports HARNESS/GH; a raw caller gets a SKIP rather than a guess.
  wl_now="$(wl_file)"
  T_OWN="$(mktemp -t airlock-verify-own)"; trap 'rm -f "$T_OWN"' EXIT
  wl_domains() { grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null | sed 's/[[:space:]]*$//'; }
  wl_in_project() {   # is $1 a domain the PROJECT's own WHITELIST asked for?
    local d
    set -f
    for d in ${AIRLOCK_WHITELIST:-}; do [[ "$d" == "$1" ]] && { set +f; return 0; }; done
    set +f
    return 1
  }
  if [[ -z "${AIRLOCK_HARNESS:-}" ]]; then
    v_skip "the whitelist carries no other harness's vendor domains" "AIRLOCK_HARNESS is not set (raw caller)"
    v_skip "no credential for an unselected harness is set inside" "AIRLOCK_HARNESS is not set (raw caller)"
  else
    # What this project's OWN blocks legitimately contribute. Blocks overlap on
    # purpose — stack-java and harness-copilot both list .githubusercontent.com — so
    # a domain is only "another harness's" when nothing the project itself selected
    # would have put it there.
    own="$T_OWN"
    : > "$own"
    for b in ${AIRLOCK_WL_BLOCKS:-}; do
      case "$b" in project) continue ;; esac
      [[ -f "$HARNESS_DIR/proxy/whitelist.d/$b.txt" ]]         && wl_domains "$HARNESS_DIR/proxy/whitelist.d/$b.txt" >> "$own"
    done
    strays=""; warned=""
    for h in opencode claude codex copilot; do
      [[ "$h" == "$AIRLOCK_HARNESS" ]] && continue
      blk="$HARNESS_DIR/proxy/whitelist.d/harness-$h.txt"
      [[ -f "$blk" ]] || continue
      while read -r d; do
        [[ -n "$d" ]] || continue
        wl_domains "$wl_now" | grep -Fqx "$d" || continue
        grep -Fqx "$d" "$own" && continue          # its own stack/harness put it there
        if wl_in_project "$d"; then warned="${warned:+$warned }$d(project WHITELIST)"
        else strays="${strays:+$strays }$d(harness-$h)"; fi
      done <<EOF
$(wl_domains "$blk")
EOF
    done
    if [[ -n "$strays" ]]; then
      v_fail "the whitelist carries no other harness's vendor domains" \
        "open for a harness this project does not run: $strays"
    else
      v_pass "the whitelist carries no other harness's vendor domains"
    fi
    [[ -n "$warned" ]] && echo "WARN  another harness's domain is open, but the project asked for it: $warned"

    # A credential the selected harness cannot use must not be inside the container.
    # (`airlock` exports every name, empty, for exactly this reason — this checks it.)
    allowed_creds=""
    case "$AIRLOCK_HARNESS" in
      opencode) allowed_creds="OPENAI_API_KEY OPENROUTER_API_KEY" ;;
      claude)   allowed_creds="ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN" ;;
      codex)    allowed_creds="OPENAI_API_KEY" ;;
      copilot)  allowed_creds="" ;;
    esac
    leaked=""
    for n in OPENAI_API_KEY OPENROUTER_API_KEY ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN; do
      case " $allowed_creds " in *" $n "*) continue ;; esac
      # Names only, never values: the probe's exit status is the whole answer.
      v_run "test -n \"\$$n\"" && leaked="${leaked:+$leaked }$n"
    done
    if [[ -n "$leaked" ]]; then
      v_fail "no credential for an unselected harness is set inside" \
        "non-empty inside for HARNESS=$AIRLOCK_HARNESS: $leaked"
    else
      v_pass "no credential for an unselected harness is set inside"
    fi
  fi

  if [[ -z "${AIRLOCK_GH:-}" ]]; then
    v_skip "no gh login is mounted while GH=off" "AIRLOCK_GH is not set (raw caller)"
  elif [[ "$AIRLOCK_GH" == "on" ]]; then
    v_skip "no gh login is mounted while GH=off" "GH=on for this project"
  else
    if v_run "test -s /home/dev/.config/gh/hosts.yml"; then
      v_fail "no gh login is mounted while GH=off" \
        "/home/dev/.config/gh/hosts.yml has content — a token the project did not ask for"
    else
      v_pass "no gh login is mounted while GH=off"
    fi
  fi

  echo
  echo "── the effective egress whitelist ($wl_now) ─────────────────────────"
  wl_domains "$wl_now" | sed 's/^/      /'
  echo "      ($(wl_domains "$wl_now" | grep -c . | tr -d ' ') domain(s); everything else is denied)"

  echo
  if [[ "$VERIFY_FAIL" -eq 0 ]]; then
    echo "verify: all probes passed."
  else
    echo "verify: at least one probe FAILED — the sandbox is not holding what it claims." >&2
  fi
  exit "$VERIFY_FAIL"
}
