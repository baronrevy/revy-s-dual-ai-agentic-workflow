#!/usr/bin/env bash
# Read-only server probe. Prints facts only; never prints file contents that may hold secrets.
set -u
h() { printf '\n## %s\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }
ver() { if have "$1"; then printf '%-12s %s\n' "$1" "$("$@" 2>&1 | head -1)"; else printf '%-12s MISSING\n' "$1"; fi; }

h "OS / kernel"
head -2 /etc/os-release; uname -r
for k in kernel.unprivileged_userns_clone kernel.apparmor_restrict_unprivileged_userns user.max_user_namespaces; do
  printf '%s = %s\n' "$k" "$(sysctl -n "$k" 2>/dev/null || echo n/a)"; done
printf 'apparmor: %s\n' "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null || echo n/a)"
printf 'cgroup: %s\n' "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)"
printf 'systemd --user: %s  linger: %s\n' "$(systemctl --user is-system-running 2>&1 | head -1)" "$(loginctl show-user "$(id -un)" -p Linger 2>/dev/null)"
printf 'sudo without password: %s\n' "$(sudo -n true 2>/dev/null && echo yes || echo no)"

h "Tools"
ver bash --version; ver git --version; ver jq --version; ver perl -e 'print "$^V\n"'
ver flock --version; ver setsid --version; ver timeout --version; ver stat --version; ver tmux -V
ver bwrap --version; ver shellcheck --version; ver gitleaks version; ver semgrep --version
ver claude --version; ver opencode --version; ver python3 --version; ver check-jsonschema --version
have bwrap && printf 'bwrap setuid: %s\n' "$(stat -c %A "$(command -v bwrap)")"

h "bubblewrap smoke test (harmless: runs /bin/true)"
if have bwrap; then
  bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp --unshare-all --die-with-parent /bin/true 2>&1 && echo "bwrap unshare-all: OK"
  bwrap --ro-bind / / --unshare-net --die-with-parent /bin/true 2>&1 && echo "bwrap unshare-net: OK"
else echo "bwrap not installed"; fi

h "Filesystems"
for p in "$HOME" /tmp /opt; do printf '%-8s %s\n' "$p" "$(findmnt -no FSTYPE,OPTIONS -T "$p" 2>/dev/null)"; done
df -h "$HOME" /tmp 2>/dev/null | sed 1d
printf 'umask: %s\n' "$(umask)"
for p in ~/.claude ~/.config ~/.config/opencode; do [ -L "$p" ] && echo "SYMLINK: $p -> $(readlink "$p")"; done

h "v1 install (listing + hashes only)"
for d in ~/.claude/skills/build ~/.claude/skills/ship-pr ~/.claude/agents ~/.claude/bin ~/.claude/hooks ~/.claude/build ~/.config/opencode/agents; do
  if [ -e "$d" ]; then echo "[$d]"; find "$d" -maxdepth 2 -type f -exec sha256sum {} + 2>/dev/null | sed "s|$HOME|~|"; else echo "[$d] absent"; fi; done

h "Claude Code settings (structure only)"
f=~/.claude/settings.json
[ -f "$f" ] && jq -c '{keys: keys, hooks: (.hooks // {} | keys), perm_keys: (.permissions // {} | keys)}' "$f" 2>&1 || echo "no settings.json"
printf 'global gitignore: %s\n' "$(git config --global core.excludesFile || echo unset)"

h "OpenCode (no secrets printed)"
for f in ~/.config/opencode/opencode.json ~/.config/opencode/opencode.jsonc; do
  [ -f "$f" ] && echo "$f top-level keys: $(jq -c 'keys' "$f" 2>/dev/null || echo '(jsonc, not parsed)')"; done
[ -f ~/.local/share/opencode/auth.json ] && echo "auth.json present (providers: $(jq -c 'keys' ~/.local/share/opencode/auth.json 2>/dev/null))"
printf 'DEEPSEEK_API_KEY in env: %s\n' "$([ -n "${DEEPSEEK_API_KEY:-}" ] && echo set || echo unset)"
have opencode && { echo "deepseek models:"; timeout 30 opencode models deepseek 2>&1 | head -20; }

h "Toolchains on PATH"
for t in node npm pnpm python3 pip uv go cargo rustc java ruby; do have "$t" && printf '%-8s %s\n' "$t" "$(command -v "$t" | sed "s|$HOME|~|")"; done
ls -d /opt/* 2>/dev/null

h "Remote URL shapes (owner/repo redacted) - current directory"
if git rev-parse --git-dir >/dev/null 2>&1; then
  git remote -v | sed -E -e 's#//[^/@ ]+@#//CREDS@#' -e 's#([:/])[^/: ]+/[^/ ]+ #\1OWNER/REPO #'
else echo "not in a git repo (cd into one you plan to allowlist and re-run for this section)"; fi
