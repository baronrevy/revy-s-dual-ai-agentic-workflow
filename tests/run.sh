#!/usr/bin/env bash
# Run every test: tests/run.sh [phase-dir-glob]   e.g. tests/run.sh phase0
# Prints PASS / FAIL / SKIP per test and exits non-zero if anything failed.
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
filter=${1:-phase*}
T_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/build-tests.XXXXXX")
export T_ROOT
trap 'rm -rf "$T_ROOT"' EXIT

pass=0 failed=0 skipped=0
declare -a failures=()

# shellcheck disable=SC2231  # $filter is a glob on purpose
for file in "$here"/$filter/test_*.sh; do
  [ -f "$file" ] || continue
  printf '%s\n' "${file#"$here"/}"
  # shellcheck disable=SC2016
  mapfile -t tests < <(bash -c '. "$1"; declare -F | awk "{print \$3}" | grep "^test_"' _ "$file")
  for t in "${tests[@]}"; do
    (
      # shellcheck source=lib.sh
      . "$here/lib.sh"
      # shellcheck disable=SC1090
      . "$file"
      "$t"
    ) 2>"$T_ROOT/last.err"
    rc=$?
    case $rc in
      0)  pass=$((pass + 1)); printf '  PASS  %s\n' "$t" ;;
      77) skipped=$((skipped + 1)); printf '  SKIP  %s (%s)\n' "$t" "$(sed -n 's/^ *skip: //p' "$T_ROOT/last.err" | head -1)" ;;
      *)  failed=$((failed + 1)); failures+=("$t"); printf '  FAIL  %s\n' "$t"; sed 's/^/        /' "$T_ROOT/last.err" | head -15 ;;
    esac
  done
done

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$failed" "$skipped"
(( failed == 0 )) || { printf 'failed: %s\n' "${failures[*]}"; exit 1; }
