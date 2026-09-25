# Claude Code + OpenCode zero-trust build pipeline

Claude Code is the brain; OpenCode running a DeepSeek model is an untrusted worker
that only writes code inside a sandbox. Claude specs, gates, reviews and reports.
You make every accept, discard, merge and push decision.

Built in phases, each approved before and after:

| Phase | Builds | Status |
|---|---|---|
| 0 | Config, schema, fail-closed loader, repo allowlist check | done |
| 1 | Bubblewrap sandbox, worker wrapper, `/build` flow, resumable state, run log | next |
| 2 | Deterministic gates, auto-retry, notifications | |
| 3 | Spec read-back, delta reviews, lessons learned | |
| 4 | Triage, model right-sizing, slicing | |

## Install

Needs bash 4+, GNU coreutils, git and jq. Tests also use shellcheck and python3-jsonschema.

```bash
sudo apt install jq shellcheck python3-jsonschema bubblewrap
./install.sh          # safe to re-run
tests/run.sh          # all tests; no DeepSeek or Claude calls
```

The installer:
- installs into `~/.claude/build/` and `~/.claude/bin/build-config`
- writes `config.json` (mode 0600) only if none exists; an existing one is never overwritten
- backs up every file it replaces to `~/.claude/build/backups/<timestamp>/`
- tightens group or world write access on `~/.claude` and its own directories
- adds `ask` rules to `~/.claude/settings.json` so Claude's file tools need your approval
  to edit `~/.claude/build/**`, `~/.claude/bin/**` or `settings.json` itself

## Config

`~/.claude/build/config.json`, validated against `config.schema.json`. Unknown keys are errors.

| Key | Decision | Default |
|---|---|---|
| `repo_allowlist` | D1: repos that may be sent to DeepSeek | empty; every remote, push URL and submodule must be listed |
| `sandbox` | D2 | bubblewrap, no fallback (fixed) |
| `network` | D3 | worker allowed with rails; gates and tests offline (fixed) |
| `worker.model` | worker model; `OC_MODEL` env overrides | `deepseek/deepseek-v4-pro` |
| `limits.round_cap` | D4 | 3 |
| `limits.worker_timeout_minutes` | D5 | 60 |
| `security_sensitive_paths` | D6: regexes forcing Opus review | auth, crypto, session, token, permission, parsing, sql, shell/exec |
| `triage.small` | D7 | 1 file, 30 lines, no sensitive path |
| `notifications` | D8 | none |
| `toolchains` | D9: read-only in sandbox | empty |
| `circuit_breaker` | D10: last-resort loop stops | 40 transitions, 6 automated hours, 3 same-state resumes |

To allow a repo, get its normalized form and add an entry by hand:

```bash
~/.claude/bin/build-config normalize-remote git@github.com:you/project.git
# -> github.com/you/project
# add {"remote": "github.com/you/project", "added": "YYYY-MM-DD"} to repo_allowlist.repos
~/.claude/bin/build-config check-repo ~/code/project
```

## `build-config` interface

| Command | Result |
|---|---|
| `validate` | exit 0 only if config and installed files are safe and valid |
| `show` | effective config as JSON |
| `get <key.path>` | one value, e.g. `limits.round_cap` |
| `check-repo [dir]` | exit 0 only if every URL the repo can send to is allowlisted |
| `normalize-remote <url>` | allowlist form of a URL |

Scripts source `~/.claude/build/lib/config.sh` and call `bcfg_load`, `bcfg_get`,
`bcfg_check_repo`, `bcfg_normalize_remote`.

Exit codes: 10 config missing, 11 unsafe file or directory, 12 bad JSON or duplicate keys,
13 unsupported schema version, 14 schema violation, 15 semantic rule, 16 internal error,
20 repo refused, 2 usage. Every non-zero code means stop: no handoff.

## Schema versions

`schema_version` is 1. A newer loader migrates older configs in memory with
`build/migrations/config/<n>-to-<n+1>.jq` and never rewrites your file. A config newer
than the installed code is refused.
