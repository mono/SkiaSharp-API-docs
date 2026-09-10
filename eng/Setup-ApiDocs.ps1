[CmdletBinding()]
param(
    [string] $TransportPackageSource = 'https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-libraries-transport/nuget/v3/index.json',
    [string] $PackageSource,
    [string] $PackageVersion,
    [string] $DocsMediaPackageVersion,
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
    @{ Id = '_NuGets'; Version = $PackageVersion; Source = $TransportPackageSource },
    @{ Id = '_DocsMedia'; Version = $DocsMediaPackageVersion; Source = $TransportPackageSource }
)) {
    $source = if ($PackageSource) { $PackageSource } else { $package.Source }
    $arguments = @(
        'package', 'download', $package.Id, '--prerelease',
        '--output', $PackageRoot,
        '--configfile', (Join-Path $repositoryRoot 'NuGet.Config'),
        '--source', $source
    )
    if ($package.Version) {
        $arguments += @('--version', $package.Version)
    }

    & dotnet @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Downloading $($package.Id) from '$source' failed with exit code $LASTEXITCODE."
    }
}

Write-Host "Prepared API documentation packages in $PackageRoot."
