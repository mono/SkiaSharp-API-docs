[CmdletBinding()]
param(
    [string] $PackageSource,
    [string] $PackageVersion,
    [string] $DocsMediaPackageVersion,
    [string] $MdocPackageVersion,
    [string] $PackageRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) '.artifacts/api-docs/packages')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw 'The .NET 10 SDK is required to download API documentation packages.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
Remove-Item -Recurse -Force $PackageRoot -ErrorAction Ignore
New-Item -ItemType Directory -Force -Path $PackageRoot | Out-Null

foreach ($package in @(
    @{ Id = '_NuGets'; Version = $PackageVersion },
    @{ Id = '_DocsMedia'; Version = $DocsMediaPackageVersion },
    @{ Id = 'mdoc'; Version = $MdocPackageVersion }
)) {
    $arguments = @(
        'package', 'download', $package.Id, '--prerelease',
        '--output', $PackageRoot,
        '--configfile', (Join-Path $repositoryRoot 'NuGet.Config')
    )
    if ($PackageSource) {
        $arguments += @('--source', $PackageSource)
    }
    if ($package.Version) {
        $arguments += @('--version', $package.Version)
    }

    & dotnet @arguments
    if ($LASTEXITCODE -ne 0) {
        $sourceDescription = if ($PackageSource) { $PackageSource } else { 'the configured dnceng feeds' }
        throw "Downloading $($package.Id) from $sourceDescription failed with exit code $LASTEXITCODE."
    }
}

Write-Host "Prepared API documentation packages in $PackageRoot."
