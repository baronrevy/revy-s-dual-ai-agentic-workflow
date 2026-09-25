# shellcheck shell=bash
# Phase 0: D1. A repo not in the allowlist is refused before anything reaches the worker.

test_normalize_accepts_common_forms() {
  new_home
  local pair in want
  for pair in \
    'git@github.com:Owner/Repo.git|github.com/Owner/Repo' \
    'https://github.com/owner/repo|github.com/owner/repo' \
    'https://user:hunter2@GitHub.com/owner/repo.git/|github.com/owner/repo' \
    'ssh://git@github.com:22/owner/repo.git|github.com/owner/repo' \
    'ssh://git@gitlab.example.com:2222/group/sub/repo.git|gitlab.example.com/group/sub/repo' \
    'git://host.example/a/b|host.example/a/b' \
    'https://host.example//a//b/|host.example/a/b' \
    'host.example:a/b|host.example/a/b'; do
    in=${pair%%|*}; want=${pair#*|}
    run "$BC" normalize-remote "$in"
    { [ "$RC" = 0 ] && [ "$OUT" = "$want" ]; } || fail "'$in' -> '$OUT' (exit $RC), want '$want'"
  done
}

test_normalize_rejects_unsafe_forms() {
  new_home
  local u
  for u in '/srv/git/repo.git' 'file:///srv/repo' './rel' '../rel' '' 'https://host/a/../b' \
         'ftp://host/a' 'https://[::1]/a' 'git@host:' 'https://host' 'https://host/a b' 'plainword'; do
    run "$BC" normalize-remote "$u"
    [ "$RC" != 0 ] || fail "'$u' was accepted as '$OUT'"
  done
}

test_listed_repo_allowed() {
  new_home
  allow_remote github.com/o/r
  local repo
  repo=$(make_repo git@github.com:o/r.git)
  run "$BC" check-repo "$repo"
  expect_rc 0; expect_out "allowed"
}

test_unlisted_repo_refused() {
  new_home
  allow_remote github.com/o/r
  local repo
  repo=$(make_repo git@github.com:o/other.git)
  run "$BC" check-repo "$repo"
  expect_rc 20; expect_err "github.com/o/other is not in repo_allowlist"
}

test_empty_allowlist_refuses_everything() {
  new_home
  local repo
  repo=$(make_repo git@github.com:o/r.git)
  run "$BC" check-repo "$repo"
  expect_rc 20
}

test_repo_without_remotes_refused() {
  new_home
  local repo
  repo=$(make_repo)
  run "$BC" check-repo "$repo"
  expect_rc 20; expect_err "no remotes"
}

test_not_a_repo_refused() {
  new_home
  run "$BC" check-repo "$(mktemp -d "$T_ROOT/plain.XXXXXX")"
  expect_rc 20; expect_err "not inside a git work tree"
}

test_any_unlisted_remote_refuses() {
  new_home
  allow_remote github.com/o/r
  local repo
  repo=$(make_repo git@github.com:o/r.git https://gitlab.com/else/where.git)
  run "$BC" check-repo "$repo"
  expect_rc 20; expect_err "gitlab.com/else/where"
}

test_unlisted_push_url_refuses() {
  new_home
  allow_remote github.com/o/r
  local repo
  repo=$(make_repo git@github.com:o/r.git)
  git -C "$repo" remote set-url --push origin git@evil.example:o/r.git
  run "$BC" check-repo "$repo"
  expect_rc 20; expect_err "evil.example/o/r"
}

test_insteadof_rewrite_is_what_counts() {
  new_home
  allow_remote github.com/o/r
  local repo
  # Looks allowlisted, but git would actually send to evil.example.
  repo=$(make_repo https://github.com/o/r.git)
  git -C "$repo" config url."https://evil.example/".insteadOf "https://github.com/"
  run "$BC" check-repo "$repo"
  expect_rc 20; expect_err "evil.example/o/r"
  # And the reverse: a shorthand that rewrites to an allowlisted host is fine.
  repo=$(make_repo gh:o/r)
  git -C "$repo" config url."https://github.com/".insteadOf "gh:"
  run "$BC" check-repo "$repo"
  expect_rc 0
}

test_submodules_must_be_listed() {
  new_home
  allow_remote github.com/o/r
  local repo
  repo=$(make_repo git@github.com:o/r.git)
  git config -f "$repo/.gitmodules" submodule.lib.url https://github.com/third/party.git
  run "$BC" check-repo "$repo"
  expect_rc 20; expect_err "github.com/third/party"
  allow_remote github.com/third/party
  run "$BC" check-repo "$repo"
  expect_rc 0
  git config -f "$repo/.gitmodules" submodule.rel.url ../sibling.git
  run "$BC" check-repo "$repo"
  expect_rc 20; expect_err "relative URL"
}

test_nested_gitmodules_checked() {
  new_home
  allow_remote github.com/o/r
  local repo
  repo=$(make_repo git@github.com:o/r.git)
  mkdir -p "$repo/vendor/lib"
  git config -f "$repo/vendor/lib/.gitmodules" submodule.deep.url https://example.org/deep/dep
  run "$BC" check-repo "$repo"
  expect_rc 20; expect_err "example.org/deep/dep"
}

test_credentials_never_printed() {
  new_home
  local repo
  repo=$(make_repo https://alice:hunter2secret@evil.example/o/r.git)
  git -C "$repo" remote add r2 'https://bob:tok_abc123@bad form/x'
  run "$BC" check-repo "$repo"
  expect_rc 20
  expect_nowhere hunter2secret; expect_nowhere tok_abc123; expect_nowhere alice
}

test_invalid_config_blocks_check_repo() {
  new_home
  allow_remote github.com/o/r
  local repo
  repo=$(make_repo git@github.com:o/r.git)
  cfg_edit '.limits.round_cap = 99'
  run "$BC" check-repo "$repo"
  expect_rc 14
  rm -f "$CFG"
  run "$BC" check-repo "$repo"
  expect_rc 10
}

# The Phase 0 "done when": a refused repo sends nothing to the worker.
# stub-handoff.sh stands in for the Phase 1 wrapper; opencode is a fake that
# records whatever it receives.
_handoff_setup() {
  new_home
  FAKEBIN="$T_ROOT/fakebin.$RANDOM"; mkdir -p "$FAKEBIN"
  SENT="$T_ROOT/sent.$RANDOM"
  cat >"$FAKEBIN/opencode" <<EOF
#!/usr/bin/env bash
mkdir -p "$SENT"; printf '%s\n' "\$*" >"$SENT/args"
while [ \$# -gt 0 ]; do [ "\$1" = --file ] && cat "\$2" >"$SENT/spec"; shift; done
EOF
  chmod +x "$FAKEBIN/opencode"
  SPEC="$T_ROOT/spec.$RANDOM.md"
  printf 'SECRET SPEC TEXT %s\n' "$RANDOM" >"$SPEC"
}

test_refused_repo_sends_nothing() {
  _handoff_setup
  local repo
  repo=$(make_repo git@github.com:o/unlisted.git)
  PATH="$FAKEBIN:$PATH" run "$REPO_ROOT/tests/phase0/stub-handoff.sh" "$repo" "$SPEC"
  expect_rc 20
  [ ! -e "$SENT" ] || fail "worker was invoked for a refused repo"
}

test_allowed_repo_reaches_worker() {
  _handoff_setup
  allow_remote github.com/o/r
  local repo
  repo=$(make_repo git@github.com:o/r.git)
  PATH="$FAKEBIN:$PATH" run "$REPO_ROOT/tests/phase0/stub-handoff.sh" "$repo" "$SPEC"
  expect_rc 0
  cmp -s "$SPEC" "$SENT/spec" || fail "positive control: spec did not reach the fake worker"
}
