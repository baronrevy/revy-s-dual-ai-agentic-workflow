# shellcheck shell=bash
# Config loader for the build pipeline. Source this file; do not execute it.
#
# Interface (every later phase uses only these):
#   bcfg_load                  validate and load ~/.claude/build/config.json into BCFG_JSON
#   bcfg_get <key.path>        print one value (strings raw, everything else as compact JSON)
#   bcfg_normalize_remote <u>  print a remote URL in allowlist form, or fail
#   bcfg_check_repo <dir>      0 if every remote and submodule URL of <dir> is allowlisted
#
# Fail closed: any problem returns non-zero and the caller must stop. Exit codes:
#   10 config missing          11 unsafe file or directory   12 not valid JSON
#   13 unsupported version     14 fails the schema           15 fails a semantic rule
#   16 internal error          20 repo refused
# Messages go to stderr and never contain raw remote URLs, which may carry credentials.

BCFG_SUPPORTED_VERSION=1
BCFG_E_MISSING=10
BCFG_E_UNSAFE=11
BCFG_E_PARSE=12
BCFG_E_VERSION=13
BCFG_E_SCHEMA=14
BCFG_E_SEMANTIC=15
BCFG_E_INTERNAL=16
BCFG_E_REFUSED=20

BCFG_JSON=""
BCFG_LOADED=0

# Keep in sync with $defs.model_id.pattern in config.schema.json.
BCFG_MODEL_RE='^[a-z0-9][a-z0-9_-]*/[A-Za-z0-9][A-Za-z0-9._:-]*$'
# Home subdirectories that hold credentials and must never be exposed to the sandbox.
BCFG_DENY_HOME_DIRS=(.ssh .gnupg .claude .config .aws .azure .docker .kube .password-store
  .mozilla .pki .local/share/opencode .local/share/keyrings)
# File names that hold credentials; a toolchain path may not contain one as a segment.
BCFG_DENY_NAMES=(credentials credentials.toml .npmrc .pypirc .netrc .git-credentials
  auth.json .yarnrc .yarnrc.yml .gitconfig)
BCFG_DENY_ROOTS=(/ /home /root /etc /tmp /var /run /proc /sys /dev /boot)

_bcfg_err() { printf 'build-config: %s\n' "$*" >&2; }

bcfg_dir() { printf '%s\n' "${HOME:?HOME is not set}/.claude/build"; }

# _bcfg_safe <path> <file|dir>: not a symlink, right type, owned by us or root,
# not writable by group or others.
_bcfg_safe() {
  local p=$1 want=$2 uid owner mode ftype
  if [ -L "$p" ]; then _bcfg_err "refusing symlink: $p"; return "$BCFG_E_UNSAFE"; fi
  if ! read -r owner mode ftype < <(stat -c '%u %a %F' -- "$p" 2>/dev/null); then
    _bcfg_err "cannot stat: $p"; return "$BCFG_E_UNSAFE"
  fi
  case "$want:$ftype" in
    file:regular*|dir:directory) ;;
    *) _bcfg_err "not a $want: $p"; return "$BCFG_E_UNSAFE" ;;
  esac
  uid=$(id -u)
  if [ "$owner" != "$uid" ] && [ "$owner" != 0 ]; then
    _bcfg_err "not owned by you or root: $p"; return "$BCFG_E_UNSAFE"
  fi
  if (( 8#$mode & 8#022 )); then
    _bcfg_err "writable by group or others (mode $mode): $p"; return "$BCFG_E_UNSAFE"
  fi
  return 0
}

# Every directory from $HOME down to the build dir, plus the files the loader trusts.
_bcfg_check_anchors() {
  local d rc p
  d=$(bcfg_dir)
  for p in "$HOME" "$HOME/.claude" "$d" "$d/lib"; do
    _bcfg_safe "$p" dir || return
  done
  for p in "$d/config.schema.json" "$d/lib/jsonschema.jq" "$d/lib/config.sh"; do
    if [ ! -e "$p" ] && [ ! -L "$p" ]; then
      _bcfg_err "missing installed file: $p (re-run install.sh)"; return "$BCFG_E_INTERNAL"
    fi
    _bcfg_safe "$p" file || { rc=$?; return "$rc"; }
  done
}

# JSON parse with two extra rules jq does not enforce: exactly one top-level
# object, and no duplicate keys (a duplicate could hide a value from review).
_bcfg_parse() {
  local raw=$1 stream_leaves doc_leaves
  if ! jq -e -s 'length == 1 and (.[0] | type) == "object"' >/dev/null 2>&1 <<<"$raw"; then
    _bcfg_err "config.json is not a single valid JSON object"; return "$BCFG_E_PARSE"
  fi
  stream_leaves=$(jq -n --stream '[inputs | select(length == 2)] | length' <<<"$raw") || return "$BCFG_E_PARSE"
  doc_leaves=$(jq '[path(.. | select(((type != "object") and (type != "array")) or (length == 0)))] | length' <<<"$raw") ||
    return "$BCFG_E_PARSE"
  if [ "$stream_leaves" != "$doc_leaves" ]; then
    _bcfg_err "config.json contains duplicate keys"; return "$BCFG_E_PARSE"
  fi
}

# In-memory migration chain: migrations/config/<n>-to-<n+1>.jq. The file on disk
# is never rewritten by the loader.
_bcfg_migrate() {
  local json=$1 from to f d
  d=$(bcfg_dir)
  from=$(jq -r '.schema_version | if type == "number" and . == floor then tostring else "bad" end' <<<"$json")
  if [ "$from" = bad ]; then
    _bcfg_err "schema_version is missing or not an integer"; return "$BCFG_E_VERSION"
  fi
  if (( from > BCFG_SUPPORTED_VERSION )); then
    _bcfg_err "config schema_version $from is newer than this install supports ($BCFG_SUPPORTED_VERSION); update the pipeline"
    return "$BCFG_E_VERSION"
  fi
  if (( from < 1 )); then
    _bcfg_err "config schema_version $from is not valid"; return "$BCFG_E_VERSION"
  fi
  while (( from < BCFG_SUPPORTED_VERSION )); do
    to=$((from + 1))
    f="$d/migrations/config/$from-to-$to.jq"
    _bcfg_safe "$f" file || { _bcfg_err "no safe migration from version $from"; return "$BCFG_E_VERSION"; }
    json=$(jq -c -f "$f" <<<"$json") || { _bcfg_err "migration $from-to-$to failed"; return "$BCFG_E_VERSION"; }
    from=$to
  done
  printf '%s\n' "$json"
}

_bcfg_schema_check() {
  local json=$1 d errors
  d=$(bcfg_dir)
  local out
  # Check each step: a crash in the validator must never read as "no errors".
  if ! out=$(jq -n -c --slurpfile schema "$d/config.schema.json" --slurpfile doc /dev/stdin \
               -f "$d/lib/jsonschema.jq" <<<"$json" 2>/dev/null) ||
     ! jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null 2>&1 <<<"$out"; then
    _bcfg_err "schema validator failed to run"; return "$BCFG_E_INTERNAL"
  fi
  errors=$(jq -r '.[]' <<<"$out")
  [ -z "$errors" ] && return 0
  if grep -q '^SCHEMA:' <<<"$errors"; then
    _bcfg_err "installed schema is unusable:"; head -20 <<<"$errors" | sed 's/^/  /' >&2
    return "$BCFG_E_INTERNAL"
  fi
  _bcfg_err "config.json fails the schema:"; head -50 <<<"$errors" | sed 's/^/  /' >&2
  return "$BCFG_E_SCHEMA"
}

# _bcfg_toolchain_path_ok <path>: lexical rules only. Phase 1 adds filesystem
# checks before anything is bound into the sandbox.
_bcfg_toolchain_path_ok() {
  local raw=$1 p rel seg n
  local -a segs
  p=$raw
  # shellcheck disable=SC2088  # a literal "~/" prefix from the config, expanded here
  [[ $p == "~/"* ]] && p="$HOME/${p#"~/"}"
  p=${p%/}
  IFS=/ read -r -a segs <<<"${p#/}"
  for seg in "${segs[@]}"; do
    case $seg in
      ''|.|..) _bcfg_err "toolchain path has an empty, . or .. segment: $raw"; return 1 ;;
    esac
    for n in "${BCFG_DENY_NAMES[@]}"; do
      [ "$seg" = "$n" ] && { _bcfg_err "toolchain path names a credential file: $raw"; return 1; }
    done
  done
  for n in "${BCFG_DENY_ROOTS[@]}"; do
    [ "$p" = "$n" ] || [ "$p" = "" ] && { _bcfg_err "toolchain path is a system root: $raw"; return 1; }
  done
  if [ "$p" = "$HOME" ] || [[ $HOME == "$p"/* ]]; then
    _bcfg_err "toolchain path is your home directory or above it: $raw"; return 1
  fi
  if [[ $p == "$HOME"/* ]]; then
    rel=${p#"$HOME"/}
    for n in "${BCFG_DENY_HOME_DIRS[@]}"; do
      if [ "$rel" = "$n" ] || [[ $rel == "$n"/* ]]; then
        _bcfg_err "toolchain path is inside a credential directory (~/$n): $raw"; return 1
      fi
    done
    if [[ $rel != */* ]]; then
      _bcfg_err "toolchain path is a tool root; list a versioned subdirectory instead: $raw"; return 1
    fi
  fi
  return 0
}

_bcfg_semantic_check() {
  local json=$1 bad=0 r norm p
  if [ -n "$(jq -r '.repo_allowlist.repos | group_by(.remote) | map(select(length > 1) | .[0].remote) | .[]' <<<"$json")" ]; then
    _bcfg_err "repo_allowlist has duplicate remotes"; bad=1
  fi
  while IFS= read -r r; do
    norm=$(bcfg_normalize_remote "https://$r" 2>/dev/null) || norm=""
    if [ "$norm" != "$r" ]; then
      _bcfg_err "repo_allowlist remote is not in normalized form: $r (use: build-config normalize-remote <url>)"; bad=1
    fi
  done < <(jq -r '.repo_allowlist.repos[].remote' <<<"$json")
  if [ -n "$(jq -r '.toolchains | group_by(.id) | map(select(length > 1)) | .[][0].id' <<<"$json")" ]; then
    _bcfg_err "toolchains has duplicate ids"; bad=1
  fi
  while IFS= read -r p; do
    _bcfg_toolchain_path_ok "$p" || bad=1
  done < <(jq -r '.toolchains[].paths[]' <<<"$json")
  (( bad )) && return "$BCFG_E_SEMANTIC"
  return 0
}

bcfg_load() {
  local d cfg raw json rc
  BCFG_JSON=""; BCFG_LOADED=0
  command -v jq >/dev/null 2>&1 || { _bcfg_err "jq is required"; return "$BCFG_E_INTERNAL"; }
  d=$(bcfg_dir)
  _bcfg_check_anchors || return
  cfg="$d/config.json"
  if [ ! -e "$cfg" ] && [ ! -L "$cfg" ]; then
    _bcfg_err "no config at $cfg; run install.sh"; return "$BCFG_E_MISSING"
  fi
  _bcfg_safe "$cfg" file || return
  raw=$(<"$cfg")
  _bcfg_parse "$raw" || return
  json=$(_bcfg_migrate "$(jq -c . <<<"$raw")") || return
  _bcfg_schema_check "$json" || return
  _bcfg_semantic_check "$json" || return
  if [ -n "${OC_MODEL:-}" ]; then
    if [[ ! $OC_MODEL =~ $BCFG_MODEL_RE ]] || (( ${#OC_MODEL} > 100 )); then
      _bcfg_err "OC_MODEL is not a valid provider/model id"; return "$BCFG_E_SEMANTIC"
    fi
    json=$(jq -c --arg m "$OC_MODEL" '.worker.model = $m' <<<"$json") || return "$BCFG_E_INTERNAL"
  fi
  BCFG_JSON=$json
  BCFG_LOADED=1
}

bcfg_get() {
  local key=$1
  (( BCFG_LOADED )) || { _bcfg_err "config not loaded"; return "$BCFG_E_INTERNAL"; }
  [[ $key =~ ^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*$ ]] || { _bcfg_err "bad key: $key"; return 2; }
  jq -e -r --arg k "$key" '
    ($k | split(".") | map(if test("^[0-9]+$") then tonumber else . end)) as $p
    | if (try getpath($p) catch null) == null then error("no such key")
      else getpath($p) | if type == "string" then . else tojson end end
  ' <<<"$BCFG_JSON" 2>/dev/null || { _bcfg_err "no such key: $key"; return 2; }
}

# Normalized form: lowercase host, then the path; no scheme, user, password,
# port, trailing slash or .git suffix. Anything unrecognized fails.
bcfg_normalize_remote() {
  local url=$1 scheme rest authority host path
  if [[ $url =~ [[:space:][:cntrl:]] ]] || [ -z "$url" ]; then
    _bcfg_err "remote URL is empty or has whitespace"; return 1
  fi
  if [[ $url =~ ^([A-Za-z][A-Za-z0-9+.-]*)://(.*)$ ]]; then
    scheme=${BASH_REMATCH[1],,}
    rest=${BASH_REMATCH[2]}
    case $scheme in
      ssh|git+ssh|ssh+git|https|http|git) ;;
      *) _bcfg_err "unsupported remote scheme: $scheme"; return 1 ;;
    esac
    authority=${rest%%/*}
    if [ "$authority" = "$rest" ]; then path=""; else path=${rest#"$authority"}; fi
    authority=${authority##*@}
    host=${authority%%:*}
  elif [[ $url =~ ^([^@/]+@)?([^/:]+):(.*)$ ]]; then
    host=${BASH_REMATCH[2]}
    path=${BASH_REMATCH[3]}
  else
    _bcfg_err "local path or unrecognized remote form"; return 1
  fi
  host=${host,,}
  if [[ ! $host =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
    _bcfg_err "unsupported remote host form"; return 1
  fi
  while [[ $path == *//* ]]; do path=${path//\/\//\/}; done
  path=${path#/}; path=${path%/}
  path=${path%.git}; path=${path%/}
  if [[ ! $path =~ ^[A-Za-z0-9._~-]+(/[A-Za-z0-9._~-]+)*$ ]]; then
    _bcfg_err "unsupported remote path form"; return 1
  fi
  if [[ /$path/ == */./* ]] || [[ /$path/ == */../* ]]; then
    _bcfg_err "remote path has . or .. segments"; return 1
  fi
  printf '%s/%s\n' "$host" "$path"
}

_bcfg_allowed() {
  jq -e --arg r "$1" 'any(.repo_allowlist.repos[]; .remote == $r)' >/dev/null <<<"$BCFG_JSON"
}

# Every fetch and push URL of every remote (after insteadOf rewriting, which is
# where git actually sends data) and every submodule URL must be allowlisted.
bcfg_check_repo() {
  local dir=${1:-.} top r u norm gm gmdir entry refused=0 n=0
  (( BCFG_LOADED )) || { _bcfg_err "config not loaded"; return "$BCFG_E_INTERNAL"; }
  if ! top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null); then
    _bcfg_err "refused: not inside a git work tree"; return "$BCFG_E_REFUSED"
  fi
  local -a urls=()
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    while IFS= read -r u; do urls+=("remote $r|$u"); done < <(
      git -C "$top" remote get-url --all "$r" 2>/dev/null
      git -C "$top" remote get-url --push --all "$r" 2>/dev/null)
  done < <(git -C "$top" remote 2>/dev/null)
  if (( ${#urls[@]} == 0 )); then
    _bcfg_err "refused: repo has no remotes"; return "$BCFG_E_REFUSED"
  fi
  while IFS= read -r -d '' gm; do
    gmdir=$(dirname "$gm")
    while IFS= read -r u; do
      [ -n "$u" ] || continue
      case $u in
        ./*|../*) _bcfg_err "refused: submodule in ${gmdir#"$top"}/ uses a relative URL"; refused=1; continue ;;
      esac
      u=$(git -C "$gmdir" ls-remote --get-url "$u" 2>/dev/null) || u=""
      urls+=("submodule in ${gmdir#"$top"}/|$u")
    done < <(git config -f "$gm" --get-regexp '^submodule\..*\.url$' 2>/dev/null | cut -d' ' -f2-)
  done < <(find "$top" -name .gitmodules -type f -not -path '*/.git/*' -print0 2>/dev/null)
  while IFS= read -r u; do
    [ -n "$u" ] && urls+=("submodule (.git/config)|$u")
  done < <(git -C "$top" config --local --get-regexp '^submodule\..*\.url$' 2>/dev/null | cut -d' ' -f2-)

  local -A seen=()
  for entry in "${urls[@]}"; do
    [ -n "${seen[$entry]:-}" ] && continue
    seen[$entry]=1
    n=$((n + 1))
    if ! norm=$(bcfg_normalize_remote "${entry#*|}" 2>/dev/null); then
      _bcfg_err "refused: ${entry%%|*} has an unsupported URL form"; refused=1; continue
    fi
    if ! _bcfg_allowed "$norm"; then
      _bcfg_err "refused: ${entry%%|*} -> $norm is not in repo_allowlist"; refused=1
    fi
  done
  (( refused )) && return "$BCFG_E_REFUSED"
  printf 'allowed: %d URL(s) checked\n' "$n"
  return 0
}
