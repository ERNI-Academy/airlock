# shellcheck shell=bash
# airlock-backends.sh — where the backends plugin lives. Sourced by bin/sandbox-run
# (which loads the plugin) and bin/airlock (which only reads its names, in a
# subshell). Functions only; needs HARNESS_DIR.
#
# The plugin is host-side code: its path comes from the host's environment or the
# kit checkout, never from a project config. AIRLOCK_BACKENDS wins; otherwise
# backends.sh at the kit root (git-ignored; start from templates/backends.example.sh).
# Callers use it only if the file exists — no plugin is a normal state.
backends_file() {
  printf '%s' "${AIRLOCK_BACKENDS:-$HARNESS_DIR/backends.sh}"
}
