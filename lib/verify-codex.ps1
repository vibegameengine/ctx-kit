# Verification helpers for ctx-kit's Codex layer. Dot-source only after
# lib\common.ps1, which provides Write-Ok/Write-Fail/Resolve-CodeGraphBinary.
param(
    [Parameter(Mandatory=$true)][string]$ProjectDir,
    [switch]$NoProbe
)

$hooksPath = Join-Path $ProjectDir '.codex\hooks.json'
$runner = Join-Path $ProjectDir '.codex\hooks\ctx-kit-codex.ps1'

Write-Step 'Codex integration'
if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
    Write-Fail 'codex CLI not found'
    return
}

Push-Location $ProjectDir
$mcpList = (& codex mcp list 2>$null | Out-String)
$selected = (& codex mcp get code-graph-mcp --json 2>$null | Out-String)
Pop-Location
$CG = Resolve-CodeGraphBinary
try {
    $transport = ($selected | ConvertFrom-Json).transport
    if ($transport.command -eq $CG -and $transport.cwd -eq $ProjectDir) {
        Write-Ok 'Codex reads the selected project binary and cwd'
    } else {
        Write-Warn 'project MCP config is not active yet; trust/open this project normally in Codex and re-run verify'
    }
} catch { Write-Fail 'codex mcp get did not return a valid transport' }
foreach ($name in @('context-mode', 'code-graph-mcp')) {
    if ($mcpList -match "(?m)^$([regex]::Escape($name))\s.*\benabled\b") {
        Write-Ok "Codex MCP server enabled: $name"
    } elseif ($mcpList -match "(?m)^$([regex]::Escape($name))\s") {
        Write-Fail "Codex MCP server is registered but disabled: $name"
    } else {
        Write-Fail "Codex MCP server missing: $name"
    }
}

if (-not (Test-Path $hooksPath)) {
    Write-Fail 'missing .codex/hooks.json -- run .\install.ps1 -Target Both'
    return
}
try {
    $config = Get-Content $hooksPath -Raw | ConvertFrom-Json
    Write-Ok '.codex/hooks.json is valid JSON'
} catch {
    Write-Fail '.codex/hooks.json is malformed'
    return
}

$required = @{
    'PreToolUse' = @('context-pretooluse')
    'PostToolUse' = @('context-posttooluse', 'index-write')
    'SessionStart' = @('context-sessionstart', 'index-sessionstart')
    'PreCompact' = @('context-precompact')
    'UserPromptSubmit' = @('context-userpromptsubmit', 'index-prompt')
    'Stop' = @('context-stop')
}
foreach ($event in $required.Keys) {
    $handlers = @($config.hooks.$event | ForEach-Object { $_.hooks } | Where-Object { $_ })
    foreach ($action in $required[$event]) {
        if (@($handlers | Where-Object { $_.commandWindows -match [regex]::Escape("-Action $action") }).Count -eq 1) {
            Write-Ok "Codex $event hook present: $action"
        } else {
            Write-Fail "Codex $event hook missing or duplicated: $action"
        }
    }
}

if (Test-Path $runner) { Write-Ok 'Codex hook runner present' }
else { Write-Fail 'Codex hook runner missing' }

if ($NoProbe -or -not (Test-Path $runner)) { return }
$CG = Resolve-CodeGraphBinary
if (-not $CG -or -not (Test-Path (Join-Path $ProjectDir '.code-graph'))) {
    Write-Info 'Codex hook probe skipped (no code-graph index)'
    return
}

& node (Join-Path $PSScriptRoot 'verify-hooks.mjs') --project-dir $ProjectDir --binary $CG --target Codex
if ($LASTEXITCODE -ne 0) { Write-Fail 'configured Codex hook/MCP probe failed' }
