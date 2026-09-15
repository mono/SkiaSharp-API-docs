<#
.SYNOPSIS
Fetches the transport package set used to generate the API documentation.

.DESCRIPTION
Downloads _NuGets, its dependency chunks, and _DocsMedia from a NuGet feed or
local folder source. It expands the embedded product packages into the reusable
download cache; it does not generate documentation.

.EXAMPLE
./eng/Fetch-ApiDocs.ps1 -PackageVersion '0.0.0-pr.5064.2156' -TransportSource ./artifacts/local

Fetches the supplied CI artifacts from the local NuGet source.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $PackageVersion,
    [string] $TransportSource = 'https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-libraries-transport/nuget/v3/index.json',
    [string] $TransportRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts/downloads/transport')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Normalize a local feed path because dotnet package download requires an absolute source.
if (Test-Path -LiteralPath $TransportSource -PathType Container) {
    $TransportSource = (Resolve-Path -LiteralPath $TransportSource).Path
}

# Rebuild the transport cache from the requested feed or local CI artifact source.
Remove-Item -Recurse -Force $TransportRoot -ErrorAction Ignore
New-Item -ItemType Directory -Force $TransportRoot | Out-Null
foreach ($packageId in '_NuGets', '_DocsMedia') {
    dotnet package download "$packageId@$PackageVersion" --prerelease --source $TransportSource --output $TransportRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Downloading $packageId $PackageVersion failed."
    }
}

# Read the meta-package to fetch every transport dependency chunk at the same version.
$metaPackage = Get-ChildItem -LiteralPath $TransportRoot -Filter "_NuGets.$PackageVersion.nupkg" -File -Recurse | Select-Object -First 1
if ($null -eq $metaPackage) {
    throw "Expected _NuGets $PackageVersion under '$TransportRoot'."
}

Import-Module (Join-Path $PSScriptRoot 'ApiDocs.Common.psm1') -Force
foreach ($dependency in Get-NuGetPackageDependencies $metaPackage.FullName) {
    if ($dependency.Id -notlike '_NuGets.Dependencies.*') {
        continue
    }
    dotnet package download "$($dependency.Id)@$($dependency.Version)" --prerelease --source $TransportSource --output $TransportRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Downloading $($dependency.Id) $($dependency.Version) failed."
    }
}

# Expose the embedded product archives as a local NuGet source for Prepare.
$productSource = Join-Path $TransportRoot 'packages'
Expand-TransportPackages $TransportRoot $productSource | Out-Null

# Extract only the published documentation images into a clean media directory.
$mediaPackage = Get-ChildItem -LiteralPath $TransportRoot -Filter '_DocsMedia.*.nupkg' -File -Recurse | Select-Object -First 1
$mediaRoot = Join-Path $TransportRoot 'media'
Remove-Item -Recurse -Force $mediaRoot -ErrorAction Ignore
New-Item -ItemType Directory -Force $mediaRoot | Out-Null
$temporaryMediaRoot = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
try {
    Expand-Archive -LiteralPath $mediaPackage.FullName -DestinationPath $temporaryMediaRoot -Force
    Get-ChildItem -LiteralPath (Join-Path $temporaryMediaRoot 'images') -File |
        Copy-Item -Destination $mediaRoot -Force
}
finally {
    Remove-Item -Recurse -Force $temporaryMediaRoot -ErrorAction Ignore
}
Write-Host "Fetched transport packages and expanded product archives for $PackageVersion into '$TransportRoot'."
