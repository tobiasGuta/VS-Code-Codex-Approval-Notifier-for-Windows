[CmdletBinding()]
param(
    [string]$ShimDirectory = (Join-Path $PSScriptRoot 'shim-build')
)

$ErrorActionPreference = 'Stop'

$shim = Join-Path $ShimDirectory 'CodexAppServerShim.exe'
$targetFile = Join-Path $ShimDirectory 'CodexAppServerShim.target'
if (-not (Test-Path -LiteralPath $shim -PathType Leaf)) {
    throw "Shim executable not found: $shim"
}
if (-not (Test-Path -LiteralPath $targetFile -PathType Leaf)) {
    throw "Shim target file not found: $targetFile"
}

$target = (Get-Content -LiteralPath $targetFile -Raw -Encoding UTF8).Trim()
if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
    throw "Configured Codex target not found: $target"
}

function Invoke-Capture {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $output = @(& $Path @Arguments 2>&1 | ForEach-Object { [string]$_ })
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = $output
        Text     = ($output -join "`n")
    }
}

Write-Host '# Codex App-Server Shim Acceptance'
Write-Host "Shim:   $shim"
Write-Host "Target: $target"
Write-Host ''

$targetVersion = Invoke-Capture -Path $target -Arguments @('--version')
$shimVersion = Invoke-Capture -Path $shim -Arguments @('--version')

Write-Host "Target version exit: $($targetVersion.ExitCode)"
Write-Host "Shim version exit:   $($shimVersion.ExitCode)"
Write-Host "Version output equal: $($targetVersion.Text -eq $shimVersion.Text)"

if ($targetVersion.ExitCode -ne $shimVersion.ExitCode -or $targetVersion.Text -ne $shimVersion.Text) {
    throw 'Version passthrough failed.'
}

$targetHelp = Invoke-Capture -Path $target -Arguments @('app-server', '--help')
$shimHelp = Invoke-Capture -Path $shim -Arguments @('app-server', '--help')

Write-Host "App-server help exit equal: $($targetHelp.ExitCode -eq $shimHelp.ExitCode)"
Write-Host "App-server help output equal: $($targetHelp.Text -eq $shimHelp.Text)"

if ($targetHelp.ExitCode -ne $shimHelp.ExitCode -or $targetHelp.Text -ne $shimHelp.Text) {
    throw 'App-server help passthrough failed.'
}

$targetSchemaHelp = Invoke-Capture -Path $target -Arguments @('app-server', 'generate-json-schema', '--help')
$shimSchemaHelp = Invoke-Capture -Path $shim -Arguments @('app-server', 'generate-json-schema', '--help')

Write-Host "Schema tooling passthrough equal: $($targetSchemaHelp.ExitCode -eq $shimSchemaHelp.ExitCode -and $targetSchemaHelp.Text -eq $shimSchemaHelp.Text)"

if ($targetSchemaHelp.ExitCode -ne $shimSchemaHelp.ExitCode -or $targetSchemaHelp.Text -ne $shimSchemaHelp.Text) {
    throw 'App-server tooling passthrough failed.'
}

# Starting a live stdio app-server would block waiting for JSON-RPC input, so this
# acceptance test intentionally does not launch one. The live VS Code acceptance
# step will inspect the child command line after chatgpt.cliExecutable is changed.

Write-Host ''
Write-Host 'PASS: non-server and app-server tooling invocations are transparent.'
Write-Host 'No live app-server was started by this test.'
