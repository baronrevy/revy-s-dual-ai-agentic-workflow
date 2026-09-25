# shellcheck shell=bash
# Script quality and schema checks required by the spec.

_shell_files() {
  printf '%s\n' "$REPO_ROOT/install.sh" "$REPO_ROOT/bin/build-config" "$REPO_ROOT/server-probe.sh"
  find "$REPO_ROOT/build" "$REPO_ROOT/tests" -name '*.sh' -type f
}

test_shellcheck_clean() {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  local out
  mapfile -t files < <(_shell_files)
  out=$(shellcheck -x -P "$REPO_ROOT/tests" "${files[@]}" 2>&1) || fail "shellcheck findings:
$out"
}

test_all_json_parses() {
  local f
  while IFS= read -r -d '' f; do
    jq empty "$f" 2>/dev/null || fail "invalid JSON: ${f#"$REPO_ROOT"/}"
  done < <(find "$REPO_ROOT" -name '*.json' -not -path '*/.git/*' -print0)
}

_py_jsonschema() {
  local py
  for py in /usr/bin/python3 python3; do
    if "$py" -c 'import jsonschema' 2>/dev/null; then printf '%s\n' "$py"; return 0; fi
  done
  return 1
}

test_schema_is_valid_draft_2020_12() {
  local py
  py=$(_py_jsonschema) || skip "python3-jsonschema not installed"
  "$py" - "$REPO_ROOT/build/config.schema.json" <<'EOF' || fail "schema rejected by jsonschema"
import json, sys
from jsonschema import Draft202012Validator
Draft202012Validator.check_schema(json.load(open(sys.argv[1])))
EOF
}

# The jq validator must agree with a real JSON Schema implementation on every
# schema-level case. (x-regex is a local extension, so regex cases are excluded.)
test_validator_agrees_with_reference() {
  local py f ours theirs doc
  py=$(_py_jsonschema) || skip "python3-jsonschema not installed"
  new_home
  local -a cases=(
    '.' '.surprise = 1' '.limits.round_cap = "3"' '.limits.round_cap = 0' '.limits.round_cap = 2.5'
    '.limits.worker_timeout_minutes = 481' 'del(.sandbox)' '.sandbox.fallback = "unsandboxed"'
    '.network.worker = "disabled"' '.network.gates_and_tests = "allowed"'
    '.notifications = {"provider": "ntfy"}' '.notifications = {"provider": "none", "x": 1}'
    '.notifications = {"provider": "ntfy", "server": "https://ntfy.sh", "credentials_file": "~/.config/c/n.env"}'
    '.repo_allowlist.repos = [{"remote": "github.com/o/r", "added": "2026-09-25"}]'
    '.repo_allowlist.repos = [{"remote": "GitHub.com/o/r", "added": "2026-09-25"}]'
    '.repo_allowlist.repos = [{"remote": "github.com/o/r"}]'
    '.toolchains = [{"id": "n", "components": [{"name": "node", "version": "24"}], "paths": ["~/.nvm/v"], "approved": "2026-09-25"}]'
    '.toolchains = [{"id": "n", "components": [], "paths": ["~/.nvm/v"], "approved": "2026-09-25"}]'
    '.toolchains = [{"id": "n", "components": [{"name": "node", "version": "24"}], "paths": ["rel"], "approved": "2026-09-25"}]'
    '.security_sensitive_paths = []' '.security_sensitive_paths = ["a", "a"]'
    '.circuit_breaker.max_same_state_resumes = 11' 'del(.circuit_breaker.max_automated_hours)'
    '.worker.model = "no-slash"' '.schema_version = 2'
  )
  for f in "${cases[@]}"; do
    doc=$(jq -c "$f" "$REPO_ROOT/build/config.default.json")
    ours=$(jq -n --slurpfile schema "$REPO_ROOT/build/config.schema.json" --slurpfile doc /dev/stdin \
             -f "$REPO_ROOT/build/lib/jsonschema.jq" <<<"$doc" | jq -r 'if length == 0 then "valid" else "invalid" end')
    theirs=$("$py" -c '
import json, sys
from jsonschema import Draft202012Validator
v = Draft202012Validator(json.load(open(sys.argv[1])))
print("valid" if v.is_valid(json.loads(sys.stdin.read())) else "invalid")
' "$REPO_ROOT/build/config.schema.json" <<<"$doc")
    [ "$ours" = "$theirs" ] || fail "disagree on '$f': ours=$ours reference=$theirs"
  done
}
