# shellcheck shell=bash
# Test helpers. Each test runs in its own subshell with a throwaway HOME, so
# nothing touches the real ~/.claude. Tests never call DeepSeek or Claude.

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SKIP_RC=77

# Keep git deterministic: no system or user config leaks into tests.
export GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0
unset OC_MODEL

fail() { printf '    %s\n' "$*" >&2; exit 1; }
skip() { printf '    skip: %s\n' "$*" >&2; exit "$SKIP_RC"; }

# new_home: fresh HOME with the pipeline installed from this checkout.
# Sets BC (the installed CLI) and CFG (the config path) for the tests.
# shellcheck disable=SC2034
new_home() {
  HOME=$(mktemp -d "${T_ROOT:?}/home.XXXXXX")
  chmod 700 "$HOME"
  export HOME XDG_CONFIG_HOME="$HOME/.config"
  "$REPO_ROOT/install.sh" >"$HOME/.install.log" 2>&1 || { cat "$HOME/.install.log" >&2; fail "install failed"; }
  BC="$HOME/.claude/bin/build-config"
  CFG="$HOME/.claude/build/config.json"
}

# empty_home: fresh HOME with nothing installed.
empty_home() {
  HOME=$(mktemp -d "${T_ROOT:?}/home.XXXXXX")
  chmod 700 "$HOME"
  export HOME XDG_CONFIG_HOME="$HOME/.config"
}

# run <cmd...>: capture stdout, stderr and exit code into OUT, ERR, RC.
run() {
  local o e
  o=$(mktemp "$T_ROOT/out.XXXXXX"); e=$(mktemp "$T_ROOT/err.XXXXXX")
  set +e
  "$@" >"$o" 2>"$e"
  RC=$?
  OUT=$(<"$o"); ERR=$(<"$e")
  rm -f "$o" "$e"
}

expect_rc() {
  [ "$RC" = "$1" ] || fail "expected exit $1, got $RC; stderr: ${ERR:0:400}"
}
expect_err() {
  [[ $ERR == *"$1"* ]] || fail "stderr missing '$1'; got: ${ERR:0:400}"
}
expect_out() {
  [[ $OUT == *"$1"* ]] || fail "stdout missing '$1'; got: ${OUT:0:400}"
}
expect_nowhere() {
  [[ $OUT$ERR != *"$1"* ]] || fail "output must not contain '$1'"
}

# cfg_edit '<jq filter>': rewrite config.json in place, keeping its mode.
cfg_edit() {
  local tmp
  tmp=$(mktemp "$CFG.XXXXXX")
  jq "$1" "$CFG" >"$tmp" || fail "cfg_edit filter failed: $1"
  chmod 600 "$tmp"; mv -f "$tmp" "$CFG"
}

# cfg_raw '<text>': replace config.json with exact text.
cfg_raw() {
  printf '%s' "$1" >"$CFG"; chmod 600 "$CFG"
}

# allow_remote <normalized>: add an allowlist entry.
allow_remote() {
  cfg_edit ".repo_allowlist.repos += [{\"remote\": \"$1\", \"added\": \"2026-09-25\"}]"
}

# make_repo <url...>: git repo with origin (and extra remotes r1, r2...).
make_repo() {
  local dir i=0
  dir=$(mktemp -d "$T_ROOT/repo.XXXXXX")
  git init -q "$dir"
  for u in "$@"; do
    if (( i == 0 )); then git -C "$dir" remote add origin "$u"; else git -C "$dir" remote add "r$i" "$u"; fi
    i=$((i + 1))
  done
  printf '%s\n' "$dir"
}
