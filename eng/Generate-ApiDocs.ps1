<#
.SYNOPSIS
Generates ECMA API XML from the prepared package workspace.

.DESCRIPTION
Selects one reference-first assembly asset for each product package, runs mdoc
with its adjacent compiler XML, and replaces generated output while preserving
OpenPublishing infrastructure and deferred Uno output. Run MDoc.ps1 first to
install the pinned tool; this script does not mutate artifacts/downloads.

.EXAMPLE
./eng/Generate-ApiDocs.ps1

Generates SkiaSharpAPI from artifacts/workspace.
#>
[CmdletBinding()]
param(
    [switch] $MDocDebug,
    [string] $WorkspaceRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts/workspace'),
    [string] $OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'SkiaSharpAPI')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'MDoc.ps1')
$ProductRoot = Join-Path $WorkspaceRoot 'products'
$DependencyRoot = Join-Path $WorkspaceRoot 'dependencies'
$MediaRoot = Join-Path (Split-Path -Parent $WorkspaceRoot) 'downloads/transport/media'

function Get-FrameworkRank([string] $framework) {
    if ($framework -eq 'net10.0') { return 0 }
    if ($framework -like 'net10.0-*') { return 1 }
    if ($framework -eq 'netstandard2.0') { return 2 }
    if ($framework -eq 'netstandard2.1') { return 3 }
    if ($framework -eq 'net9.0') { return 4 }
    if ($framework -like 'net9.0-*') { return 5 }
    if ($framework -eq 'net6.0') { return 6 }
    return 10
}

# Find managed product assemblies and require the compiler XML beside every one.
$assets = foreach ($assembly in @(Get-ChildItem -LiteralPath $ProductRoot -Filter '*.dll' -File -Recurse)) {
    $relativePath = $assembly.FullName.Substring($ProductRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
    if ($relativePath -notmatch '[\\/](ref|lib)[\\/]([^\\/]+)[\\/]') {
        continue
    }
    $packageId = $relativePath.Split([IO.Path]::DirectorySeparatorChar)[0]
    if ($packageId -eq 'SkiaSharp.Views.Uno.WinUI') {
        continue
    }
    $documentation = [IO.Path]::ChangeExtension($assembly.FullName, '.xml')
    if (-not (Test-Path -LiteralPath $documentation)) {
        throw "Missing adjacent compiler XML for '$relativePath'."
    }
    [PSCustomObject]@{
        PackageId = $packageId
        Assembly = $assembly
        Documentation = $documentation
        Role = $Matches[1]
        Framework = $Matches[2]
    }
}

# Keep one ref-first asset for each package and assembly name.
$selectedAssets = @($assets | Group-Object { "$($_.PackageId)|$($_.Assembly.Name)" } | ForEach-Object {
    $_.Group | Sort-Object @{ Expression = { if ($_.Role -eq 'ref') { 0 } else { 1 } } },
        @{ Expression = { Get-FrameworkRank $_.Framework } }, Framework | Select-Object -First 1
} | Sort-Object PackageId, @{ Expression = { $_.Assembly.Name } })
if ($selectedAssets.Count -eq 0) {
    throw "No documentable product assets were found under '$ProductRoot'."
}

# Generate ECMA structure into a disposable staging directory.
$stagingRoot = Join-Path (Split-Path -Parent $OutputRoot) '.SkiaSharpAPI.staging'
Remove-Item -Recurse -Force $stagingRoot -ErrorAction Ignore
New-Item -ItemType Directory -Force $stagingRoot | Out-Null

$arguments = @('update', '--delete', '--use-docid', '--out', $stagingRoot, '--lib', $DependencyRoot) +
    @($selectedAssets | ForEach-Object { $_.Assembly.FullName })
if ($MDocDebug) {
    $arguments += '--debug'
}
Invoke-MDoc -Arguments $arguments

# Import compiler XML prose for each selected assembly.
foreach ($asset in $selectedAssets) {
    Invoke-MDoc -Arguments @(
        'update',
        '--preserve',
        '--out', $stagingRoot,
        '--lib', $DependencyRoot,
        '--lib', $ProductRoot,
        '--import', $asset.Documentation,
        $asset.Assembly.FullName
    )
}

# Replace only generated API output and preserve docset infrastructure and deferred Uno pages.
$preservedItems = @('docfx.json', '_filter.xml', 'SkiaSharpAPI-breadcrumb', 'xml', 'SkiaSharp.Views.Windows')
Get-ChildItem -LiteralPath $OutputRoot -Force |
    Where-Object { $_.Name -notin $preservedItems } |
    Remove-Item -Recurse -Force
Get-ChildItem -LiteralPath $stagingRoot -Force |
    Where-Object { $_.Name -notin $preservedItems } |
    Copy-Item -Destination $OutputRoot -Recurse -Force

# Replace the published image set from Fetch's clean media directory.
if (@(Get-ChildItem -LiteralPath $MediaRoot -File).Count -gt 0) {
    $outputImages = Join-Path $OutputRoot 'images'
    Remove-Item -Recurse -Force $outputImages -ErrorAction Ignore
    Copy-Item -LiteralPath $MediaRoot -Destination $outputImages -Recurse -Force
}

# Remove the staging tree after its generated contents have been promoted.
Remove-Item -Recurse -Force $stagingRoot

Write-Host "Generated API documentation from $($selectedAssets.Count) selected assemblies."
