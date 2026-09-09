[CmdletBinding()]
param(
    [string] $PackageSource = 'https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-libraries-transport/nuget/v3/index.json',
    [string] $MdocPackageSource = 'https://api.nuget.org/v3/index.json',
    [string] $PackageVersion,
    [string[]] $AdditionalReferencePath = @(),
    [switch] $KeepStaging
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$apiRoot = Join-Path $repositoryRoot 'SkiaSharpAPI'
$workRoot = Join-Path $repositoryRoot '.artifacts/api-docs'
$packagesPath = Join-Path $workRoot 'packages'
$extractedPackagesPath = Join-Path $workRoot 'extracted-packages'
$stagingPath = Join-Path $workRoot 'staging'
$mdocPath = Join-Path $workRoot 'mdoc'
$dotnetRoot = Join-Path $repositoryRoot '.artifacts/dotnet-sdk'
$dotnetRuntime = Join-Path $dotnetRoot ($(if ($IsWindows) { 'dotnet.exe' } else { 'dotnet' }))

function Get-ServiceResource([string] $source, [string] $resourceType) {
    $serviceIndex = Invoke-RestMethod -Uri $source
    $resource = $serviceIndex.resources |
        Where-Object { $_.'@type' -like "$resourceType*" } |
        Select-Object -First 1

    if ($null -eq $resource) {
        throw "The package source '$source' does not expose a $resourceType resource."
    }

    return $resource.'@id'.TrimEnd('/')
}

function Get-LatestPackageVersion([string] $flatContainer, [string] $packageId) {
    $versions = (Invoke-RestMethod -Uri "$flatContainer/$($packageId.ToLowerInvariant())/index.json").versions
    $stableVersions = $versions | Where-Object { $_ -notmatch '-' }
    if ($stableVersions.Count -eq 0) {
        throw "No stable version of '$packageId' is available from '$PackageSource'."
    }

    return $stableVersions |
        Sort-Object { [version](($_ -split '-')[0]) } -Descending |
        Select-Object -First 1
}

function Save-Package([string] $flatContainer, [string] $packageId, [string] $version) {
    $normalizedId = $packageId.ToLowerInvariant()
    $normalizedVersion = $version.ToLowerInvariant()
    $packageFile = Join-Path $packagesPath "$normalizedId.$normalizedVersion.nupkg"
    $extractPath = Join-Path $packagesPath "$normalizedId.$normalizedVersion"

    Invoke-WebRequest `
        -Uri "$flatContainer/$normalizedId/$normalizedVersion/$normalizedId.$normalizedVersion.nupkg" `
        -OutFile $packageFile
    Expand-Archive -Path $packageFile -DestinationPath $extractPath -Force
    return $extractPath
}

function Get-Moniker([string] $packageId) {
    if ($packageId.StartsWith('SkiaSharp.Views.Maui', [StringComparison]::OrdinalIgnoreCase)) {
        return 'skiasharp-views-maui'
    }
    if ($packageId.StartsWith('SkiaSharp.Views', [StringComparison]::OrdinalIgnoreCase)) {
        return 'skiasharp-views'
    }
    if ($packageId.StartsWith('SkiaSharp.Direct3D', [StringComparison]::OrdinalIgnoreCase)) {
        return 'skiasharp-direct3d'
    }
    if ($packageId.StartsWith('SkiaSharp.Vulkan', [StringComparison]::OrdinalIgnoreCase)) {
        return 'skiasharp-vulkan'
    }

    return $packageId.ToLowerInvariant().Replace('.', '-')
}

function Install-DotnetSdk {
    if (Test-Path $dotnetRuntime) {
        return
    }

    $installer = Join-Path $workRoot 'dotnet-install.ps1'
    Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $installer
    & $installer -Channel '10.0' -InstallDir $dotnetRoot -NoPath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $dotnetRuntime)) {
        throw 'Installing the required .NET 10 SDK failed.'
    }
}

$dotnetSdk = Get-Command dotnet -ErrorAction SilentlyContinue
if ($null -eq $dotnetSdk) {
    throw 'The .NET SDK is required to run mdoc.'
}
Remove-Item -Recurse -Force $workRoot -ErrorAction Ignore
New-Item -ItemType Directory -Force -Path $packagesPath, $extractedPackagesPath, $stagingPath, $mdocPath | Out-Null

$mdocFlatContainer = Get-ServiceResource $MdocPackageSource 'PackageBaseAddress'
$metaPackageVersion = if ($PackageVersion) { $PackageVersion } else { '*-*' }
$restoreProject = Join-Path $workRoot 'PackageSet.csproj'
@"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="_NuGets" Version="$metaPackageVersion" />
    <PackageReference Include="GirCore.Gtk-4.0" Version="0.7.0" PrivateAssets="all" />
    <PackageReference Include="GtkSharp" Version="3.24.24.95" PrivateAssets="all" />
    <PackageReference Include="Tizen.NET" Version="12.0.0.18510" PrivateAssets="all" />
    <PackageReference Include="Microsoft.WindowsAppSDK" Version="1.4.230913002" PrivateAssets="all" />
    <PackageReference Include="Microsoft.Windows.CsWinRT" Version="2.1.0" PrivateAssets="all" />
    <PackageDownload Include="Microsoft.NETCore.App.Ref" Version="[10.0.0]" />
    <PackageDownload Include="Microsoft.WindowsDesktop.App.Ref" Version="[10.0.0]" />
  </ItemGroup>
</Project>
"@ | Set-Content -NoNewline -Path $restoreProject

Write-Host "Restoring the _NuGets package set from $PackageSource"
& $dotnetSdk.Source restore $restoreProject `
    --configfile (Join-Path $repositoryRoot 'NuGet.Config') `
    --packages $packagesPath `
    --verbosity minimal
if ($LASTEXITCODE -ne 0) {
    throw "Restoring _NuGets failed with exit code $LASTEXITCODE."
}

$mdocVersion = Get-LatestPackageVersion $mdocFlatContainer 'mdoc'
[void] (Save-Package $mdocFlatContainer 'mdoc' $mdocVersion)
$mdocDll = Get-ChildItem -Path $packagesPath -Filter mdoc.dll -Recurse |
    Where-Object { $_.FullName -match '[\\/]tools[\\/]net6\.0[\\/]' } |
    Select-Object -First 1
if ($null -eq $mdocDll) {
    throw 'The mdoc package did not contain its net6.0 tool.'
}
$referencePath = Get-ChildItem -Path (Join-Path $packagesPath 'microsoft.netcore.app.ref') -Directory -ErrorAction Ignore |
    Where-Object Name -Like '10.0*' |
    ForEach-Object { Join-Path $_.FullName 'ref/net10.0' } |
    Where-Object { Test-Path $_ } |
    Select-Object -First 1
if ($null -eq $referencePath) {
    throw 'The .NET 10 reference pack was not restored.'
}

$frameworks = New-Object System.Xml.XmlDocument
$frameworkRoot = $frameworks.CreateElement('Frameworks')
[void] $frameworks.AppendChild($frameworkRoot)
$monikerDirectories = @()
$downloadedPackages = @()
$packageArchives = Get-ChildItem -Path $packagesPath -Filter '*.nupkg' -Recurse |
    Where-Object { $_.DirectoryName -match '[\\/]tools$' }
foreach ($packageArchive in $packageArchives) {
    $extractPath = Join-Path $extractedPackagesPath ([IO.Path]::GetFileNameWithoutExtension($packageArchive.Name))
    Expand-Archive -Path $packageArchive.FullName -DestinationPath $extractPath -Force
    $nuspec = Get-ChildItem -Path $extractPath -Filter '*.nuspec' | Select-Object -First 1
    [xml] $metadata = Get-Content -Raw -Path $nuspec.FullName
    $packageId = $metadata.package.metadata.id
    if ($packageId -match '^(HarfBuzzSharp|SkiaSharp)(\.|$)' -and
        $packageId -notmatch '^SkiaSharp\.Views\.Uno' -and
        $packageId -notmatch 'NativeAssets') {
        $downloadedPackages += [PSCustomObject]@{
            Id = $packageId
            Path = $extractPath
        }
    }
}

if (-not $downloadedPackages) {
    throw 'The _NuGets package set did not restore any SkiaSharp or HarfBuzzSharp packages.'
}

foreach ($package in $downloadedPackages) {
    $referenceAssemblies = Get-ChildItem -Path (Join-Path $package.Path 'ref') -Filter '*.dll' -Recurse -ErrorAction Ignore
    $assemblies = if ($referenceAssemblies) {
        $referenceAssemblies
    } else {
        Get-ChildItem -Path (Join-Path $package.Path 'lib') -Filter '*.dll' -Recurse -ErrorAction Ignore
    }

    if (-not $assemblies) {
        Write-Warning "Skipping $($package.Id): it contains no reference or library assemblies."
        continue
    }

    $moniker = Get-Moniker $package.Id
    $monikerPath = Join-Path $workRoot "frameworks/$moniker"
    if ($monikerDirectories -notcontains $monikerPath) {
        New-Item -ItemType Directory -Force -Path $monikerPath | Out-Null
        $frameworkNode = $frameworks.CreateElement('Framework')
        [void] $frameworkNode.SetAttribute('Name', $moniker)
        [void] $frameworkNode.SetAttribute('Source', $moniker)
        [void] $frameworkRoot.AppendChild($frameworkNode)
        $monikerDirectories += $monikerPath
    }

    foreach ($assembly in $assemblies | Sort-Object FullName) {
        $destination = Join-Path $monikerPath $assembly.Name
        if (-not (Test-Path $destination)) {
            Copy-Item -Force $assembly.FullName $destination
        }
    }
}

if ($monikerDirectories.Count -eq 0) {
    throw 'The package set contained no managed assemblies to document.'
}

$frameworksPath = Join-Path $workRoot 'frameworks/frameworks.xml'
$frameworks.Save($frameworksPath)
Copy-Item -Recurse -Force (Join-Path $apiRoot 'xml') (Join-Path $stagingPath 'xml')
Copy-Item -Force (Join-Path $apiRoot '_filter.xml') $stagingPath

$libraryArguments = @('--lib', $referencePath)
foreach ($directory in $monikerDirectories) {
    $libraryArguments += @('--lib', $directory)
}
Install-DotnetSdk
$requiredWorkloadPacks = @(
    'Microsoft.Android.Ref.36',
    'Microsoft.iOS.Ref.net10.0_26.0',
    'Microsoft.MacCatalyst.Ref.net10.0_26.0',
    'Microsoft.macOS.Ref.net10.0_26.0',
    'Microsoft.tvOS.Ref.net10.0_26.0'
)
if ($requiredWorkloadPacks | Where-Object { -not (Test-Path (Join-Path $dotnetRoot "packs/$_")) }) {
    & $dotnetRuntime workload install android ios maccatalyst macos tvos --skip-manifest-update `
        --configfile (Join-Path $repositoryRoot 'NuGet.Config')
    if ($LASTEXITCODE -ne 0) {
        throw "Installing .NET 10 platform reference packs failed with exit code $LASTEXITCODE."
    }
}
$platformReferencePaths = Get-ChildItem -Path (Join-Path $dotnetRoot 'packs') -Filter '*.dll' -Recurse |
    ForEach-Object DirectoryName |
    Sort-Object -Unique
foreach ($directory in $platformReferencePaths) {
    $libraryArguments += @('--lib', $directory)
}
$packageReferencePaths = Get-ChildItem -Path $packagesPath -Filter '*.dll' -Recurse |
    ForEach-Object DirectoryName |
    Sort-Object -Unique
foreach ($directory in $packageReferencePaths) {
    $libraryArguments += @('--lib', $directory)
}
foreach ($directory in $AdditionalReferencePath | Where-Object { Test-Path $_ }) {
    $libraryArguments += @('--lib', $directory)
}
Push-Location (Split-Path -Parent $frameworksPath)
try {
    & $dotnetRuntime $mdocDll.FullName update --delete --fno-assembly-versions `
        --fignore-missing-types `
        --lang DocId `
        --frameworks $frameworksPath `
        --out $stagingPath `
        @libraryArguments
    if ($LASTEXITCODE -ne 0) {
        throw "mdoc failed with exit code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}

$preservedItems = @('docfx.json', 'SkiaSharpAPI-breadcrumb', 'images', 'xml')
Get-ChildItem -Path $apiRoot -Force | Where-Object { $_.Name -notin $preservedItems } | Remove-Item -Recurse -Force
Get-ChildItem -Path $stagingPath -Force | Where-Object { $_.Name -ne 'xml' } |
    Copy-Item -Destination $apiRoot -Recurse -Force

Write-Host "Replaced generated ECMA XML in $apiRoot from clean staging."
if (-not $KeepStaging) {
    Remove-Item -Recurse -Force $workRoot
}
