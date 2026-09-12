[CmdletBinding()]
param(
    [string] $ArtifactRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts/api-docs'),
    [string] $OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'SkiaSharpAPI')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Only these items are OpenPublishing infrastructure, never generated API content.
$preservedOutputItems = @('docfx.json', '_filter.xml', 'SkiaSharpAPI-breadcrumb', 'xml')
if (Test-Path $OutputRoot) {
    Get-ChildItem -Path $OutputRoot -Force |
        Where-Object { $_.Name -notin $preservedOutputItems } |
        Remove-Item -Recurse -Force
}

# The versioned download cache is intentionally permanent across local reset runs.
if (Test-Path $ArtifactRoot) {
    Get-ChildItem -Path $ArtifactRoot -Force |
        Where-Object { $_.Name -ne 'downloads' } |
        Remove-Item -Recurse -Force
}

Write-Host "Cleared generated API documentation and disposable artifacts; retained '$ArtifactRoot/downloads'."
