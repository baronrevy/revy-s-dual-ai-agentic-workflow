#!/usr/bin/env bash
# Test stand-in for the Phase 1 worker wrapper: nothing may reach the worker
# unless the D1 check passes. Usage: stub-handoff.sh <repo> <spec-file>
set -euo pipefail
repo=$1 spec=$2
"$HOME/.claude/bin/build-config" check-repo "$repo" || exit
opencode run --file "$spec"
