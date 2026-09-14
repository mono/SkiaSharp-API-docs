[CmdletBinding()]
param(
    [switch] $ClearCache,
    [string] $ArtifactRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts'),
    [string] $OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'SkiaSharpAPI')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# These files belong to the OpenPublishing docset rather than generated ECMA output.
$preservedOutputItems = @(
    'docfx.json',
    '_filter.xml',
    'SkiaSharpAPI-breadcrumb',
    'xml'
)

if (Test-Path -LiteralPath $OutputRoot -PathType Container) {
    Get-ChildItem -LiteralPath $OutputRoot -Force |
        Where-Object { $_.Name -notin $preservedOutputItems } |
        Remove-Item -Recurse -Force
}

if (Test-Path -LiteralPath $ArtifactRoot -PathType Container) {
    Get-ChildItem -LiteralPath $ArtifactRoot -Force |
        Where-Object { $_.Name -ne 'local' -and ($ClearCache -or $_.Name -ne 'downloads') } |
        Remove-Item -Recurse -Force
}

Write-Host 'Cleared generated API documentation and disposable work artifacts.'
if (-not $ClearCache) {
    Write-Host "Retained '$ArtifactRoot/local' and '$ArtifactRoot/downloads'; pass -ClearCache to remove downloads."
}
