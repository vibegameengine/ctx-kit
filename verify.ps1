<#
.SYNOPSIS
  ctx-kit -- verify every layer on Windows, with evidence rather than config-reading.

.DESCRIPTION
  The Windows counterpart of verify.sh. Exits non-zero if any check fails.

  The check that matters most is the stripped-PATH probe: it extracts the hook
  command FROM the settings file, runs it with PATH cut down to the system
  minimum, and then proves a brand-new symbol reached the graph. Reading the JSON
  back only proves the JSON is what we wrote.

.EXAMPLE
  .\verify.ps1
.EXAMPLE
  .\verify.ps1 -ProjectDir C:\src\myrepo -NoProbe
#>
[CmdletBinding()]
param(
    [string]$ProjectDir,
    [switch]$NoProbe
)

$KitDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $KitDir 'lib\common.ps1')

$ProjectDir = Resolve-ProjectDir $ProjectDir
$SettingsPath = Join-Path $ProjectDir '.claude\settings.local.json'

# ---------------------------------------------------------------------------
Write-Step 'Toolchain'
# ---------------------------------------------------------------------------
$CG = Resolve-CodeGraphBinary
if ($CG) { Write-Ok "code-graph-mcp -> $CG" }
else { Write-Fail 'code-graph-mcp not found (plugin not installed, or its binary never downloaded -- re-run .\install.ps1)' }

$CMCP = Resolve-NodeCli 'compressmcp'
if ($CMCP) { Write-Ok "compressmcp -> $CMCP" }
else { Write-Warn 'compressmcp not found (optional)' }

# ---------------------------------------------------------------------------
Write-Step 'Plugins'
# ---------------------------------------------------------------------------
$plugins = (& claude plugin list 2>$null | Out-String)
foreach ($p in @('context-mode', 'code-graph-mcp')) {
    if ($plugins -match [regex]::Escape($p)) {
        $ver = ''
        if ($plugins -match "$([regex]::Escape($p))@[^\r\n]*\r?\n\s*Version:\s*([^\r\n]+)") { $ver = " (v$($Matches[1].Trim()))" }
        Write-Ok "$p installed$ver"
    } else {
        Write-Fail "$p not installed"
    }
}

# ---------------------------------------------------------------------------
Write-Step 'compressmcp wiring'
# ---------------------------------------------------------------------------
if ($CMCP) {
    $status = (& $CMCP check 2>&1 | Out-String)
    # Matched on the WORD, not the tick compressmcp prints: this file is
    # deliberately pure ASCII. Windows PowerShell 5.1 reads a BOM-less script as
    # the ANSI code page, where a UTF-8 tick decodes to bytes including 0x93 --
    # a smart quote, which PowerShell accepts as a string delimiter. One tick,
    # even inside a comment, and the whole script fails to parse.
    if ($status -match '\(compress\):\s+\S+\s+installed') { Write-Ok 'PostToolUse compress hook' } else { Write-Fail 'PostToolUse compress hook missing' }

    # NOT `compressmcp check`, and NOT the settings file. Its installer writes
    # mcpServers into ~/.claude/settings.json, and Claude Code does not read MCP
    # config from there at all -- servers live in ~/.claude.json (local/user
    # scope) or a project .mcp.json. So the entry is real, `compressmcp check`
    # reports it as registered, any verifier that reads the same file agrees,
    # and the server has never once started. Ask the only component whose
    # opinion decides. (Matched on the word, not the tick: ASCII-only file.)
    $mcpList = (& claude mcp list 2>$null | Out-String)
    if ($mcpList -match '(?m)^compressmcp:.*Connected') {
        Write-Ok 'MCP server connected (confirmed by claude mcp list)'
    } elseif ($mcpList -match '(?m)^compressmcp:') {
        Write-Fail 'MCP server registered but not connecting -- run: claude mcp get compressmcp'
    } else {
        Write-Fail 'MCP server not registered where Claude Code reads it (~\.claude.json) -- re-run .\install.ps1'
    }

    $globalSettings = Join-Path $env:USERPROFILE '.claude\settings.json'
    if (Test-Path $globalSettings) {
        # `compressmcp check` reports the status line as missing whenever
        # something else owns settings.json -> statusLine. That is a false alarm
        # when code-graph's composite has adopted it as a provider.
        if ($status -match 'Status line:\s+\S+\s+not configured') {
            $providers = Join-Path $env:USERPROFILE '.claude\statusline-providers.json'
            if ((Test-Path $providers) -and ((Get-Content $providers -Raw) -match 'compressmcp --status')) {
                Write-Ok 'status line chained via the code-graph composite (compressmcp own check is a false negative here)'
            } else {
                Write-Warn 'status line not configured (cosmetic only)'
            }
        } else {
            Write-Ok 'status line configured'
        }
    }
}

# ---------------------------------------------------------------------------
Write-Step 'Project settings'
# ---------------------------------------------------------------------------
$settings = $null
if (-not (Test-Path $SettingsPath)) {
    Write-Fail "missing $SettingsPath -- run .\install.ps1"
} else {
    try {
        $settings = Get-Content $SettingsPath -Raw | ConvertFrom-Json
        Write-Ok 'settings.local.json is valid JSON'
    } catch {
        Write-Fail 'settings.local.json is malformed -- this silently disables ALL settings in it'
    }

    if ($settings) {
        if ($settings.env.CODE_GRAPH_HOOK_INDEX -eq 'on') { Write-Ok 'env CODE_GRAPH_HOOK_INDEX=on' }
        else { Write-Fail "env CODE_GRAPH_HOOK_INDEX not set to 'on'" }

        foreach ($ev in @('SessionStart', 'UserPromptSubmit')) {
            # @() is load-bearing: PowerShell unwraps a one-element pipeline into
            # the element itself, and `.Count` on a single PSCustomObject is $null
            # in 5.1 -- the check would report "expected 1, found " forever.
            $found = @(Get-KitHook -Settings $settings -Event $ev)
            if ($found.Count -eq 1) {
                if ($found[0].shell -eq 'powershell') {
                    Write-Ok "$ev hook present (shell: powershell)"
                } else {
                    # Not a failure: a bash hook works IF Git Bash is installed.
                    # It is a warning because nothing tells you when it is not.
                    Write-Warn "$ev hook present but not pinned to PowerShell -- it silently does nothing on a machine without Git for Windows"
                }
            } else {
                Write-Fail "$ev hook: expected 1, found $($found.Count)"
            }
        }
    }

    if ($env:CODE_GRAPH_HOOK_INDEX -eq 'on') {
        Write-Ok "CODE_GRAPH_HOOK_INDEX is live in this shell's session"
    } else {
        Write-Warn 'CODE_GRAPH_HOOK_INDEX not visible in the environment -- open /hooks once or restart Claude Code'
    }
}

# ---------------------------------------------------------------------------
Write-Step 'Git hygiene'
# ---------------------------------------------------------------------------
& git -C $ProjectDir rev-parse --git-dir *> $null
if ($LASTEXITCODE -eq 0) {
    foreach ($entry in @('.claude/settings.local.json', '.code-graph')) {
        if (Test-GitIgnored -ProjectDir $ProjectDir -PathSpec $entry) { Write-Ok "$entry is gitignored" }
        else { Write-Fail "$entry is NOT gitignored (it holds absolute machine paths / a large local DB)" }
    }
} else {
    Write-Info 'not a git repo -- skipped'
}

# ---------------------------------------------------------------------------
Write-Step 'Index health'
# ---------------------------------------------------------------------------
$indexDir = Join-Path $ProjectDir '.code-graph'
if ($CG -and (Test-Path $indexDir)) {
    Push-Location $ProjectDir
    $health = (& $CG health-check 2>&1 | Out-String)
    Pop-Location
    $first = ($health -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    if ($health -match '(?m)^OK:') { Write-Ok $first.Trim() } else { Write-Fail $first.Trim() }

    $vec = ($health -split "`n" | Where-Object { $_ -match '(?i)^Search:' } | Select-Object -First 1)
    if ($vec -match '(?i)vector inactive') {
        Write-Warn 'semantic search is keyword-only (FTS5/BM25), not vector -- run .\install-model.ps1'
    } else {
        if ($vec) { Write-Ok $vec.Trim() } else { Write-Ok 'vector search active' }
        if ($vec -match '(?i)in progress') { Write-Info 'embedding coverage still filling -- re-run .\install-model.ps1 to finish' }
    }
} elseif ($CG) {
    Write-Fail "no .code-graph\ index in $ProjectDir -- run .\install.ps1"
}

# ---------------------------------------------------------------------------
Write-Step 'Hook probe (stripped PATH)'
# ---------------------------------------------------------------------------
if ($NoProbe) {
    Write-Info 'skipped (-NoProbe)'
} elseif (-not $CG -or -not $settings -or -not (Test-Path $indexDir)) {
    Write-Info 'skipped (prerequisites missing)'
} else {
    # The probe must land somewhere the indexer actually walks: .code-graph\ is
    # gitignored and skipped, so a probe there would never be indexed and this
    # check would report a false failure.
    $probeDir = $ProjectDir
    foreach ($d in @('src', 'lib', 'app', 'source')) {
        $candidate = Join-Path $ProjectDir $d
        if (Test-Path $candidate) { $probeDir = $candidate; break }
    }
    $stamp = Join-Path $indexDir '.auto-index-stamp'
    $stampBak = $null
    if (Test-Path $stamp) { $stampBak = (Get-Content $stamp -Raw) }

    # BOTH hooks, not just one. They are nearly the same command, and "nearly"
    # is exactly what a probe exists to catch: they differ in the throttle, in
    # the stdin they are handed, and in which of them a broken exit code takes
    # down (a non-zero UserPromptSubmit hook blocks every prompt). Verifying one
    # and asserting the other's mere presence is how a dead SessionStart hook
    # sits unnoticed for weeks.
    foreach ($ev in @('SessionStart', 'UserPromptSubmit')) {
        $hook = @(Get-KitHook -Settings $settings -Event $ev)[0]
        if (-not $hook) {
            Write-Fail "could not extract the $ev hook command from settings"
            continue
        }

        $sym = "ctxKitProbe$ev$(Get-Random -Maximum 999999)"
        $probeFile = Join-Path $probeDir "__ctx_kit_probe_${ev}_$PID.ts"
        "export function $sym(): number { return 1; }" | Set-Content -Path $probeFile -Encoding ascii
        # Cleared so the throttled hook cannot decide it ran recently enough.
        Remove-Item $stamp -Force -ErrorAction SilentlyContinue

        $stdin = if ($ev -eq 'SessionStart') { '{"source":"startup"}' } else { '{"prompt":"probe"}' }
        $run = Invoke-InBareEnv -Command $hook.command -WorkingDirectory $ProjectDir -StdinJson $stdin
        if ($run.ExitCode -ne 0) {
            Write-Fail "$ev exited $($run.ExitCode) with a stripped PATH -- it would fail silently"
        } else {
            Write-Ok "$ev exits 0 with only system paths on PATH (no node, no npm, no Git Bash)"
        }

        # Every query runs FROM the project: the CLI resolves .code-graph\ against
        # the current directory, so a search made from wherever the operator
        # happened to be standing reads a DIFFERENT repo's index -- and reports
        # this probe as a failure while the hook did its job perfectly.
        Push-Location $ProjectDir
        $hit = (& $CG search $sym 2>$null | Out-String)
        Pop-Location
        if ($hit -match $sym) { Write-Ok "$ev put a brand-new symbol into the graph" }
        else { Write-Fail "$ev ran but the new symbol never reached the graph" }

        Remove-Item $probeFile -Force -ErrorAction SilentlyContinue
        Remove-Item $stamp -Force -ErrorAction SilentlyContinue
        Push-Location $ProjectDir
        & $CG incremental-index --quiet *> $null
        $still = (& $CG search $sym 2>$null | Out-String)
        Pop-Location
        # ${ev} not $ev: a colon straight after a variable name makes PowerShell
        # read it as a scope qualifier (the $env:PATH form) and refuse to parse.
        if ($still -match $sym) { Write-Fail "${ev}: deleted probe still in the graph -- deletions are not being reindexed" }
        else { Write-Ok "${ev}: deleting the file removed it from the graph" }
    }

    if ($stampBak) { Set-Content -Path $stamp -Value $stampBak -NoNewline -Encoding ascii }
    else { Remove-Item $stamp -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------
Write-Host ''
if ($Global:CtxKit.Failures -gt 0) {
    Write-Host "$($Global:CtxKit.Failures) failed" -ForegroundColor Red -NoNewline
    Write-Host ", $($Global:CtxKit.Warnings) warnings"
    exit 1
}
Write-Host 'All checks passed' -ForegroundColor Green -NoNewline
Write-Host " ($($Global:CtxKit.Warnings) warnings)"
