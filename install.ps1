<#
.SYNOPSIS
  ctx-kit -- one-command setup of the context-saving stack for a repo, on Windows.

.DESCRIPTION
  The Windows counterpart of install.sh. Same four layers, same settings
  generator (lib/settings.mjs is shared, so the two platforms can never drift),
  but the hooks it writes are PowerShell and pinned with "shell": "powershell".

  Why not just run install.sh under Git Bash: Claude Code runs a Windows hook
  through Git Bash only when Git for Windows is installed, and falls back to
  PowerShell when it is not. A bash-only hook is silently dead on any machine
  without it -- and a hook that does nothing reports nothing.

  Idempotent: safe to re-run. Every step checks its own state first.

.EXAMPLE
  .\install.ps1
.EXAMPLE
  .\install.ps1 -ProjectDir C:\src\myrepo -Throttle 300 -Yes
#>
[CmdletBinding()]
param(
    [string]$ProjectDir,
    [int]$Throttle = 120,
    [switch]$SkipPlugins,
    [switch]$SkipCompressMcp,
    [switch]$NoIndex,
    [Alias('y')][switch]$Yes
)

$KitDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $KitDir 'lib\common.ps1')

if ($Throttle -lt 0) { Stop-WithError "invalid -Throttle: $Throttle" }
$ProjectDir = Resolve-ProjectDir $ProjectDir

# ---------------------------------------------------------------------------
Write-Step 'Preflight'
# ---------------------------------------------------------------------------
if (-not (Test-CommandExists node)) { Stop-WithError 'node not found on PATH -- install Node.js 18+ first' }
if (-not (Test-CommandExists claude)) { Stop-WithError 'claude not found on PATH -- install Claude Code first: https://claude.com/claude-code' }

# Parsed here rather than with `node -p "expr"`: Windows PowerShell 5.1 rewrites
# the argument vector on its way to a native exe and eats the embedded double
# quotes, so node receives `process.versions.node.split(.)[0]` and dies on a
# syntax error that reads like a broken Node install.
$nodeMajor = [int]((& node -v).TrimStart('v').Split('.')[0])
if ($nodeMajor -lt 18) { Stop-WithError "Node 18+ required, found $(& node -v)" }
Write-Ok "node $(& node -v), claude CLI present"
Write-Info "project: $ProjectDir"

& git -C $ProjectDir rev-parse --git-dir *> $null
$isGitRepo = ($LASTEXITCODE -eq 0)
if (-not $isGitRepo) { Write-Warn 'not a git repository -- .gitignore wiring will be skipped' }

if (-not $Yes) {
    $reply = Read-Host "`nInstall into $ProjectDir? [y/N]"
    if ($reply -notmatch '^[yY]') { Stop-WithError 'aborted' }
}

# ---------------------------------------------------------------------------
Write-Step 'Plugins (context-mode, code-graph-mcp)'
# ---------------------------------------------------------------------------
if ($SkipPlugins) {
    Write-Info 'skipped (-SkipPlugins)'
} else {
    $installedPlugins = (& claude plugin list 2>$null | Out-String)
    $marketplaces = (& claude plugin marketplace list 2>$null | Out-String)

    function Add-Marketplace {
        param([string]$Repo, [string]$Name)
        if ($marketplaces -match [regex]::Escape($Name)) { Write-Ok "marketplace already registered: $Name"; return }
        & claude plugin marketplace add $Repo *> $null
        if ($LASTEXITCODE -eq 0) { Write-Ok "marketplace added: $Repo" }
        else { Write-Warn "could not add marketplace $Repo -- add it manually with /plugin" }
    }
    function Install-Plugin {
        param([string]$Ref, [string]$Name)
        if ($installedPlugins -match [regex]::Escape($Name)) { Write-Ok "plugin already installed: $Name"; return }
        & claude plugin install $Ref *> $null
        if ($LASTEXITCODE -eq 0) { Write-Ok "plugin installed: $Ref" }
        else { Write-Warn "could not install $Ref -- install it manually with /plugin" }
    }

    # mksglu/context-mode is canonical; mksglu/claude-context-mode redirects to it.
    Add-Marketplace 'mksglu/context-mode' 'context-mode'
    Install-Plugin 'context-mode@context-mode' 'context-mode'

    Add-Marketplace 'sdsrss/code-graph-mcp' 'code-graph-mcp'
    Install-Plugin 'code-graph-mcp@code-graph-mcp' 'code-graph-mcp'
}

# ---------------------------------------------------------------------------
Write-Step 'code-graph-mcp binary'
# ---------------------------------------------------------------------------
# The step install.sh does not have, and the reason a Windows install otherwise
# stalls at "CLI not found -- restart Claude Code once and re-run": the plugin
# does not put anything on PATH. It downloads a native exe into its own cache,
# and only on a SessionStart that has not happened yet. Trigger that download
# here instead of telling the user to restart and hope.
$CG = Resolve-CodeGraphBinary
if ($CG) {
    Write-Ok "code-graph-mcp -> $CG"
} else {
    $pluginRoot = Join-Path $env:USERPROFILE '.claude\plugins\cache\code-graph-mcp\code-graph-mcp'
    $newest = $null
    if (Test-Path $pluginRoot) {
        $newest = Get-ChildItem $pluginRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    if ($newest) {
        $updater = Join-Path $newest.FullName 'scripts\auto-update.js'
        if (Test-Path $updater) {
            Write-Info 'downloading the native binary (~44 MB) -- the plugin fetches it lazily and has not yet'
            & node $updater --install-missing *> $null
            $CG = Resolve-CodeGraphBinary
        }
    }
    if ($CG) { Write-Ok "code-graph-mcp -> $CG" }
    else { Write-Warn 'code-graph-mcp binary not found -- restart Claude Code once, then re-run this installer' }
}

# ---------------------------------------------------------------------------
Write-Step 'compressmcp (MCP response compression)'
# ---------------------------------------------------------------------------
if ($SkipCompressMcp) {
    Write-Info 'skipped (-SkipCompressMcp)'
} else {
    $cmcp = Resolve-NodeCli 'compressmcp'
    if (-not $cmcp) {
        & npm install -g compressmcp *> $null
        if ($LASTEXITCODE -eq 0) { Write-Ok 'npm package installed' } else { Write-Warn 'npm install -g compressmcp failed' }
        $cmcp = Resolve-NodeCli 'compressmcp'
    } else {
        Write-Ok 'npm package already present'
    }

    if ($cmcp) {
        $status = (& $cmcp check 2>&1 | Out-String)
        # Matched on the WORD, not the tick: this file is deliberately pure
        # ASCII. Windows PowerShell 5.1 reads a BOM-less script as the ANSI code
        # page, where a UTF-8 tick decodes to bytes that include 0x93 -- a smart
        # quote, which PowerShell accepts as a string delimiter. One tick in a
        # comment is enough to make the whole script fail to parse.
        if ($status -match 'PostToolUse hook \(compress\):\s+\S+\s+installed') {
            # Deliberately NOT re-running `compressmcp install`. Its installer
            # overwrites settings.json -> statusLine; if code-graph is also
            # installed, its composite status line has already adopted
            # compressmcp's as "_previous", and re-running would replace the
            # composite and silently drop code-graph's segment.
            Write-Ok 'hooks already wired (not re-running installer -- it would clobber the composite status line)'
        } else {
            & $cmcp install *> $null
            if ($LASTEXITCODE -eq 0) { Write-Ok 'hooks + MCP server registered' } else { Write-Warn 'compressmcp install failed -- run it manually' }
        }

        # Register the MCP server where Claude Code actually reads MCP config.
        #
        # compressmcp's own installer writes mcpServers into
        # ~/.claude/settings.json. Claude Code never loads MCP servers from
        # there -- they live in ~/.claude.json (local/user scope) or a project
        # .mcp.json. The entry it writes is therefore inert, while
        # `compressmcp check` keeps reporting the server as registered because
        # it reads back its own file. Observed: a machine where the server had
        # never started once, with every status readout green.
        #
        # Registered as `node <entry>` rather than by bin name because Claude
        # Code spawns MCP servers in exec form, with no shell: on Windows the
        # extensionless npm shim is not executable (ENOENT) and Node >= 18.20
        # refuses the .cmd shim (EINVAL). Correct on every platform.
        $mcpList = (& claude mcp list 2>$null | Out-String)
        if ($mcpList -match '(?m)^compressmcp:') {
            Write-Ok 'MCP server already registered with Claude Code'
        } else {
            $entry = & node (Join-Path $KitDir 'lib\mcp-entry.mjs') --name compressmcp 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $entry) {
                Write-Warn 'could not locate compressmcp entry point -- register by hand: claude mcp add --scope user compressmcp -- node <entry> --server'
            } else {
                & claude mcp add --scope user compressmcp -- node $entry --server *> $null
                if ($LASTEXITCODE -eq 0) { Write-Ok 'MCP server registered with Claude Code' }
                else { Write-Warn "claude mcp add failed -- register by hand: claude mcp add --scope user compressmcp -- node `"$entry`" --server" }
            }
        }
    }

    # compressmcp compresses MCP tool responses. With no other MCP server
    # configured it is pure overhead -- hooks on every call, nothing to
    # compress. The two plugins above register servers, so this is normally fine.
    $mcpList = (& claude mcp list 2>$null | Out-String)
    if ((@($mcpList -split "`n" | Where-Object { $_ -match '^\S+:' }).Count) -le 1) {
        Write-Warn 'no other MCP servers configured -- compressmcp has nothing to compress until you add some'
    }
}

# ---------------------------------------------------------------------------
Write-Step 'Project hooks (automatic reindexing)'
# ---------------------------------------------------------------------------
$settingsPath = & node (Join-Path $KitDir 'lib\settings.mjs') apply --project-dir $ProjectDir --throttle $Throttle --shell powershell
if ($LASTEXITCODE -ne 0) { Stop-WithError 'could not write .claude/settings.local.json' }
Write-Ok "wrote $($settingsPath.Replace($ProjectDir + '\', ''))"
Write-Info 'env CODE_GRAPH_HOOK_INDEX=on   -> agent Write/Edit indexed immediately'
Write-Info 'SessionStart hook              -> catches git pull / editor edits between sessions'
Write-Info "UserPromptSubmit hook (${Throttle}s)  -> catches edits outside the agent mid-session"

if ($isGitRepo) {
    $gi = Join-Path $ProjectDir '.gitignore'
    $existing = @()
    if (Test-Path $gi) { $existing = Get-Content $gi }
    $added = $false
    foreach ($entry in @('.claude/settings.local.json', '.code-graph/')) {
        if ($existing -contains $entry) {
            Write-Ok ".gitignore already has $entry"
            continue
        }
        if (-not $added) {
            Add-Content -Path $gi -Value "`r`n# ctx-kit (machine-specific paths + local index)"
            $added = $true
        }
        Add-Content -Path $gi -Value $entry
        Write-Ok ".gitignore += $entry"
    }
}

# ---------------------------------------------------------------------------
Write-Step 'Initial index'
# ---------------------------------------------------------------------------
if ($NoIndex) {
    Write-Info 'skipped (-NoIndex)'
} elseif (-not $CG) {
    Write-Warn 'no code-graph-mcp binary -- skipping the initial index'
} else {
    Write-Info "indexing $ProjectDir (first run walks the whole tree; later runs are incremental)"
    Push-Location $ProjectDir
    & $CG incremental-index --quiet *> $null
    $health = (& $CG health-check 2>&1 | Out-String).Split("`n")[0]
    Pop-Location
    if ($health) { Write-Ok $health.Trim() } else { Write-Ok 'index built' }

    if ($health -match '(?i)vector inactive') {
        Write-Info 'vector search inactive -- run .\install-model.ps1 to install the embedding model (~80 MB)'
    }
}

# ---------------------------------------------------------------------------
Write-Step 'Verify'
# ---------------------------------------------------------------------------
& (Join-Path $KitDir 'verify.ps1') -ProjectDir $ProjectDir

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green -NoNewline
Write-Host ' One manual step remains:'
Write-Host ''
Write-Host '  Open /hooks once in Claude Code (or restart it).' -ForegroundColor Blue
Write-Host ''
Write-Host '  Claude Code only watches directories that already had a settings file when'
Write-Host '  the session started. A freshly created .claude/settings.local.json is not'
Write-Host '  picked up until the config is reloaded -- the hooks are correct, just not'
Write-Host '  live yet.'
Write-Host ''
Write-Host '  Then re-run  .\verify.ps1  to confirm the hooks actually fire.'
