[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $SourcePath)) {
    throw "Action launcher source not found: $SourcePath"
}

Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue

$source = Get-Content -Raw -LiteralPath $SourcePath
Add-Type `
    -TypeDefinition $source `
    -Language CSharp `
    -OutputAssembly $OutputPath `
    -OutputType WindowsApplication

if (-not (Test-Path -LiteralPath $OutputPath)) {
    throw "Action launcher was not created: $OutputPath"
}
