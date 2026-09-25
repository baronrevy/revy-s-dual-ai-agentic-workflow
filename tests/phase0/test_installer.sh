# shellcheck shell=bash
# Phase 0: the installer is safe to run twice, backs up what it replaces, and
# never overwrites the user's config.

_hashes() { find "$HOME/.claude" -type f -not -path '*/backups/*' -not -name '.install.log' -exec sha256sum {} + | sort; }
_backup_count() { find "$HOME/.claude/build/backups" -mindepth 1 -maxdepth 1 | wc -l; }

test_fresh_install_layout_and_modes() {
  new_home
  local d
  for d in "$HOME/.claude" "$HOME/.claude/bin" "$HOME/.claude/build" "$HOME/.claude/build/lib"; do
    [ "$(stat -c %a "$d")" = 700 ] || fail "$d mode $(stat -c %a "$d")"
  done
  [ "$(stat -c %a "$CFG")" = 600 ] || fail "config mode $(stat -c %a "$CFG")"
  [ -x "$BC" ] || fail "build-config not executable"
  cmp -s "$CFG" "$REPO_ROOT/build/config.default.json" || fail "config is not the default"
}

test_second_run_changes_nothing() {
  new_home
  local before
  before=$(_hashes)
  run "$REPO_ROOT/install.sh"
  expect_rc 0; expect_out "no changes"
  [ "$(_hashes)" = "$before" ] || fail "files changed on second run"
  [ "$(_backup_count)" = 0 ] || fail "second run created a backup"
}

test_existing_config_is_kept() {
  new_home
  cfg_edit '.limits.round_cap = 5'
  run "$REPO_ROOT/install.sh"
  expect_rc 0
  [ "$(jq .limits.round_cap "$CFG")" = 5 ] || fail "user config was overwritten"
}

test_loose_config_mode_is_tightened() {
  new_home
  chmod 664 "$CFG"
  run "$REPO_ROOT/install.sh"
  expect_rc 0; expect_out "tightened"
  [ "$(stat -c %a "$CFG")" = 600 ] || fail "mode not tightened"
}

test_changed_managed_file_is_backed_up_and_replaced() {
  new_home
  local lib="$HOME/.claude/build/lib/config.sh"
  printf '# old version\n' >>"$lib"
  run "$REPO_ROOT/install.sh"
  expect_rc 0; expect_out "backed up"
  cmp -s "$lib" "$REPO_ROOT/build/lib/config.sh" || fail "managed file not replaced"
  grep -rq '# old version' "$HOME/.claude/build/backups" || fail "old file not in backup"
}

test_settings_merged_not_replaced() {
  empty_home
  mkdir -m 700 "$HOME/.claude"
  printf '%s' '{"model":"opus","permissions":{"allow":["Bash(ls)"],"ask":["Edit(~/.claude/build/**)"]}}' \
    >"$HOME/.claude/settings.json"
  run "$REPO_ROOT/install.sh"
  expect_rc 0
  local s="$HOME/.claude/settings.json"
  [ "$(jq -r .model "$s")" = opus ] || fail "model setting lost"
  [ "$(jq -c .permissions.allow "$s")" = '["Bash(ls)"]' ] || fail "allow rules changed"
  [ "$(jq '.permissions.ask | length' "$s")" = 3 ] || fail "ask rules: $(jq -c .permissions.ask "$s")"
  [ "$(_backup_count)" = 1 ] || fail "settings.json was not backed up"
  run "$REPO_ROOT/install.sh"
  [ "$(jq '.permissions.ask | length' "$s")" = 3 ] || fail "ask rules duplicated on rerun"
  [ "$(_backup_count)" = 1 ] || fail "rerun made another backup"
}

test_invalid_settings_aborts_before_any_change() {
  empty_home
  mkdir -m 700 "$HOME/.claude"
  printf '{ not json' >"$HOME/.claude/settings.json"
  run "$REPO_ROOT/install.sh"
  [ "$RC" != 0 ] || fail "installer accepted invalid settings.json"
  [ "$(cat "$HOME/.claude/settings.json")" = '{ not json' ] || fail "settings.json was modified"
  [ ! -e "$HOME/.claude/build" ] || fail "installer changed things before aborting"
}

test_symlinked_targets_refused() {
  empty_home
  mkdir -m 700 "$HOME/.claude"
  printf '{}' >"$HOME/real-settings.json"
  ln -s "$HOME/real-settings.json" "$HOME/.claude/settings.json"
  run "$REPO_ROOT/install.sh"
  [ "$RC" != 0 ] || fail "installer wrote through a symlinked settings.json"
  empty_home
  mkdir -p "$HOME/elsewhere"
  ln -s "$HOME/elsewhere" "$HOME/.claude"
  run "$REPO_ROOT/install.sh"
  [ "$RC" != 0 ] || fail "installer installed through a symlinked ~/.claude"
}

test_group_writable_claude_dir_tightened() {
  empty_home
  mkdir "$HOME/.claude"; chmod 775 "$HOME/.claude"
  run "$REPO_ROOT/install.sh"
  expect_rc 0; expect_out "tightened"
  [ "$(stat -c %a "$HOME/.claude")" = 755 ] || fail "\$HOME/.claude mode $(stat -c %a "$HOME/.claude")"
}

test_writable_home_aborts() {
  empty_home
  chmod 777 "$HOME"
  run "$REPO_ROOT/install.sh"
  chmod 700 "$HOME"
  [ "$RC" != 0 ] || fail "installer ran with a world-writable home"
  expect_err "home directory is writable"
}
