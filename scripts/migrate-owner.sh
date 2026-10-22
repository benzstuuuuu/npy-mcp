#!/usr/bin/env bash
# npy-mcp owner migration — macOS + Linux
#
#   curl -fsSL https://raw.githubusercontent.com/benzstuuuuu/npy-mcp/master/scripts/migrate-owner.sh | bash
#
# The GitHub owner moved from PigRabbBoy to benzstuuuuu. Configs installed
# earlier still say git+https://github.com/PigRabbBoy/npy-mcp@…, which only
# works while GitHub keeps redirecting the old name. This rewrites that URL in
# every known AI-client config. Nothing else in the file changes (Docker Hub
# refs like pigrabbboy/npy-mcp:latest are left alone). A .bak-* backup is made
# before every write, and a second run changes nothing.
#
# Preview only:
#   curl -fsSL .../migrate-owner.sh | bash -s -- --dry-run

set -euo pipefail

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m !!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m !!\033[0m %s\n' "$*" >&2; exit 1; }

DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    *)         die "Unknown flag: $1 (see header of this script for usage)" ;;
  esac
done

command -v python3 >/dev/null 2>&1 || die "python3 is required"

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"

# Candidate config files — mirrors client_paths() in install.sh. Gemini desktop
# (Core Data store) is skipped: the installer writes no repo URL there.
CONFIG_PATHS=(
  "$HOME/.gemini/settings.json"
  "$HOME/Library/Application Support/Claude/claude_desktop_config.json"
  "$CONFIG_HOME/Claude/claude_desktop_config.json"
  "$HOME/.claude.json"
  "$HOME/.cursor/mcp.json"
  "$CONFIG_HOME/Code/User/mcp.json"
  "$HOME/.codex/config.toml"
  "$CONFIG_HOME/opencode/opencode.json"
  "$HOME/.codeium/windsurf/mcp_config.json"
  ".mcp.json"
  ".cursor/mcp.json"
  ".vscode/mcp.json"
)

# Plain byte substitution: no JSON/TOML parsing, so formatting, CRLF and any
# BOM survive untouched.
read -r -d '' REWRITE_PY <<'PY' || true
import glob, os, re, shutil, stat, sys, tempfile, time

RULE = re.compile(rb"(github(?:usercontent)?\.com/)PigRabbBoy/npy-mcp", re.I)
REPLACEMENT = rb"\1benzstuuuuu/npy-mcp"
dry_run = sys.argv[1] == "1"

def backup(path):
    # Backups hold the Notion token — keep only the newest, mode 0600.
    for old in glob.glob(glob.escape(path) + ".bak-*"):
        os.remove(old)
    dest = path + ".bak-" + time.strftime("%Y%m%d%H%M%S")
    shutil.copyfile(path, dest)
    os.chmod(dest, 0o600)

def rewrite(path, data, mode):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=".migrate-")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        if os.path.lexists(tmp):
            os.remove(tmp)
        raise

seen = set()
for given in sys.argv[2:]:
    if not os.path.isfile(given):
        continue
    path = os.path.realpath(given)  # edit through a symlink, don't replace it
    if path in seen:  # cwd == $HOME lists the same file twice
        continue
    seen.add(path)
    try:
        with open(path, "rb") as fh:
            old = fh.read()
        new = RULE.sub(REPLACEMENT, old)
        if new == old:
            print("OK\t" + given)
        elif dry_run:
            print("WOULD UPDATE\t" + given)
        else:
            mode = stat.S_IMODE(os.stat(path).st_mode)
            backup(path)
            rewrite(path, new, mode)
            print("UPDATED\t" + given)
    except OSError as err:
        print("FAILED\t" + given + " (" + str(err) + ")")
PY

results="$(python3 -I -c "$REWRITE_PY" "$DRY_RUN" "${CONFIG_PATHS[@]}")"

updated=0 ok=0 failed=0
while IFS=$'\t' read -r status path; do
  [[ -n "$status" ]] || continue
  printf '%-13s %s\n' "$status" "$path"
  case "$status" in
    UPDATED|"WOULD UPDATE") updated=$((updated + 1)) ;;
    OK)                     ok=$((ok + 1)) ;;
    FAILED)                 failed=$((failed + 1)) ;;
  esac
done <<< "$results"

echo
if [[ $DRY_RUN -eq 1 ]]; then
  say "Dry run: $updated file(s) would change, $ok already fine. Nothing was written."
else
  say "Done: $updated updated, $ok already fine."
  [[ $updated -eq 0 ]] || say "Restart your AI clients (Claude Desktop, Claude Code, Cursor, VS Code, Codex, …) so they pick up the new URL."
fi
[[ $failed -eq 0 ]] || die "$failed file(s) could not be updated (see FAILED lines above)"
