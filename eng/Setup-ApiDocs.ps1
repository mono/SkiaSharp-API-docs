[CmdletBinding()]
param(
    [string] $TransportPackageSource = 'https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-libraries-transport/nuget/v3/index.json',
    [string] $PackageSource = 'https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-public/nuget/v3/index.json',
    [string] $PackageVersion,
    [string] $DocsMediaPackageVersion,
    [string] $PackageRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts/api-docs/packages'),
    [string] $DependencyRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts/api-docs/dependencies'),
    [string] $DownloadCacheRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts/api-docs/downloads')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'ApiDocs.Common.psm1') -Force -DisableNameChecking

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw 'The .NET 10 SDK is required to download API documentation packages.'
}

# Reset product and dependency workspaces; downloads remain in the versioned shared cache.
$repositoryRoot = Split-Path -Parent $PSScriptRoot
Remove-Item -Recurse -Force $PackageRoot -ErrorAction Ignore
Remove-Item -Recurse -Force $DependencyRoot -ErrorAction Ignore
New-Item -ItemType Directory -Force -Path $PackageRoot | Out-Null
New-Item -ItemType Directory -Force -Path $DependencyRoot | Out-Null
$metadataRoot = Join-Path (Split-Path -Parent $PackageRoot) 'metadata'
Remove-Item -Recurse -Force $metadataRoot -ErrorAction Ignore

$source = Resolve-NuGetPackageSource $TransportPackageSource
$dependencySource = Resolve-NuGetPackageSource $PackageSource
$localTransportPackages = @{}
if (Test-Path -Path $source -PathType Container) {
    # Artifact folders are package archives, not a NuGet service; index them by nuspec identity.
    foreach ($archive in Get-ChildItem -Path $source -Filter '*.nupkg' -File -Recurse) {
        $packageInfo = Get-NuGetPackageArchiveInfo $archive
        if ($null -eq $packageInfo) {
            continue
        }
        $key = "$($packageInfo.Id)/$($packageInfo.Version)".ToLowerInvariant()
        if ($localTransportPackages.ContainsKey($key)) {
            continue
        }
        $localTransportPackages[$key] = [PSCustomObject]@{
            Archive = $archive
            Id = $packageInfo.Id
            Version = $packageInfo.Version
        }
    }
}

# Copies a declared transport archive directly from a local pipeline artifact.
# Production transport URLs continue through Download-NuGetPackage.
function Get-TransportPackage([string] $PackageId, [string] $PackageVersion, [switch] $AllowMissing) {
    $resolvedVersion = Resolve-NuGetPackageVersion $PackageVersion
    if ($localTransportPackages.Count -eq 0) {
        return Download-NuGetPackage $PackageId $resolvedVersion $source $PackageRoot $DownloadCacheRoot (Join-Path $repositoryRoot 'NuGet.Config') -AllowMissing:$AllowMissing
    }

    $matches = @($localTransportPackages.GetEnumerator() | Where-Object {
        $_.Value.Id -ieq $PackageId -and (-not $resolvedVersion -or $_.Value.Version -eq $resolvedVersion)
    })
    if ($matches.Count -eq 0) {
        if ($AllowMissing) {
            return $false
        }
        throw "The local transport source does not contain '$PackageId' version '$resolvedVersion'."
    }
    if ($matches.Count -gt 1) {
        throw "The local transport source contains multiple versions of '$PackageId'; specify an exact version."
    }

    $package = $matches[0].Value
    $destination = Join-Path (Join-Path $PackageRoot $package.Id.ToLowerInvariant()) $package.Version
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    Copy-Item -Force $package.Archive.FullName $destination
    return $true
}

# Platform reference assemblies
$resolverRootPackageIds = @(
    'Microsoft.Android.Ref.36',
    'Microsoft.iOS.Ref.net10.0_26.0',
    'Microsoft.MacCatalyst.Ref.net10.0_26.0',
    'Microsoft.macOS.Ref.net10.0_26.0',
    'Microsoft.tvOS.Ref.net10.0_26.0',
    'Microsoft.Windows.SDK.Contracts',
    'Microsoft.Windows.SDK.NET.Ref',
    'Microsoft.WindowsDesktop.App.Ref',
    'Samsung.Tizen.Ref'
)

$resolverPackageIds = @(
    'AtkSharp',
    'GdkSharp',
    'GirCore.Cairo-1.0',
    'GirCore.FreeType2-2.0',
    'GirCore.Gdk-4.0',
    'GirCore.GdkPixbuf-2.0',
    'GirCore.Gio-2.0',
    'GirCore.GLib-2.0',
    'GirCore.GObject-2.0',
    'GirCore.Graphene-1.0',
    'GirCore.Gsk-4.0',
    'GirCore.Gtk-4.0',
    'GirCore.HarfBuzz-0.0',
    'GirCore.Pango-1.0',
    'GirCore.PangoCairo-1.0',
    'GLibSharp',
    'GtkSharp',
    'Microsoft.Android.Ref.36',
    'Microsoft.AspNetCore.Components.Web',
    'Microsoft.AspNetCore.Components',
    'Microsoft.iOS.Ref.net10.0_26.0',
    'Microsoft.JSInterop',
    'Microsoft.MacCatalyst.Ref.net10.0_26.0',
    'Microsoft.macOS.Ref.net10.0_26.0',
    'Microsoft.Maui.Controls',
    'Microsoft.Maui.Controls.Core',
    'Microsoft.Maui.Core',
    'Microsoft.Maui.Graphics',
    'Microsoft.tvOS.Ref.net10.0_26.0',
    'Microsoft.Windows.SDK.Contracts',
    'Microsoft.Windows.SDK.NET.Ref',
    'Microsoft.WindowsAppSDK',
    'Microsoft.WindowsDesktop.App.Ref',
    'Mono.GtkSharp',
    'OpenTK.GLControl',
    'OpenTK.GLWpfControl',
    'Samsung.Tizen.Ref',
    'System.Memory',
    'System.Runtime.CompilerServices.Unsafe',
    'System.Runtime.WindowsRuntime.UI.Xaml',
    'System.Runtime.WindowsRuntime',
    'WinRT.Runtime',
    'Xamarin.Forms.Platform.GTK',
    'Xamarin.Forms.Platform.WPF',
    'Xamarin.Forms'
)

# Acquire the transport meta-package and its package-payload containers.
[void](Get-TransportPackage '_NuGets' $PackageVersion)
$metaPackage = Get-ChildItem -Path $PackageRoot -Filter '_nugets*.nupkg' -File -Recurse | Select-Object -First 1
if (-not $metaPackage) {
    throw "No _NuGets package was downloaded to '$PackageRoot'."
}

$downloadedDependencies = @{}
$pendingDependencies = [System.Collections.Generic.Queue[object]]::new()
foreach ($dependency in Get-NuGetPackageDependencies $metaPackage) {
    if ($dependency.Id -match '^_NuGets\.Dependencies\.\d+$') {
        $pendingDependencies.Enqueue($dependency)
    }
}
while ($pendingDependencies.Count -gt 0) {
    $dependency = $pendingDependencies.Dequeue()
    $dependencyVersion = Resolve-NuGetPackageVersion $dependency.Version
    $key = "$($dependency.Id)/$dependencyVersion".ToLowerInvariant()
    if ($downloadedDependencies.ContainsKey($key)) {
        continue
    }

    [void](Get-TransportPackage $dependency.Id $dependencyVersion)
    $downloadedDependencies[$key] = $true
    $dependencyArchive = Get-ChildItem -Path $PackageRoot -Filter "$($dependency.Id)*.nupkg" -File -Recurse |
        Where-Object { $_.Name -match [regex]::Escape($dependencyVersion) } |
        Select-Object -First 1
    if (-not $dependencyArchive) {
        throw "No package archive was downloaded for dependency '$key'."
    }
}

# Media is part of the generated documentation contract.
[void](Get-TransportPackage '_DocsMedia' $DocsMediaPackageVersion)

# Inspect embedded product packages and acquire only known mdoc resolver dependencies.
Expand-NuGetPackageArchives @($PackageRoot) $metadataRoot | Out-Null
$downloadedDependencies.Clear()
foreach ($resolverRootPackageId in $resolverRootPackageIds) {
    $pendingDependencies.Enqueue([PSCustomObject]@{
        Id = $resolverRootPackageId
        Version = $null
    })
}
foreach ($packageArchive in Get-ChildItem -Path $metadataRoot -Filter '*.nupkg' -File -Recurse) {
    $packageId = Get-NuGetPackageArchiveId $packageArchive
    if ($null -eq $packageId -or
        $packageId -notmatch '^(HarfBuzzSharp|SkiaSharp)(\.|$)' -or
        $packageId -match '^SkiaSharp\.Views\.Uno' -or
        $packageId -match 'NativeAssets') {
        continue
    }

    foreach ($dependency in Get-NuGetPackageDependencies $packageArchive) {
        if ($resolverPackageIds.Contains($dependency.Id)) {
            $pendingDependencies.Enqueue($dependency)
        }
    }
}
while ($pendingDependencies.Count -gt 0) {
    $dependency = $pendingDependencies.Dequeue()
    if (-not $resolverPackageIds.Contains($dependency.Id)) {
        continue
    }
    $dependencyVersion = Resolve-NuGetPackageVersion $dependency.Version
    $key = "$($dependency.Id)/$dependencyVersion".ToLowerInvariant()
    if ($downloadedDependencies.ContainsKey($key)) {
        continue
    }

    [void](Download-NuGetPackage $dependency.Id $dependencyVersion $dependencySource $DependencyRoot $DownloadCacheRoot (Join-Path $repositoryRoot 'NuGet.Config'))
    $downloadedDependencies[$key] = $true
    $dependencyArchive = Get-ChildItem -Path $DependencyRoot -Filter "$($dependency.Id)*.nupkg" -File -Recurse |
        Where-Object { $_.Name -match [regex]::Escape($dependencyVersion) } |
        Select-Object -First 1
    if (-not $dependencyArchive) {
        throw "No package archive was downloaded for dependency '$key'."
    }
    foreach ($transitiveDependency in Get-NuGetPackageDependencies $dependencyArchive) {
        if ($resolverPackageIds.Contains($transitiveDependency.Id)) {
            $pendingDependencies.Enqueue($transitiveDependency)
        }
    }
}
Remove-Item -Recurse -Force $metadataRoot

# Report the stable product package root consumed by Generate-ApiDocs.ps1.
Write-Host "Prepared API documentation packages in $PackageRoot."
