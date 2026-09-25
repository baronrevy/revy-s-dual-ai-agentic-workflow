#!/usr/bin/env bash
# Installer for the Claude Code + OpenCode build pipeline (Phase 0: config).
# Safe to run any number of times: unchanged files are left alone, every file it
# replaces is backed up first, and an existing config.json is never overwritten.
set -euo pipefail

SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
: "${HOME:?HOME is not set}"
CLAUDE="$HOME/.claude"
BUILD="$CLAUDE/build"
BIN="$CLAUDE/bin"
SETTINGS="$CLAUDE/settings.json"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP="$BUILD/backups/$STAMP"
# Claude Code asks before its file tools edit the pipeline's trust anchors.
ASK_RULES='["Edit(~/.claude/build/**)","Edit(~/.claude/bin/**)","Edit(~/.claude/settings.json)"]'

changed=0
say() { printf '  %-11s %s\n' "$1" "${2/#$HOME/\~}"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

backup() {
  local f=$1 rel
  rel=${f#"$HOME"/}
  (umask 077 && mkdir -p -- "$BACKUP/$(dirname "$rel")")
  cp -p -- "$f" "$BACKUP/$rel"
  say "backed up" "$f -> $BACKUP/$rel"
}

mode_of() { stat -c '%a' -- "$1"; }

ensure_dir() {
  local d=$1 m
  if [ -L "$d" ]; then die "$d is a symlink; refusing to install through it"; fi
  if [ ! -d "$d" ]; then
    mkdir -m 700 -- "$d"; say "created" "$d/"; changed=1; return
  fi
  m=$(mode_of "$d")
  if (( 8#$m & 8#022 )); then
    chmod go-w -- "$d"; say "tightened" "$d/ (was mode $m)"; changed=1
  fi
}

install_file() {
  local src=$1 dest=$2 mode=$3 tmp
  if [ -L "$dest" ]; then die "$dest is a symlink; remove it and re-run"; fi
  if [ -f "$dest" ] && cmp -s -- "$src" "$dest" && [ "$(mode_of "$dest")" = "$mode" ]; then
    return
  fi
  [ -f "$dest" ] && backup "$dest"
  tmp=$(mktemp "$dest.XXXXXX")
  cp -- "$src" "$tmp"; chmod "$mode" -- "$tmp"; mv -f -- "$tmp" "$dest"
  say "installed" "$dest"; changed=1
}

# ---- preflight: check everything before changing anything ----------------
echo "Preflight"
(( BASH_VERSINFO[0] >= 4 )) || die "bash 4 or newer is required"
for t in jq git stat cmp mktemp; do
  command -v "$t" >/dev/null 2>&1 || die "$t is required (Debian: sudo apt install $t)"
done
stat -c '%a' / >/dev/null 2>&1 || die "GNU stat is required"
home_mode=$(mode_of "$HOME")
if (( 8#$home_mode & 8#022 )); then
  die "your home directory is writable by group or others (mode $home_mode); fix with: chmod go-w ~"
fi
if [ -L "$SETTINGS" ]; then die "$SETTINGS is a symlink; refusing to edit it"; fi
if [ -e "$SETTINGS" ]; then
  jq -e 'type == "object" and ((.permissions // {}) | type == "object")
         and ((.permissions.ask // []) | type == "array")' "$SETTINGS" >/dev/null 2>&1 ||
    die "$SETTINGS is not valid JSON with the expected shape; fix it first (nothing was changed)"
fi
echo "  ok"

# ---- install --------------------------------------------------------------
echo "Installing"
for d in "$CLAUDE" "$BIN" "$BUILD" "$BUILD/lib" "$BUILD/migrations" "$BUILD/migrations/config" "$BUILD/backups"; do
  ensure_dir "$d"
done

install_file "$SRC/build/config.schema.json" "$BUILD/config.schema.json" 644
install_file "$SRC/build/lib/jsonschema.jq"  "$BUILD/lib/jsonschema.jq"  644
install_file "$SRC/build/lib/config.sh"      "$BUILD/lib/config.sh"      644
install_file "$SRC/bin/build-config"         "$BIN/build-config"         755
for m in "$SRC"/build/migrations/config/*.jq; do
  [ -e "$m" ] || continue
  install_file "$m" "$BUILD/migrations/config/$(basename "$m")" 644
done

cfg="$BUILD/config.json"
if [ -L "$cfg" ]; then
  die "$cfg is a symlink; replace it with a regular file and re-run"
elif [ ! -e "$cfg" ]; then
  install_file "$SRC/build/config.default.json" "$cfg" 600
else
  m=$(mode_of "$cfg")
  if [ "$m" != 600 ]; then chmod 600 -- "$cfg"; say "tightened" "$cfg (was mode $m)"; changed=1; fi
fi

# settings.json: add the ask rules, keep everything else as it is.
if [ -e "$SETTINGS" ]; then current=$(cat -- "$SETTINGS"); else current='{}'; fi
merged=$(jq --argjson rules "$ASK_RULES" '
  .permissions = (.permissions // {})
  | .permissions.ask = (reduce $rules[] as $r (.permissions.ask // [];
      if any(.[]; . == $r) then . else . + [$r] end))' <<<"$current")
if [ ! -e "$SETTINGS" ] || [ "$(jq -S . <<<"$current")" != "$(jq -S . <<<"$merged")" ]; then
  [ -e "$SETTINGS" ] && backup "$SETTINGS"
  tmp=$(mktemp "$SETTINGS.XXXXXX")
  printf '%s\n' "$merged" >"$tmp"
  if [ -e "$SETTINGS" ]; then chmod "$(mode_of "$SETTINGS")" -- "$tmp"; else chmod 600 -- "$tmp"; fi
  mv -f -- "$tmp" "$SETTINGS"
  say "updated" "$SETTINGS (permissions.ask)"; changed=1
fi

(( changed )) || echo "  no changes (already installed)"

# ---- verify ---------------------------------------------------------------
echo "Verifying"
if "$BIN/build-config" validate; then
  echo "Done. Run ~/.claude/bin/build-config --help to see commands."
else
  rc=$?
  echo "install.sh: the config failed validation (exit $rc). Fix it; handoff stays blocked until it passes." >&2
  exit "$rc"
fi
