<#
.SYNOPSIS
  ctx-kit -- rollback, on Windows.

.DESCRIPTION
  The Windows counterpart of uninstall.sh.

  Nothing here deletes source files. The index is the only removable artifact and
  it is never removed without an explicit flag plus a confirmation.

.EXAMPLE
  .\uninstall.ps1                # remove this repo's hooks only (safe default)
.EXAMPLE
  .\uninstall.ps1 -Global        # also unwire compressmcp and the two plugins
.EXAMPLE
  .\uninstall.ps1 -PurgeIndex    # also delete .code-graph\ (asks first)
#>
[CmdletBinding()]
param(
    [string]$ProjectDir,
    [ValidateSet('Both', 'Claude', 'Codex')][string]$Target = 'Both',
    [switch]$Global,
    [switch]$PurgeIndex,
    [Alias('y')][switch]$Yes
)

$KitDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $KitDir 'lib\common.ps1')

$ProjectDir = Resolve-ProjectDir $ProjectDir
$UseClaude = $Target -in @('Both', 'Claude')
$UseCodex = $Target -in @('Both', 'Codex')

& node (Join-Path $KitDir 'lib\project-mcp.mjs') remove --project-dir $ProjectDir --target $Target
if ($LASTEXITCODE -ne 0) { Stop-WithError 'project MCP config could not be safely removed' }

Write-Step 'Project hooks'
 $settingsPath = Join-Path $ProjectDir '.claude\settings.local.json'
if ($UseClaude -and (Test-Path $settingsPath)) {
    # Must not abort the whole rollback: settings.mjs exits non-zero on malformed
    # JSON (it refuses to clobber it), and that must not stop -Global/-PurgeIndex.
    & node (Join-Path $KitDir 'lib\settings.mjs') remove --project-dir $ProjectDir *> $null
    if ($LASTEXITCODE -eq 0) { Write-Ok 'kit hooks and CODE_GRAPH_HOOK_INDEX removed (other settings left intact)' }
    else { Write-Warn 'could not edit .claude\settings.local.json (malformed?) -- remove the [ctx-kit] hooks by hand' }
} else {
    if ($UseClaude) { Write-Info 'no .claude\settings.local.json -- nothing to do' }
}

if ($UseCodex) {
    $codexHooks = Join-Path $ProjectDir '.codex\hooks.json'
    if (Test-Path $codexHooks) {
        & node (Join-Path $KitDir 'lib\codex-hooks.mjs') remove --project-dir $ProjectDir *> $null
        if ($LASTEXITCODE -eq 0) { Write-Ok 'Codex ctx-kit hooks removed (other .codex/hooks.json entries left intact)' }
        else { Write-Warn 'could not edit .codex\hooks.json (malformed?) -- remove ctx-kit-codex handlers by hand' }
    } else {
        Write-Info 'no .codex\hooks.json -- nothing to do'
    }
}

if ($Global) {
    Write-Step 'Global tooling'
    $cmcp = Resolve-NodeCli 'compressmcp'
    if ($UseClaude -and $cmcp) {
        & $cmcp uninstall *> $null
        if ($LASTEXITCODE -eq 0) { Write-Ok 'compressmcp hooks removed' } else { Write-Warn 'compressmcp uninstall failed' }
    }
    if ($UseClaude) {
        foreach ($p in @('context-mode', 'code-graph-mcp')) {
            & claude plugin uninstall $p *> $null
            if ($LASTEXITCODE -eq 0) { Write-Ok "plugin removed: $p" } else { Write-Warn "could not remove plugin $p" }
        }
        Write-Info 'the npm package itself is left in place: npm uninstall -g compressmcp'
    }
    # The plugin's downloaded exe (~44 MB in ~\.cache\code-graph\bin) is left in
    # place on purpose: it is shared by every repo on this machine, and deleting
    # it here would silently break the OTHER projects still using the kit.
    Write-Info 'the downloaded code-graph binary is left in place: ~\.cache\code-graph\bin'
}

if ($PurgeIndex) {
    Write-Step 'Index'
    $idx = Join-Path $ProjectDir '.code-graph'
    if (Test-Path $idx) {
        $bytes = (Get-ChildItem $idx -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        $size = '{0:N1} MB' -f ($bytes / 1MB)
        $go = $true
        if (-not $Yes) {
            $reply = Read-Host "  Delete $idx ($size)? This is not reversible. [y/N]"
            if ($reply -notmatch '^[yY]') { Write-Info 'kept'; $go = $false }
        }
        if ($go) {
            Remove-Item $idx -Recurse -Force
            Write-Ok "removed $idx ($size)"
        }
    } else {
        Write-Info 'no .code-graph\ directory'
    }
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green -NoNewline
if ($UseClaude) { Write-Host ' Restart Claude Code (or open /hooks) to reload the config.' }
elseif ($UseCodex) { Write-Host ' Restart Codex to reload its configuration.' }
