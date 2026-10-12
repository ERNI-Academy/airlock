#!/usr/bin/env bash
#
# airlock-gc.sh — owns the garbage collection of per-project sandbox images: which
# `harness-<slug>-<hash6>-dev` images (and which dangling layers of them) are dead
# weight on the Docker VM disk, and removing them.
#
# Why: every project ever launched leaves a ~5 GB image behind, keyed by the same
# slug + path-hash as its control dir, and nothing ever removed one. A rebuild with a
# different stack or harness leaves the previous image behind as a dangling `<none>`
# layer set. Left alone, that fills the Docker VM disk.
#
# The decision is a PURE function (gc_classify) over a text listing, so the offline
# tests can feed it a fake `docker images` and a temp AIRLOCK_HOME. Everything that
# talks to docker is in gc_list / gc_sizes / gc_remove / gc_vm_free_kb.
#
# Sourced, defines functions only. Callers provide $NAME and $AIRLOCK_HOME (from
# airlock-config.sh).
#
# Exposes:
#   gc_stamp <ctl>                       write <ctl>/last-launch (epoch seconds)
#   gc_last_launch <ctl>                 epoch of the project's last launch (or best guess)
#   gc_project_days <ctl>                the project's GC_DAYS pin, or empty
#   gc_classify <mode> <now> <days> <all_stale> <exempt repos…>   stdin listing → plan
#   gc_list                              the live listing, from docker
#   gc_main [--dry-run] [--days N] [--all-stale]          the `airlock gc` verb
#   gc_auto <current repo…>              the launch-time sweep (orphaned + stale only)
#
# Labels (set by docker-compose.yml's `build.labels`, so every Dockerfile carries
# them without a layer of its own):
#   io.airlock.sandbox=1
#   io.airlock.project=<COMPOSE_PROJECT_NAME>
#   io.airlock.launcher=airlock|harness   airlock = built through bin/airlock
#   io.airlock.home=<AIRLOCK_HOME>        which control-dir root it belongs to
# Images from before the labels have none of them ("pre-label"): the manual verb
# judges those by name alone, the automatic sweep leaves them alone.

GC_DEFAULT_DAYS=30
GC_FLOOR_GB=10          # warn before a launch when the Docker VM has less free than this

# The image name compose gives a project's dev service, and the control-dir name it
# pairs with: harness-<slug>-<hash6>-dev  ↔  $AIRLOCK_HOME/<slug>-<hash6>.
GC_NAME_RE='^harness-(.+-[0-9a-f]{6})-dev$'

gc_mtime() {   # <path> → epoch mtime, or nothing
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
}

# RFC 3339 (docker's .Created) → epoch seconds. BSD date first, GNU date second.
# The fractional part and the zone are dropped: a few hours either way is noise
# against a threshold measured in days.
gc_iso_epoch() {
  local s="${1:0:19}"
  date -j -u -f '%Y-%m-%dT%H:%M:%S' "$s" +%s 2>/dev/null \
    || date -u -d "${s/T/ }" +%s 2>/dev/null \
    || echo 0
}

gc_stamp() {   # <ctl>
  date +%s > "$1/last-launch" 2>/dev/null || true
}

# The newest of: the launch stamp, the files a launch writes, the dir itself. Before
# the stamp existed there is no exact answer, so take the most recent sign of life —
# the conservative direction (a project looks fresher, never staler, than it is).
gc_last_launch() {   # <ctl>
  local c="$1" best=0 v f
  if [[ -f "$c/last-launch" ]]; then
    v="$(head -1 "$c/last-launch" 2>/dev/null | tr -cd '0-9')"
    [[ -n "$v" ]] && { echo "$v"; return 0; }
  fi
  for f in "$c/whitelist.applied" "$c/whitelist.txt" "$c/config" "$c"; do
    v="$(gc_mtime "$f")"
    [[ -n "$v" && "$v" -gt "$best" ]] && best="$v"
  done
  echo "$best"
}

# A project's own GC_DAYS, read as data from its config (no full parse: this runs
# over OTHER projects' configs, and one broken config must not stop the sweep).
# Digits only; anything else counts as unset.
gc_project_days() {   # <ctl>
  local v
  [[ -f "$1/config" ]] || return 0
  v="$(sed -nE "s/^[[:space:]]*(export[[:space:]]+)?GC_DAYS=[\"']?([0-9]+)[\"']?[[:space:]]*(#.*)?$/\2/p" "$1/config" 2>/dev/null | tail -1)"
  printf '%s' "$v"
}

# ── the decision ──────────────────────────────────────────────────────────────
# stdin, one image per line:   ref|id|containers|created_epoch|launcher|home|cproj
#   ref        repo:tag, or <none>:<none> for a dangling image
#   containers how many containers (running or stopped) use it
#   launcher   the io.airlock.launcher label (empty = pre-label image)
#   home       the io.airlock.home label
#   cproj      compose's own com.docker.compose.project label when its service label
#              is `dev` — how a PRE-label dangling sandbox layer is still recognised
# stdout, one line per image the rules have an opinion on:
#   remove|<kind>|<ref>|<id>|<reason>      kind = orphaned | stale | dangling
#   skip|<kind>|<ref>|<id>|<reason>
# Images that are neither named like a sandbox nor labelled by airlock produce no
# line at all: scripted builds, registry images, other projects' builds are not ours.
#
#   mode       manual (the verb) | auto (the launch-time sweep: no dangling, no
#              pre-label images, no images from another AIRLOCK_HOME)
#   days       default age threshold; 0 disables the age rule
#   all_stale  1 = every other airlock project counts as stale, whatever its age
#   exempt     repo names never removed (the project being launched / the cwd's)
gc_classify() {
  local mode="$1" now="$2" days="$3" all_stale="$4"; shift 4
  local exempt=" $* " ref id ctr created launcher home cproj repo name ctl pin thr last age kind
  while IFS='|' read -r ref id ctr created launcher home cproj; do
    [[ -n "$ref" ]] || continue
    repo="${ref%:*}"
    ctr="${ctr:-0}"; created="${created:-0}"
    # Dangling: only ours (labelled by an airlock launch under THIS home), only by hand.
    # A pre-label one is recognised by compose's project label carrying the sandbox
    # name shape (harness-<slug>-<hash6>, service dev): untagged, so garbage whoever
    # built it — but still only by hand.
    if [[ "$repo" == "<none>" ]]; then
      [[ "$mode" == "manual" ]] || continue
      if [[ -z "$launcher" && "$cproj-dev" =~ $GC_NAME_RE ]]; then
        if [[ "$ctr" -gt 0 ]]; then
          echo "skip|dangling|$ref|$id|$ctr container(s) still use it"; continue
        fi
        echo "remove|dangling|$ref|$id|untagged pre-label leftover of $cproj"; continue
      fi
      [[ "$launcher" == "airlock" ]] || continue
      if [[ "$home" != "$AIRLOCK_HOME" ]]; then
        echo "skip|dangling|$ref|$id|built under AIRLOCK_HOME=$home"; continue
      fi
      if [[ "$ctr" -gt 0 ]]; then
        echo "skip|dangling|$ref|$id|$ctr container(s) still use it"; continue
      fi
      echo "remove|dangling|$ref|$id|untagged leftover of an earlier sandbox build"
      continue
    fi
    [[ "$repo" =~ $GC_NAME_RE ]] || continue
    name="${BASH_REMATCH[1]}"
    ctl="$AIRLOCK_HOME/$name"
    kind=stale; [[ -d "$ctl" ]] || kind=orphaned
    case "$exempt" in *" $repo "*)
      echo "skip|$kind|$ref|$id|the current project's image"; continue ;;
    esac
    case "$launcher" in
      harness)
        echo "skip|$kind|$ref|$id|built by raw bin/harness (scripts), not by airlock"; continue ;;
      airlock)
        if [[ "$home" != "$AIRLOCK_HOME" ]]; then
          echo "skip|$kind|$ref|$id|built under AIRLOCK_HOME=$home"; continue
        fi ;;
      "")
        if [[ "$mode" == "auto" ]]; then
          echo "skip|$kind|$ref|$id|pre-label image (only 'airlock gc' judges those)"; continue
        fi ;;
      *) echo "skip|$kind|$ref|$id|unknown launcher label '$launcher'"; continue ;;
    esac
    if [[ "$ctr" -gt 0 ]]; then
      echo "skip|$kind|$ref|$id|$ctr container(s) still use it ('airlock down' in that project first)"; continue
    fi
    if [[ "$kind" == "orphaned" ]]; then
      echo "remove|orphaned|$ref|$id|no control dir $ctl"; continue
    fi
    pin="$(gc_project_days "$ctl")"
    if [[ "$pin" == "0" ]]; then
      echo "skip|stale|$ref|$id|pinned by GC_DAYS=0 in its config"; continue
    fi
    last="$(gc_last_launch "$ctl")"
    # An image built more recently than every other sign of life still counts as one.
    [[ "$created" -gt "$last" ]] && last="$created"
    age=$(( (now - last) / 86400 ))
    if [[ "$all_stale" == "1" ]]; then
      echo "remove|stale|$ref|$id|--all-stale (last launch ${age}d ago)"; continue
    fi
    if [[ "$days" == "0" ]]; then
      echo "skip|stale|$ref|$id|age rule off (--days 0); last launch ${age}d ago"; continue
    fi
    thr="${pin:-$days}"
    if [[ $(( now - last )) -gt $(( thr * 86400 )) ]]; then
      echo "remove|stale|$ref|$id|last launch ${age}d ago (> ${thr}d)"
    else
      echo "skip|stale|$ref|$id|fresh: last launch ${age}d ago (<= ${thr}d)"
    fi
  done
}

# ── talking to docker ─────────────────────────────────────────────────────────
# The listing gc_classify reads. One `docker images`, one `docker image inspect` for
# the images that could be ours, and one container lookup per such image (a stopped
# container pins its image too, and `docker rmi` without -f would refuse anyway).
gc_list() {
  local rows ids line repo tag id meta ref ctr created launcher home cproj csvc
  # Docker 29 leaves dangling images out of the plain listing, so ask for them too.
  rows="$(docker images --format '{{.Repository}}|{{.Tag}}|{{.ID}}' 2>/dev/null)" || return 1
  rows="$( { printf '%s\n' "$rows"
             docker images -f dangling=true --format '{{.Repository}}|{{.Tag}}|{{.ID}}' 2>/dev/null
           } | awk 'NF && !seen[$0]++' )"
  ids=""
  while IFS='|' read -r repo tag id; do
    [[ -n "$id" ]] || continue
    if [[ "$repo" == "<none>" || "$repo" =~ $GC_NAME_RE ]]; then ids="$ids $id"; fi
  done <<EOF
$rows
EOF
  [[ -n "$ids" ]] || return 0
  # shellcheck disable=SC2086 # the ids are hex words
  # `index .Config "Labels"`, not .Config.Labels: an image with no labels at all has
  # no such key, and the dotted form aborts the whole inspect on it.
  meta="$(docker image inspect -f '{{.Id}}|{{.Created}}|{{with index .Config "Labels"}}{{index . "io.airlock.launcher"}}|{{index . "io.airlock.home"}}|{{index . "com.docker.compose.project"}}|{{index . "com.docker.compose.service"}}{{else}}||||{{end}}' $ids 2>/dev/null)" || meta=""
  meta="$(printf '%s\n' "$meta" | sed 's/<no value>//g')"   # a missing label, via index
  while IFS='|' read -r repo tag id; do
    [[ -n "$id" ]] || continue
    [[ "$repo" == "<none>" || "$repo" =~ $GC_NAME_RE ]] || continue
    ref="$repo:$tag"
    line="$(printf '%s\n' "$meta" | grep -m1 "^sha256:$id" || true)"
    created="$(gc_iso_epoch "$(printf '%s' "$line" | cut -d'|' -f2)")"
    launcher="$(printf '%s' "$line" | cut -d'|' -f3)"
    home="$(printf '%s' "$line" | cut -d'|' -f4)"
    cproj="$(printf '%s' "$line" | cut -d'|' -f5)"
    csvc="$(printf '%s' "$line" | cut -d'|' -f6)"
    [[ "$csvc" == "dev" ]] || cproj=""
    # Not ours and dangling: no need to ask docker anything more about it.
    if [[ "$repo" == "<none>" && "$launcher" != "airlock" && -z "$cproj" ]]; then
      echo "$ref|$id|0|$created|$launcher|$home|"; continue
    fi
    ctr="$(docker ps -a -q --filter "ancestor=$id" 2>/dev/null | grep -c . || true)"
    echo "$ref|$id|${ctr:-0}|$created|$launcher|$home|$cproj"
  done <<EOF
$rows
EOF
}

# "5.253GB" → bytes. Docker prints decimal units (kB = 1000 B).
gc_to_bytes() {
  awk -v s="$1" 'BEGIN{
    n=s; sub(/[A-Za-z]+$/,"",n); u=s; sub(/^[0-9.]+/,"",u);
    m=1; if(u=="kB"||u=="KB")m=1e3; else if(u=="MB")m=1e6; else if(u=="GB")m=1e9; else if(u=="TB")m=1e12;
    printf "%.0f", n*m }'
}

gc_human() {   # bytes → "10.4 GB"
  awk -v b="${1:-0}" 'BEGIN{ if(b>=1e9) printf "%.1f GB", b/1e9; else printf "%.0f MB", b/1e6 }'
}

# id|bytes for every image, from `docker system df -v`: its UniqueSize is what
# removing that image frees (layers shared with a kept image stay on disk).
gc_sizes() {
  docker system df -v --format '{{range .Images}}{{.ID}}|{{.UniqueSize}}{{println}}{{end}}' 2>/dev/null \
    | while IFS='|' read -r id sz; do
        [[ -n "$id" ]] || continue
        printf '%s|%s\n' "${id#sha256:}" "$(gc_to_bytes "$sz")"
      done
}

gc_size_of() {   # <short id> <sizes listing> → bytes (0 if unknown)
  local v
  v="$(printf '%s\n' "$2" | grep -m1 "^$1" | cut -d'|' -f2)"
  echo "${v:-0}"
}

# Free KB on the Docker VM's data disk — only where that is cheap to ask: Colima,
# whose VM answers `colima ssh -- df` in ~0.2 s. Docker Desktop and remote daemons
# expose no free-space number short of running a container, so: nothing.
gc_vm_free_kb() {
  local ctx prof root
  command -v colima >/dev/null 2>&1 || return 1
  ctx="$(docker context show 2>/dev/null)" || return 1
  case "$ctx" in
    colima)   prof=default ;;
    colima-*) prof="${ctx#colima-}" ;;
    *) return 1 ;;
  esac
  root="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null)"; root="${root:-/var/lib/docker}"
  colima ssh -p "$prof" -- df -Pk "$root" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {print $4}' | grep .
}

gc_free_line() {   # → "Docker VM: 11.9 GB free" or nothing
  local kb
  kb="$(gc_vm_free_kb)" || return 0
  [[ -n "$kb" ]] && echo "Docker VM: $(gc_human $((kb * 1000))) free"
}

# Remove one planned image. Re-checks for a container first (one may have started
# since the listing), and never forces: `docker rmi` refusing is the right outcome.
gc_remove() {   # <ref> <id> <kind>
  local target="$1"
  case "$3|$1" in dangling\|*|*:\<none\>) target="$2" ;; esac
  if [[ -n "$(docker ps -a -q --filter "ancestor=$2" 2>/dev/null)" ]]; then
    echo "  skipped $1 — a container started using it" >&2; return 1
  fi
  docker rmi "$target" >/dev/null 2>&1
}

# ── the verb ──────────────────────────────────────────────────────────────────
gc_main() {
  local dry=0 days="$GC_DEFAULT_DAYS" all=0 plan sizes act kind ref id why b total=0 n=0 failed=0 here other
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run|-n) dry=1; shift ;;
      --days) days="${2:-}"; if [[ $# -ge 2 ]]; then shift 2; else shift; fi ;;
      --days=*) days="${1#--days=}"; shift ;;
      --all-stale) all=1; shift ;;
      -h|--help)
        echo "usage: $NAME gc [--dry-run] [--days N] [--all-stale]"
        echo "  removes per-project sandbox images: orphaned (no control dir), stale (no launch"
        echo "  in N days, default $GC_DEFAULT_DAYS; 0 = age rule off) and dangling airlock build leftovers."
        return 0 ;;
      *) echo "$NAME gc: unknown arg '$1' (--dry-run | --days N | --all-stale)" >&2; return 1 ;;
    esac
  done
  case "$days" in ''|*[!0-9]*) echo "$NAME gc: --days needs a number of days (0 = age rule off)" >&2; return 1 ;; esac
  command -v docker >/dev/null 2>&1 || { echo "$NAME gc: docker is not on PATH" >&2; return 1; }
  local listing
  listing="$(gc_list)" || { echo "$NAME gc: cannot list images — is the Docker daemon running?" >&2; return 1; }
  # The cwd's project is exempt like a launching one: running gc from inside a project
  # never removes that project's image. ctl_dir_for computes the name without
  # creating the dir.
  here="harness-$(basename "$(ctl_dir_for "$PWD")")-dev"
  plan="$(printf '%s\n' "$listing" | gc_classify manual "$(date +%s)" "$days" "$all" "$here")"
  sizes="$(gc_sizes)"
  local hdr="AIRLOCK_HOME=$AIRLOCK_HOME, days=$days"
  [[ "$all" == 1 ]] && hdr="$hdr, all-stale"
  if [[ "$dry" == 1 ]]; then echo "$NAME gc --dry-run ($hdr):"; else echo "$NAME gc ($hdr):"; fi
  if [[ -z "$plan" ]]; then
    echo "  no sandbox images found"
  fi
  while IFS='|' read -r act kind ref id why; do
    [[ -n "$act" ]] || continue
    b="$(gc_size_of "$id" "$sizes")"
    if [[ "$act" == "skip" ]]; then
      printf '  keep    %-9s %s (%s) — %s\n' "$kind" "$ref" "$id" "$why"; continue
    fi
    if [[ "$dry" == 1 ]]; then
      printf '  remove  %-9s %s (%s, %s) — %s\n' "$kind" "$ref" "$id" "$(gc_human "$b")" "$why"
      total=$((total + b)); n=$((n + 1)); continue
    fi
    if gc_remove "$ref" "$id" "$kind"; then
      printf '  removed %-9s %s (%s, %s) — %s\n' "$kind" "$ref" "$id" "$(gc_human "$b")" "$why"
      total=$((total + b)); n=$((n + 1))
    else
      printf '  FAILED  %-9s %s (%s) — docker rmi refused\n' "$kind" "$ref" "$id"; failed=$((failed + 1))
    fi
  done <<EOF
$plan
EOF
  if [[ "$dry" == 1 ]]; then
    echo "  would remove $n image(s), ~$(gc_human "$total") (unique size; layers shared with kept images stay)"
  else
    if [[ "$failed" -gt 0 ]]; then
      echo "  removed $n image(s), ~$(gc_human "$total"); $failed failed"
    else
      echo "  removed $n image(s), ~$(gc_human "$total")"
    fi
  fi
  # Untagged images that are NOT airlock build leftovers (pre-label sandbox builds,
  # other tools' rebuilds): reported, never removed — that is the user's call.
  other="$(printf '%s\n' "$listing" | awk -F'|' '$1 ~ /^<none>:/ && $5!="airlock" && $7==""' | grep -c . || true)"
  if [[ "${other:-0}" -gt 0 ]]; then
    echo "  $other other dangling image(s) not from a sandbox build (other tools) — left alone; 'docker image prune' removes all dangling images if you want them gone"
  fi
  gc_free_line | sed 's/^/  /'
  [[ "$failed" -eq 0 ]]
}

# ── the launch-time sweep ─────────────────────────────────────────────────────
# Orphaned + stale only, labelled images of THIS AIRLOCK_HOME only, the launching
# project exempt. Silent unless it removed something; never fails the launch.
gc_auto() {   # <exempt repo…>
  local plan sizes act kind ref id why b total=0 n=0 kb listing
  command -v docker >/dev/null 2>&1 || return 0
  listing="$(gc_list 2>/dev/null)" || return 0
  plan="$(printf '%s\n' "$listing" | gc_classify auto "$(date +%s)" "$GC_DEFAULT_DAYS" 0 "$@" | grep '^remove|' || true)"
  if [[ -n "$plan" ]]; then
    sizes="$(gc_sizes)"
    while IFS='|' read -r act kind ref id why; do
      [[ -n "$act" ]] || continue
      b="$(gc_size_of "$id" "$sizes")"
      if gc_remove "$ref" "$id" "$kind" 2>/dev/null; then total=$((total + b)); n=$((n + 1)); fi
    done <<EOF
$plan
EOF
    [[ "$n" -gt 0 ]] && echo "$NAME: gc removed $n orphaned/stale sandbox image(s) ($(gc_human "$total")) — '$NAME gc --dry-run' shows the rules"  >&2
  fi
  return 0
}

# Before a build: a full VM disk fails it halfway with a confusing error. Only where
# the free space is cheap to read (Colima); silent everywhere else.
gc_floor_warn() {
  local kb
  kb="$(gc_vm_free_kb 2>/dev/null)" || return 0
  [[ -n "$kb" ]] || return 0
  if [[ "$kb" -lt $((GC_FLOOR_GB * 1000000)) ]]; then
    echo "$NAME: WARNING — the Docker VM has only $(gc_human $((kb * 1000))) free (floor ${GC_FLOOR_GB} GB); a sandbox build can fail. '$NAME gc --dry-run', 'docker builder prune'." >&2
  fi
  return 0
}
