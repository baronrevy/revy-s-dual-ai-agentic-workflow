# shellcheck shell=bash
# Phase 0: the config loader validates, and fails closed on anything wrong.

test_default_config_is_valid() {
  new_home
  run "$BC" validate
  expect_rc 0; expect_out "config OK"
}

test_get_returns_values() {
  new_home
  run "$BC" get limits.round_cap;           expect_rc 0; [ "$OUT" = 3 ] || fail "round_cap=$OUT"
  run "$BC" get limits.worker_timeout_minutes; [ "$OUT" = 60 ] || fail "timeout=$OUT"
  run "$BC" get worker.model;               [ "$OUT" = deepseek/deepseek-v4-pro ] || fail "model=$OUT"
  run "$BC" get notifications.provider;     [ "$OUT" = none ] || fail "notify=$OUT"
  run "$BC" get triage.small.allow_sensitive_paths; [ "$OUT" = false ] || fail "sensitive=$OUT"
  run "$BC" get circuit_breaker.max_transitions_per_task; [ "$OUT" = 40 ] || fail "breaker=$OUT"
  run "$BC" get no.such.key;                expect_rc 2
}

test_missing_config_refused() {
  new_home
  rm -f "$CFG"
  run "$BC" validate
  expect_rc 10
}

test_malformed_json_refused() {
  new_home
  cfg_raw '{"schema_version": 1,'
  run "$BC" validate; expect_rc 12
  cfg_raw ''
  run "$BC" validate; expect_rc 12
  cfg_raw '{} {}'
  run "$BC" validate; expect_rc 12
  cfg_raw '[1]'
  run "$BC" validate; expect_rc 12
}

test_duplicate_keys_refused() {
  new_home
  local raw
  raw=$(jq -c . "$CFG")
  cfg_raw "${raw%\}},\"limits\":{\"round_cap\":10,\"worker_timeout_minutes\":480}}"
  run "$BC" validate
  expect_rc 12; expect_err "duplicate keys"
}

test_unknown_keys_refused() {
  new_home
  cfg_edit '.surprise = 1'
  run "$BC" validate; expect_rc 14; expect_err 'unknown key "surprise"'
  new_home
  cfg_edit '.limits.round_cpa = 3'
  run "$BC" validate; expect_rc 14; expect_err 'unknown key "round_cpa"'
}

test_wrong_types_and_ranges_refused() {
  local f
  for f in '.limits.round_cap = "3"' '.limits.round_cap = 0' '.limits.round_cap = 11' \
           '.limits.round_cap = 2.5' '.limits.worker_timeout_minutes = 4' \
           '.limits.worker_timeout_minutes = 481' '.triage.small.max_files = -1' \
           '.circuit_breaker.max_transitions_per_task = 0' '.circuit_breaker.max_automated_hours = 49' \
           '.circuit_breaker.max_same_state_resumes = 0' 'del(.circuit_breaker)' 'del(.limits)'; do
    new_home
    cfg_edit "$f"
    run "$BC" validate
    [ "$RC" = 14 ] || fail "'$f' gave exit $RC, want 14"
  done
}

test_security_decisions_cannot_be_weakened() {
  local f
  for f in '.sandbox.fallback = "unsandboxed"' '.sandbox.kind = "none"' \
           '.network.gates_and_tests = "allowed"' '.network.worker = "anything"' \
           '.triage.small.allow_sensitive_paths = true' '.repo_allowlist.match = "origin_only"' \
           '.worker.provider = "other"'; do
    new_home
    cfg_edit "$f"
    run "$BC" validate
    [ "$RC" = 14 ] || fail "'$f' gave exit $RC, want 14"
  done
}

test_notifications_forms() {
  new_home
  cfg_edit '.notifications = {"provider": "email"}'
  run "$BC" validate; expect_rc 14
  cfg_edit '.notifications = {"provider": "ntfy"}'
  run "$BC" validate; expect_rc 14
  cfg_edit '.notifications = {"provider": "none", "server": "https://ntfy.sh"}'
  run "$BC" validate; expect_rc 14
  cfg_edit '.notifications = {"provider": "ntfy", "server": "http://ntfy.sh", "credentials_file": "~/.config/claude-build/ntfy.env"}'
  run "$BC" validate; expect_rc 14
  cfg_edit '.notifications = {"provider": "ntfy", "server": "https://ntfy.sh", "credentials_file": "~/.config/claude-build/ntfy.env"}'
  run "$BC" validate; expect_rc 0
}

test_sensitive_path_regexes_checked() {
  new_home
  cfg_edit '.security_sensitive_paths += ["("]'
  run "$BC" validate; expect_rc 14; expect_err "not a valid regular expression"
  new_home
  cfg_edit '.security_sensitive_paths += [""]'
  run "$BC" validate; expect_rc 14
  new_home
  cfg_edit '.security_sensitive_paths = []'
  run "$BC" validate; expect_rc 14
}

test_schema_version_rules() {
  new_home
  cfg_edit '.schema_version = 2'
  run "$BC" validate; expect_rc 13; expect_err "newer than this install supports"
  cfg_edit '.schema_version = 0'
  run "$BC" validate; expect_rc 13
  cfg_edit 'del(.schema_version)'
  run "$BC" validate; expect_rc 13
  cfg_edit '.schema_version = "1"'
  run "$BC" validate; expect_rc 13
}

test_unsafe_files_refused() {
  new_home
  chmod 664 "$CFG"
  run "$BC" validate; expect_rc 11; expect_err "writable by group or others"
  chmod 600 "$CFG"
  chmod 777 "$HOME/.claude/build"
  run "$BC" validate; expect_rc 11
  chmod 700 "$HOME/.claude/build"
  mv "$CFG" "$CFG.real"; ln -s "$CFG.real" "$CFG"
  run "$BC" validate; expect_rc 11; expect_err "refusing symlink"
}

test_config_owned_by_someone_else_refused() {
  [ "$(id -u)" = 0 ] || skip "needs root to chown"
  new_home
  chown nobody "$CFG"
  run "$BC" validate; expect_rc 11; expect_err "not owned by you or root"
}

test_tampered_or_missing_anchor_refused() {
  new_home
  local s="$HOME/.claude/build/config.schema.json" tmp
  tmp=$(mktemp "$s.XXXXXX")
  jq '.properties.limits.properties.round_cap.format = "anything"' "$s" >"$tmp"
  chmod 644 "$tmp"; mv -f "$tmp" "$s"
  run "$BC" validate; expect_rc 16; expect_err "unsupported keyword"
  new_home
  rm -f "$HOME/.claude/build/config.schema.json"
  run "$BC" validate; expect_rc 16
  new_home
  rm -f "$HOME/.claude/build/lib/jsonschema.jq"
  run "$BC" validate; expect_rc 16
  new_home
  local lib="$HOME/.claude/build/lib/config.sh"
  mv "$lib" "$lib.real"; ln -s "$lib.real" "$lib"
  run "$BC" validate; expect_rc 16
  new_home
  chmod 666 "$HOME/.claude/build/lib/config.sh"
  run "$BC" validate; expect_rc 11
}

test_validator_crash_is_not_valid() {
  new_home
  # A validator that dies must never read as "no errors".
  printf 'error("boom")\n' >"$HOME/.claude/build/lib/jsonschema.jq"
  run "$BC" validate; expect_rc 16
  printf '"not an array"\n' >"$HOME/.claude/build/lib/jsonschema.jq"
  run "$BC" validate; expect_rc 16
}

test_toolchain_paths() {
  local p
  new_home
  cfg_edit '.toolchains = [{"id":"node-24.16.0","components":[{"name":"node","version":"24.16.0"}],
             "paths":["~/.nvm/versions/node/v24.16.0","~/.cargo/bin","/usr/lib/go"],"approved":"2026-09-25"}]'
  run "$BC" validate; expect_rc 0
  # shellcheck disable=SC2088  # literal ~ paths, as they appear in the config
  for p in '~' '~/.cargo' '~/go' '/' '/home' '/etc' '~/.ssh/keys' '~/.config/opencode/x' \
           '~/.local/share/opencode/bin' '~/.cargo/credentials.toml' '~/a/../b' '~/a/./b' '~/.nvm/.npmrc/x'; do
    new_home
    cfg_edit ".toolchains = [{\"id\":\"t\",\"components\":[{\"name\":\"t\",\"version\":\"1\"}],\"paths\":[\"$p\"],\"approved\":\"2026-09-25\"}]"
    run "$BC" validate
    # 14 when the schema already rejects the form, 15 for the semantic rules.
    [ "$RC" = 14 ] || [ "$RC" = 15 ] || fail "path '$p' gave exit $RC, want 14 or 15"
  done
  new_home
  cfg_edit '.toolchains = [{"id":"t","components":[{"name":"t","version":"1"}],"paths":["relative/dir"],"approved":"2026-09-25"}]'
  run "$BC" validate; expect_rc 14
}

test_allowlist_entries_must_be_normalized() {
  local r
  for r in 'GitHub.com/o/r' 'github.com/o/r.git' 'https://github.com/o/r' 'github.com/o/r/'; do
    new_home
    cfg_edit ".repo_allowlist.repos = [{\"remote\":\"$r\",\"added\":\"2026-09-25\"}]"
    run "$BC" validate
    [ "$RC" = 14 ] || [ "$RC" = 15 ] || fail "remote '$r' gave exit $RC, want 14 or 15"
  done
  new_home
  allow_remote github.com/o/r; allow_remote github.com/o/r
  run "$BC" validate; expect_rc 15; expect_err "duplicate remotes"
}

test_oc_model_override() {
  new_home
  OC_MODEL=deepseek/deepseek-v4-flash run "$BC" get worker.model
  expect_rc 0; [ "$OUT" = deepseek/deepseek-v4-flash ] || fail "override not applied: $OUT"
  OC_MODEL='deepseek/x; rm -rf ~' run "$BC" get worker.model
  expect_rc 15
}

test_migration_chain_fails_closed() {
  new_home
  # Simulate a newer loader (version 2) with no 1-to-2 migration installed.
  sed -i 's/^BCFG_SUPPORTED_VERSION=1$/BCFG_SUPPORTED_VERSION=2/' "$HOME/.claude/build/lib/config.sh"
  run "$BC" validate; expect_rc 13; expect_err "no safe migration from version 1"
}
