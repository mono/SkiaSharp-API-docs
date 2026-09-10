[CmdletBinding()]
param(
    [string] $PackageSource = 'https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-public/nuget/v3/index.json',
    [string] $PackageVersion,
    [string] $ToolsPath = (Join-Path (Split-Path -Parent $PSScriptRoot) '.artifacts/api-docs/tools'),
    [Parameter(ValueFromRemainingArguments)]
    [string[]] $MdocArguments
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw 'The .NET SDK required to run mdoc is not available.'
}
if (-not $MdocArguments) {
    throw 'Specify an mdoc command and its arguments.'
}

$mdocPath = Get-ChildItem -Path $ToolsPath -Filter mdoc.dll -Recurse -ErrorAction Ignore |
    Where-Object { $_.FullName -match '[\\/]tools[\\/]net6\.0[\\/]' } |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $mdocPath) {
    New-Item -ItemType Directory -Force -Path $ToolsPath | Out-Null
    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    $downloadArguments = @(
        'package', 'download', 'mdoc', '--prerelease',
        '--output', $ToolsPath,
        '--configfile', (Join-Path $repositoryRoot 'NuGet.Config'),
        '--source', $PackageSource
    )
    if ($PackageVersion) {
        $downloadArguments += @('--version', $PackageVersion)
    }

    & dotnet @downloadArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Downloading mdoc from '$PackageSource' failed with exit code $LASTEXITCODE."
    }
    $mdocPath = Get-ChildItem -Path $ToolsPath -Filter mdoc.dll -Recurse |
        Where-Object { $_.FullName -match '[\\/]tools[\\/]net6\.0[\\/]' } |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $mdocPath) {
    throw "No mdoc tools/net6.0/mdoc.dll was found in '$ToolsPath'."
}

& dotnet $mdocPath @MdocArguments
