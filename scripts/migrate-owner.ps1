# npy-mcp owner migration — Windows PowerShell
#
# Single command (run in PowerShell):
#   irm https://raw.githubusercontent.com/benzstuuuuu/npy-mcp/master/scripts/migrate-owner.ps1 | iex
#
# Preview only:
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/benzstuuuuu/npy-mcp/master/scripts/migrate-owner.ps1))) -DryRun
#
# The GitHub owner moved from PigRabbBoy to benzstuuuuu. Configs installed
# earlier still say git+https://github.com/PigRabbBoy/npy-mcp@…, which only
# works while GitHub keeps redirecting the old name. This rewrites that URL in
# every known AI-client config. Nothing else in the file changes (Docker Hub
# refs like pigrabbboy/npy-mcp:latest are left alone). A .bak-* backup is made
# before every write, and a second run changes nothing.
#
# Run inside a git clone, it also rewrites that clone's npy-mcp remotes (fetch
# and push URLs, HTTPS and SSH) with `git config`. The old URL is printed, so a
# change is easy to revert; no backup is made.

param(
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Say($msg)  { Write-Host "==> $msg" -ForegroundColor Cyan }
function Warn($msg) { Write-Host " !! $msg" -ForegroundColor Yellow }
function Die($msg)  { Write-Host " !! $msg" -ForegroundColor Red; exit 1 }

# Candidate config files — mirrors Get-ClientPath in install.ps1.
$appData = $env:APPDATA
$configPaths = @(
  "$env:USERPROFILE\.gemini\settings.json",
  "$appData\Claude\claude_desktop_config.json",
  "$env:USERPROFILE\.claude.json",
  "$env:USERPROFILE\.cursor\mcp.json",
  "$appData\Code\User\mcp.json",
  "$env:USERPROFILE\.codex\config.toml",
  "$env:USERPROFILE\.config\opencode\opencode.json",
  "$env:USERPROFILE\.codeium\windsurf\mcp_config.json",
  ".mcp.json",
  ".cursor\mcp.json",
  ".vscode\mcp.json"
)

$rule = '(?i)(github(?:usercontent)?\.com/)PigRabbBoy/npy-mcp'
$replacement = '${1}benzstuuuuu/npy-mcp'
# Latin-1 maps bytes 1:1 to chars, so the rewrite is a plain byte substitution:
# no JSON/TOML parsing, and CRLF, BOM and UTF-8 text come back out exactly as read.
$latin1 = [Text.Encoding]::GetEncoding(28591)

$updated = 0; $ok = 0; $failed = 0
$seen = @{}
foreach ($given in $configPaths) {
  if (-not (Test-Path -LiteralPath $given -PathType Leaf)) { continue }
  $path = (Resolve-Path -LiteralPath $given).ProviderPath
  if ($seen.ContainsKey($path)) { continue }   # cwd == home lists the same file twice
  $seen[$path] = $true
  try {
    $old = $latin1.GetString([IO.File]::ReadAllBytes($path))
    $new = [regex]::Replace($old, $rule, $replacement)
    if ($new -ceq $old) {
      Write-Host ("{0,-13} {1}" -f "OK", $given); $ok++
    } elseif ($DryRun) {
      Write-Host ("{0,-13} {1}" -f "WOULD UPDATE", $given); $updated++
    } else {
      # These backups hold the token — keep only the most recent.
      $dir = Split-Path $path -Parent
      Get-ChildItem -LiteralPath $dir -Filter "$(Split-Path $path -Leaf).bak-*" -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
      Copy-Item -LiteralPath $path "$path.bak-$(Get-Date -Format yyyyMMddHHmmss)"
      # Temp file in the same dir, then swap: File.Replace keeps the original's ACL and attributes.
      $tmp = Join-Path $dir ".migrate-$([guid]::NewGuid().ToString('N'))"
      try {
        [IO.File]::WriteAllBytes($tmp, $latin1.GetBytes($new))
        [IO.File]::Replace($tmp, $path, $null)
      } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
      }
      Write-Host ("{0,-13} {1}" -f "UPDATED", $given); $updated++
    }
  } catch {
    Write-Host ("{0,-13} {1} ({2})" -f "FAILED", $given, $_.Exception.Message); $failed++
  }
}

# A clone made before the move keeps its remotes on the old owner. Only lines
# that change (or fail) are printed. `git config --replace-all` with an anchored
# value pattern edits one value of a multi-valued key. Credentials in a URL are
# masked in the output.
function Mask-Url($url) { [regex]::Replace($url, '(://[^/@:]+:)[^/@]+@', '${1}***@') }

$remotes = 0
if ((Get-Command git -ErrorAction SilentlyContinue) -and ((git rev-parse --is-inside-work-tree 2>$null) -eq 'true')) {
  $remoteRule = '(?i)(github\.com[:/])PigRabbBoy/npy-mcp(?![\w-])'
  $seenRemote = @{}
  foreach ($line in @(git config --local --get-regexp '^remote\..+\.(url|pushurl)$' 2>$null)) {
    $key, $old = "$line" -split ' ', 2
    $new = [regex]::Replace($old, $remoteRule, $replacement)
    if (($new -ceq $old) -or $seenRemote.ContainsKey("$key $old")) { continue }
    $seenRemote["$key $old"] = $true
    $cut = $key.LastIndexOf('.')
    $what = "git remote $($key.Substring(7, $cut - 7)) ($($key.Substring($cut + 1))): $(Mask-Url $old) -> $(Mask-Url $new)"
    if ($DryRun) {
      Write-Host ("{0,-13} {1}" -f "WOULD UPDATE", $what); $updated++; $remotes++
      continue
    }
    $valueRegex = '^' + ($old -replace '([.\[\\*+?(){}|^$])', '\$1') + '$'
    git config --local --replace-all $key $new $valueRegex 2>$null
    if ($LASTEXITCODE -eq 0) {
      Write-Host ("{0,-13} {1}" -f "UPDATED", $what); $updated++; $remotes++
    } else {
      Write-Host ("{0,-13} {1}" -f "FAILED", $what); $failed++
    }
  }
}

Write-Host ""
if ($DryRun) {
  Say "Dry run: $updated item(s) would change, $ok already fine. Nothing was written."
} else {
  Say "Done: $updated updated, $ok already fine."
  if ($updated -gt $remotes) { Say "Restart your AI clients (Claude Desktop, Claude Code, Cursor, VS Code, Codex, ...) so they pick up the new URL." }
}
if ($failed -gt 0) { Die "$failed item(s) could not be updated (see FAILED lines above)" }
