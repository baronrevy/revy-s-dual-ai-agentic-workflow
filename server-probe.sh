#!/usr/bin/env bash
# Read-only server probe for the Claude Code + OpenCode build pipeline.
# Usage: bash server-probe.sh [repo-dir ...]   (repo dirs = repos you plan to allowlist)
# Writes nothing, installs nothing. Secrets are never printed: keys show as set/unset,
# remote URLs are redacted, and v1 source is passed through a redaction filter.
set -u
h() { printf '\n===== %s =====\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }
ver() {
  local n=$1; shift
  if have "$n"; then printf '%-17s %s\n' "$n" "$("$n" "$@" 2>&1 | head -1)"; else printf '%-17s MISSING\n' "$n"; fi
}
tilde() { sed "s|$HOME|~|g"; }
redact() {
  perl -pe '
    s#(//)[^/@\s]+@#$1CREDS@#g;
    s#(ntfy\.sh/)[\w-]+#$1REDACTED#gi;
    s#((?:api[_-]?key|token|secret|passw(?:or)?d|topic|auth|bearer)["\x27]?\s*[:=]\s*["\x27]?)[^\s"\x27]{6,}#$1REDACTED#gi;
    s#\b(?:sk|pk|ghp|gho|github_pat|xox[bp]|tk)[-_][A-Za-z0-9_-]{12,}#REDACTED#g;
    s#\b[A-Za-z0-9+/_-]{40,}={0,2}#REDACTED#g;
  '
}

echo "PROBE START $(date -u +%FT%TZ)"

h "OS / kernel / namespaces"
head -2 /etc/os-release; uname -rm
for k in kernel.unprivileged_userns_clone kernel.apparmor_restrict_unprivileged_userns \
         kernel.apparmor_restrict_unprivileged_unconfined user.max_user_namespaces; do
  printf '%s = %s\n' "$k" "$(cat "/proc/sys/${k//.//}" 2>/dev/null || echo n/a)"
done
printf 'apparmor enabled: %s\n' "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null || echo n/a)"
printf 'cgroup fs: %s\n' "$(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo n/a)"
printf 'systemd --user: %s\n' "$(systemctl --user is-system-running 2>&1 | head -1)"
printf 'linger: %s\n' "$(loginctl show-user "$(id -un)" -p Linger 2>/dev/null || echo n/a)"
printf 'passwordless sudo: %s\n' "$(sudo -n true 2>/dev/null && echo yes || echo no)"
printf 'human accounts (uid>=1000): %s\n' "$(getent passwd | awk -F: '$3>=1000 && $3<65534' | wc -l)"
printf 'running as root: %s\n' "$([ "$(id -u)" = 0 ] && echo yes || echo no)"

h "Tools"
ver bash --version; ver git --version; ver jq --version; ver perl -e 'print "$^V\n"'
ver flock --version; ver setsid --version; ver timeout --version; ver stat --version
ver tmux -V; ver rsync --version; ver sha256sum --version
ver bwrap --version; ver shellcheck --version; ver gitleaks version; ver semgrep --version
ver check-jsonschema --version; ver python3 --version; ver curl --version
ver claude --version; ver opencode --version
have bwrap && printf 'bwrap perms: %s\n' "$(stat -c '%A %U' "$(command -v bwrap)")"

h "bubblewrap smoke test (runs /bin/true only)"
if have bwrap; then
  bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp --unshare-all --die-with-parent /bin/true 2>&1 \
    && echo "unshare-all: OK" || echo "unshare-all: FAILED"
  bwrap --ro-bind / / --unshare-net --die-with-parent /bin/true 2>&1 \
    && echo "unshare-net: OK" || echo "unshare-net: FAILED"
else
  echo "bwrap not installed"
fi

h "Filesystems"
for p in "$HOME" /tmp /opt; do printf '%-6s %s\n' "$(echo "$p" | tilde)" "$(findmnt -no FSTYPE,OPTIONS -T "$p" 2>/dev/null)"; done
df -h "$HOME" /tmp 2>/dev/null | tilde
printf 'umask: %s\n' "$(umask)"
for p in ~/.claude ~/.claude/skills ~/.claude/agents ~/.claude/bin ~/.config ~/.config/opencode; do
  [ -L "$p" ] && echo "SYMLINK: $(echo "$p" | tilde) -> $(readlink "$p" | tilde)"
done
echo "(no symlink lines above = no symlinked config dirs)"

h "v1 install: files + sha256"
for d in ~/.claude/skills/build ~/.claude/skills/ship-pr ~/.claude/agents ~/.claude/bin \
         ~/.claude/hooks ~/.claude/build ~/.config/opencode/agents; do
  if [ -e "$d" ]; then
    echo "[$(echo "$d" | tilde)]"
    find "$d" -maxdepth 2 -type f -exec sha256sum {} + 2>/dev/null | tilde
  else
    echo "[$(echo "$d" | tilde)] absent"
  fi
done

h "v1 source (redacted; notify.sh and credentials are never printed)"
for f in ~/.claude/bin/oc-worker.sh ~/.claude/bin/cc ~/.config/opencode/agents/worker.md \
         ~/.claude/skills/build/SKILL.md ~/.claude/agents/*.md ~/.claude/hooks/*; do
  [ -f "$f" ] || continue
  case "$f" in *notify*|*.env|*secret*|*token*|*cred*) continue ;; esac
  echo "----- BEGIN $(echo "$f" | tilde) ($(wc -l <"$f") lines) -----"
  redact <"$f"
  echo "----- END $(echo "$f" | tilde) -----"
done

h "Claude Code settings (structure only)"
f=~/.claude/settings.json
if [ -f "$f" ]; then
  jq -c '{top: keys, hooks: (.hooks // {} | keys),
          permissions: (.permissions // {} | with_entries(.value |= (if type=="array" then length else . end)))}' "$f" 2>&1
else
  echo "no ~/.claude/settings.json"
fi
printf 'global gitignore: %s\n' "$(git config --global core.excludesFile 2>/dev/null | tilde || true)"
gi=$(git config --global core.excludesFile 2>/dev/null); gi=${gi/#\~/$HOME}
[ -n "$gi" ] && [ -f "$gi" ] && { grep -n '\.claude' "$gi" || echo "(no .claude entries in global gitignore)"; }

h "OpenCode (no secrets)"
for f in ~/.config/opencode/opencode.json ~/.config/opencode/opencode.jsonc; do
  [ -f "$f" ] && echo "$(echo "$f" | tilde): keys=$(jq -c 'keys' "$f" 2>/dev/null || echo '(jsonc, not parsed)') providers=$(jq -c '.provider // {} | keys' "$f" 2>/dev/null)"
done
af=~/.local/share/opencode/auth.json
[ -f "$af" ] && echo "auth.json present, providers=$(jq -c 'keys' "$af" 2>/dev/null), perms=$(stat -c %a "$af")"
printf 'DEEPSEEK_API_KEY in env: %s\n' "$([ -n "${DEEPSEEK_API_KEY:-}" ] && echo set || echo unset)"
printf 'OC_MODEL in env: %s\n' "${OC_MODEL:-unset}"
if have opencode; then echo "opencode models deepseek:"; timeout 30 opencode models deepseek 2>&1 | head -20; fi

h "Toolchains"
for t in node npm pnpm yarn bun deno python3 pip uv poetry go cargo rustc java mvn gradle ruby bundle php composer dotnet; do
  have "$t" && printf '%-8s %s\n' "$t" "$(command -v "$t" | tilde)"
done
echo "/opt contents:"; find /opt -mindepth 1 -maxdepth 1 -printf '  %f\n' 2>/dev/null | sort
for d in ~/.nvm ~/.pyenv ~/.cargo ~/.rustup ~/.asdf ~/.local/share/mise ~/.sdkman ~/go; do
  [ -d "$d" ] && echo "home toolchain dir: $(echo "$d" | tilde)"
done

h "Repos to allowlist (remote URL shapes, owner/repo redacted)"
if [ $# -eq 0 ]; then echo "(none given; re-run as: bash server-probe.sh ~/path/to/repo ...)"; fi
n=0
for r in "$@"; do
  echo "[repo $((++n))]"
  if git -C "$r" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$r" remote -v | sed -E -e 's#//[^/@ ]+@#//CREDS@#' -e 's#([:/])[^/: ]+/[^/ ]+ #\1OWNER/REPO #'
    [ -z "$(git -C "$r" remote)" ] && echo "(no remotes)"
  else
    echo "not a git repo"
  fi
done

echo; echo "PROBE END"
