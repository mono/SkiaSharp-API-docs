[CmdletBinding(PositionalBinding = $false)]
param(
    [string] $PackageSource = 'https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-public/nuget/v3/index.json',
    [string] $PackageVersion,
    [string] $ToolsPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts/api-docs/tools'),
    [string] $DownloadCacheRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts/api-docs/downloads'),
    [Parameter(ValueFromRemainingArguments)]
    [string[]] $MdocArguments
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'ApiDocs.Common.psm1') -Force -DisableNameChecking

# Validate that the wrapper can invoke a .NET-hosted mdoc command.
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw 'The .NET SDK required to run mdoc is not available.'
}
if (-not $MdocArguments) {
    throw 'Specify an mdoc command and its arguments.'
}

# Find the cached tool or acquire mdoc from the allowed dotnet-public feed.
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$mdocPath = Get-ChildItem -Path $ToolsPath -Filter mdoc.dll -Recurse -ErrorAction Ignore |
    Where-Object { $_.FullName -match '[\\/]tools[\\/]net6\.0[\\/]' } |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $mdocPath) {
    New-Item -ItemType Directory -Force -Path $ToolsPath | Out-Null
    [void](Download-NuGetPackage 'mdoc' $PackageVersion $PackageSource $ToolsPath $DownloadCacheRoot (Join-Path $repositoryRoot 'NuGet.Config'))
    $mdocPath = Get-ChildItem -Path $ToolsPath -Filter mdoc.dll -Recurse |
        Where-Object { $_.FullName -match '[\\/]tools[\\/]net6\.0[\\/]' } |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $mdocPath) {
    throw "No mdoc tools/net6.0/mdoc.dll was found in '$ToolsPath'."
}

# Forward the caller's mdoc command and preserve its exit code.
& dotnet $mdocPath @MdocArguments
