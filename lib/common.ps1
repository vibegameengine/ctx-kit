# Shared helpers for ctx-kit on Windows.
# Dot-sourced by install.ps1 / verify.ps1 / uninstall.ps1 -- not meant to run directly.
#
# Windows PowerShell 5.1 compatible on purpose: it is the shell that is present
# on every Windows box without installing anything, and it is what Claude Code
# spawns for a hook with `"shell": "powershell"` when pwsh is absent.
# No `&&`, no ternary, no `??`, no `-AsHashtable`.

# NOT 'Stop'. In Windows PowerShell 5.1 a native command that writes to stderr
# raises a NativeCommandError; under Stop that kills the script even when the exe
# exited 0. code-graph-mcp writes progress notes to stderr on almost every call.
$ErrorActionPreference = 'Continue'

$Global:CtxKit = @{ Failures = 0; Warnings = 0; Marker = '[ctx-kit]' }

function Write-Step { param([string]$Message) Write-Host ''; Write-Host '==> ' -ForegroundColor Blue -NoNewline; Write-Host $Message }
function Write-Ok   { param([string]$Message) Write-Host '  [OK]   ' -ForegroundColor Green -NoNewline; Write-Host $Message }
function Write-Warn { param([string]$Message) $Global:CtxKit.Warnings++; Write-Host '  [WARN] ' -ForegroundColor Yellow -NoNewline; Write-Host $Message }
function Write-Fail { param([string]$Message) $Global:CtxKit.Failures++; Write-Host '  [FAIL] ' -ForegroundColor Red -NoNewline; Write-Host $Message }
function Write-Info { param([string]$Message) Write-Host "  $Message" -ForegroundColor DarkGray }

function Stop-WithError {
    param([string]$Message)
    Write-Host ''
    Write-Host 'error: ' -ForegroundColor Red -NoNewline
    Write-Host $Message
    exit 1
}

function Test-CommandExists {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# ---------------------------------------------------------------------------
# CLI resolution -- the Windows half of the lesson this kit encodes.
#
# On macOS/Linux the trap is a `#!/usr/bin/env node` shim whose shebang cannot
# find node, so the hook dies with a silent exit 127. On Windows that trap does
# not exist: the CLI is a native `code-graph-mcp.exe` that needs neither node nor
# anything on PATH once its path is known.
#
# The Windows trap is the mirror image -- the exe is on PATH *nowhere*. The plugin
# downloads it into its own cache (~/.cache/code-graph/bin) and installs no npm
# shim at all, so `Get-Command code-graph-mcp` finds nothing and an installer that
# relies on PATH concludes the tool is missing on a machine where it is present.
# ---------------------------------------------------------------------------
function Resolve-CodeGraphBinary {
    $cacheFile = Join-Path $env:USERPROFILE '.cache\code-graph\binary-path'
    if (Test-Path $cacheFile) {
        $cached = (Get-Content $cacheFile -Raw).Trim()
        if ($cached -and (Test-Path $cached)) { return $cached }
    }
    $candidates = @(
        $env:CODE_GRAPH_BIN,
        (Join-Path $env:USERPROFILE '.cache\code-graph\bin\code-graph-mcp.exe'),
        (Join-Path $env:LOCALAPPDATA 'code-graph\bin\code-graph-mcp.exe'),
        (Join-Path $env:APPDATA 'npm\node_modules\code-graph-mcp\bin\code-graph-mcp.exe'),
        (Join-Path $env:APPDATA 'npm\code-graph-mcp.cmd')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    $onPath = Get-Command code-graph-mcp -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    return $null
}

# The npm-global CLI shims (compressmcp). On Windows npm writes three files per
# bin -- `name` (sh), `name.cmd`, `name.ps1`. PowerShell can only invoke the .cmd
# or the .ps1; the extensionless sh shim is what Git Bash uses.
function Resolve-NodeCli {
    param([string]$Name)
    $onPath = Get-Command $Name -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    foreach ($ext in @('.cmd', '.ps1', '')) {
        $p = Join-Path $env:APPDATA "npm\$Name$ext"
        if (Test-Path $p) { return $p }
    }
    return $null
}

# The JS entry point behind an npm-global CLI lives in lib/mcp-entry.mjs, not
# here: both platforms need it to register an MCP server as `node <entry>`, and
# one resolver that both installers call cannot disagree with itself.

# ---------------------------------------------------------------------------
# Run a command the way a hook shell sees the world.
#
# The POSIX kit uses `env -i`. The literal translation -- clearing the child's
# environment block -- is WRONG on Windows, in two ways at once.
#
# First, with an empty block CreateProcess fails for every native exe the command
# tries to run, silently, with no output and no exit code. The test then "passes"
# while proving nothing: observed as a hook that "succeeded" in 266 ms on a repo
# whose index takes seven seconds to update.
#
# Second, and worse, it writes to the user's repo. Without SystemDrive /
# ProgramData / ALLUSERSPROFILE, Windows shell components inside the spawned
# process cannot expand %SystemDrive%\ProgramData\Microsoft\Windows\Caches and
# create it LITERALLY, relative to the working directory -- which for this probe
# is the project root. The result is a directory actually named "%SystemDrive%"
# sitting in someone's checkout, full of shell cache files.
#
# What actually differs for a hook on Windows is PATH, so that is what gets
# stripped: down to the system minimum, with the inherited block otherwise
# intact. That is what catches a hook that only works because YOUR shell happens
# to have node / npm / Git Bash on PATH.
# ---------------------------------------------------------------------------
function Invoke-InBareEnv {
    param(
        [string]$Command,
        [string]$WorkingDirectory = $PWD.Path,
        [string]$StdinJson = '{}'
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psi.Arguments = '-NoProfile -NonInteractive -Command "' + ($Command -replace '"', '\"') + '"'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $WorkingDirectory
    $sysPath = "$env:SystemRoot\System32;$env:SystemRoot;$env:SystemRoot\System32\WindowsPowerShell\v1.0"
    $psi.EnvironmentVariables['PATH'] = $sysPath
    $psi.EnvironmentVariables['Path'] = $sysPath
    $psi.EnvironmentVariables['CLAUDE_PROJECT_DIR'] = $WorkingDirectory

    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Write($StdinJson)
    $proc.StandardInput.Close()
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; StdOut = $stdout; StdErr = $stderr }
}

function Resolve-ProjectDir {
    param([string]$Path)
    if (-not $Path) { $Path = $PWD.Path }
    $root = & git -C $Path rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and $root) {
        $native = ConvertTo-WindowsPath ([string]$root).Trim()
        $resolved = Resolve-Path $native -ErrorAction SilentlyContinue
        if ($resolved) { return $resolved.Path }
    }
    $resolved = Resolve-Path $Path -ErrorAction SilentlyContinue
    if (-not $resolved) { Stop-WithError "no such directory: $Path" }
    return $resolved.Path
}

# git prints a forward-slash path, and WHICH forward-slash path depends on the
# git build: git.exe answers `C:/src/repo`, while the Git-Bash-flavoured one
# answers the MSYS form `/c/src/repo`. Naively swapping the slashes turns the
# second into `\c\src\repo`, which Resolve-Path then anchors to the current
# drive -- `C:\c\src\repo`, a path that does not exist. Handle both.
function ConvertTo-WindowsPath {
    param([string]$Path)
    if ($Path -match '^/([a-zA-Z])/(.*)$') { $Path = $Matches[1].ToUpper() + ':/' + $Matches[2] }
    return ($Path -replace '/', '\')
}

# Is a path ignored, as git will see it from the shell the user actually commits
# from?
#
# On Windows that is not one question. Git's global excludes file lives at
# $XDG_CONFIG_HOME/git/ignore, and with XDG unset it falls back to ~/.config,
# where `~` means $HOME. Git Bash exports HOME; PowerShell and cmd do not, and
# git.exe does not synthesise it here. So the SAME repo answers differently
# depending on where you ask from:
#
#   git bash    -> ignored   (global excludes found)
#   powershell  -> NOT ignored
#
# A verifier that asked only from PowerShell would report a false failure for
# anyone whose ignore rule lives in the global file. Ask the way Git Bash would.
function Test-GitIgnored {
    param([string]$ProjectDir, [string]$PathSpec)
    $hadHome = [bool]$env:HOME
    $restore = $env:HOME
    if (-not $hadHome) { $env:HOME = $env:USERPROFILE }
    & git -C $ProjectDir check-ignore -q $PathSpec 2>$null
    $ignored = ($LASTEXITCODE -eq 0)
    if ($hadHome) { $env:HOME = $restore } else { Remove-Item Env:HOME -ErrorAction SilentlyContinue }
    return $ignored
}

# The kit's own hooks, read back out of a settings file. `-like '*[ctx-kit]*'`
# looks right and silently is not: [] is a wildcard character class, so the
# pattern throws "not a valid wildcard pattern". Match on the literal instead.
function Get-KitHook {
    param([object]$Settings, [string]$Event)
    if (-not $Settings.hooks) { return @() }
    $groups = $Settings.hooks.$Event
    if (-not $groups) { return @() }
    return @($groups | ForEach-Object { $_.hooks } | Where-Object {
        $_.description -and $_.description.Contains($Global:CtxKit.Marker)
    })
}
