[CmdletBinding()]
param(
    [string] $PackageSource = 'https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-libraries-transport/nuget/v3/index.json'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

& dotnet workload install android ios maccatalyst macos tvos maui `
    --skip-manifest-update `
    --configfile (Join-Path (Split-Path -Parent $PSScriptRoot) 'NuGet.Config')
if ($LASTEXITCODE -ne 0) {
    throw "Installing API documentation workloads failed with exit code $LASTEXITCODE."
}

& (Join-Path $PSScriptRoot 'Generate-ApiDocs.ps1') -PackageSource $PackageSource
