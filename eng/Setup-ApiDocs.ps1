[CmdletBinding()]
param(
    [string] $TransportPackageSource = 'https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-libraries-transport/nuget/v3/index.json',
    [string] $PackageSource = 'https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-public/nuget/v3/index.json',
    [string] $PackageVersion,
    [string] $DocsMediaPackageVersion,
    [string] $PackageRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts/api-docs/packages'),
    [string] $DependencyRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts/api-docs/dependencies'),
    [string] $DownloadCacheRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts/api-docs/downloads'),
    [string] $ManifestPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'eng/api-docs-packages.json'),
    [string] $ProvenancePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts/api-docs/provenance.json')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'ApiDocs.Common.psm1') -Force -DisableNameChecking

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw 'The .NET 10 SDK is required to download API documentation packages.'
}

# Reset product and dependency workspaces; downloads remain in the versioned shared cache.
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$manifest = Read-ApiDocsManifest $ManifestPath
Remove-Item -Recurse -Force $PackageRoot -ErrorAction Ignore
Remove-Item -Recurse -Force $DependencyRoot -ErrorAction Ignore
New-Item -ItemType Directory -Force -Path $PackageRoot | Out-Null
New-Item -ItemType Directory -Force -Path $DependencyRoot | Out-Null
$metadataRoot = Join-Path (Split-Path -Parent $PackageRoot) 'metadata'
$resolverRestoreRoot = Join-Path (Split-Path -Parent $PackageRoot) 'resolver-restore'
Remove-Item -Recurse -Force $metadataRoot -ErrorAction Ignore
Remove-Item -Recurse -Force $resolverRestoreRoot -ErrorAction Ignore

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

$selectedPackageVersion = if ($PackageVersion) {
    Resolve-NuGetPackageVersion $PackageVersion
} elseif ($localTransportPackages.Count -gt 0) {
    Select-LatestMainTransportPackageVersion @($localTransportPackages.Values |
        Where-Object { $_.Id -ieq '_NuGets' } |
        ForEach-Object Version)
} else {
    Select-LatestMainTransportPackageVersion (Get-NuGetPackageVersions '_NuGets' $source)
}
$selectedDocsMediaPackageVersion = Resolve-DocsMediaPackageVersion $selectedPackageVersion $DocsMediaPackageVersion
Write-Host "Selected main transport package version $selectedPackageVersion."

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
$resolverRootPackages = @(
    [PSCustomObject]@{ Id = 'Microsoft.Android.Ref.36'; Version = '36.1.99-preview.2.154' }
    [PSCustomObject]@{ Id = 'Microsoft.iOS.Ref.net10.0_26.0'; Version = '26.0.11017' }
    [PSCustomObject]@{ Id = 'Microsoft.MacCatalyst.Ref.net10.0_26.0'; Version = '26.0.11017' }
    [PSCustomObject]@{ Id = 'Microsoft.macOS.Ref.net10.0_26.0'; Version = '26.0.11017' }
    [PSCustomObject]@{ Id = 'Microsoft.tvOS.Ref.net10.0_26.0'; Version = '26.0.11017' }
    [PSCustomObject]@{ Id = 'Microsoft.Windows.SDK.Contracts'; Version = '10.0.29648.1000-preview' }
    [PSCustomObject]@{ Id = 'Microsoft.Windows.SDK.NET.Ref'; Version = '10.0.26100.87' }
    [PSCustomObject]@{ Id = 'Microsoft.WindowsDesktop.App.Ref'; Version = '11.0.0-rc.1.26425.128' }
    [PSCustomObject]@{ Id = 'Samsung.Tizen.Ref'; Version = '10.0.122' }
    [PSCustomObject]@{ Id = 'Uno.WinUI'; Version = '5.2.175' }
)
$resolverRootPackageVersions = @{}
foreach ($resolverRootPackage in $resolverRootPackages) {
    $resolverRootPackageVersions[$resolverRootPackage.Id] = $resolverRootPackage.Version
}

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
    'Uno.WinUI',
    'WinRT.Runtime',
    'Xamarin.Forms.Platform.GTK',
    'Xamarin.Forms.Platform.WPF',
    'Xamarin.Forms'
)

# Acquire the transport meta-package and its package-payload containers.
[void](Get-TransportPackage '_NuGets' $selectedPackageVersion)
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
[void](Get-TransportPackage '_DocsMedia' $selectedDocsMediaPackageVersion)

# Inspect embedded product packages and acquire only known mdoc resolver dependencies.
Expand-NuGetPackageArchives @($PackageRoot) $metadataRoot | Out-Null
$downloadedDependencies.Clear()
foreach ($resolverRootPackage in $resolverRootPackages) {
    $pendingDependencies.Enqueue([PSCustomObject]@{
        Id = $resolverRootPackage.Id
        Version = $resolverRootPackage.Version
    })
}
foreach ($packageArchive in Get-ChildItem -Path $metadataRoot -Filter '*.nupkg' -File -Recurse) {
    $packageId = Get-NuGetPackageArchiveId $packageArchive
    if ($null -eq $packageId -or
        $packageId -notmatch '^(HarfBuzzSharp|SkiaSharp)(\.|$)' -or
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
    $isPackageDownload = $resolverRootPackageVersions.ContainsKey($dependency.Id)
    $requestedResolverVersion = if ($isPackageDownload) {
        $resolverRootPackageVersions[$dependency.Id]
    } else {
        $dependency.Version
    }
    $dependencyVersion = Restore-NuGetResolverPackage $dependency.Id $requestedResolverVersion $dependencySource `
        (Join-Path $repositoryRoot 'NuGet.Config') $resolverRestoreRoot -PackageDownload:$isPackageDownload
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

# Classify every managed product package before generation. The manifest is
# deliberately committed: package updates cannot silently select a different
# TFM or add a new public assembly.
$productMetadataRoot = Join-Path (Split-Path -Parent $PackageRoot) 'product-metadata'
Remove-Item -Recurse -Force $productMetadataRoot -ErrorAction Ignore
$productPackages = Expand-NuGetPackageArchives @($PackageRoot) $productMetadataRoot
$managedPackages = @(
    foreach ($packagePath in $productPackages) {
        $packageId = Get-NuGetPackageId $packagePath
        if ($null -eq $packageId -or $packageId -notmatch '^(HarfBuzzSharp|SkiaSharp)(\.|$)') {
            continue
        }
        $managedAssets = @(
            foreach ($assetRoot in @('ref', 'lib')) {
                Get-ChildItem -Path (Join-Path $packagePath $assetRoot) -Filter '*.dll' -File -Recurse -ErrorAction Ignore
            }
        )
        if ($managedAssets.Count -gt 0) {
            [PSCustomObject]@{ Id = $packageId; Path = $packagePath }
        }
    }
)
$classificationById = @{}
foreach ($classification in $manifest.packages) {
    $classificationById[$classification.id] = $classification
}
$selectedAssets = @()
foreach ($package in $managedPackages | Sort-Object Id, Path) {
    if (-not $classificationById.ContainsKey($package.Id)) {
        throw "Managed product package '$($package.Id)' is not classified in '$ManifestPath'."
    }
    $classification = $classificationById[$package.Id]
    if ($classification.classification -eq 'exclude') {
        continue
    }
    $assets = @(
        foreach ($assetRoot in $classification.assetRoots) {
            Get-ChildItem -Path (Join-Path $package.Path $assetRoot) -Filter '*.dll' -File -Recurse -ErrorAction Ignore
        }
    )
    if ($assets.Count -eq 0) {
        throw "Package '$($package.Id)' has no managed assets in declared roots '$($classification.assetRoots -join ', ')'."
    }
    foreach ($assetPath in $assets | Sort-Object FullName) {
        $asset = [IO.Path]::GetRelativePath($package.Path, $assetPath.FullName).Replace([IO.Path]::DirectorySeparatorChar, '/')
        $xmlPath = [IO.Path]::ChangeExtension($assetPath, '.xml')
        if (-not (Test-Path -LiteralPath $xmlPath -PathType Leaf)) {
            throw "Selected asset '$asset' for package '$($package.Id)' has no adjacent package-authored XML documentation."
        }
        $selectedAssets += [PSCustomObject]@{
            packageId = $package.Id
            classification = $classification.classification
            moniker = $classification.moniker
            asset = $asset
            sha256 = Get-FileSha256 $assetPath
            documentationSha256 = Get-FileSha256 $xmlPath
        }
    }
}
Remove-Item -Recurse -Force $productMetadataRoot
Remove-Item -Recurse -Force $resolverRestoreRoot -ErrorAction Ignore

$productArchives = @(Get-ChildItem -Path $PackageRoot -Filter '*.nupkg' -File -Recurse | ForEach-Object FullName)
$resolverArchives = @(Get-ChildItem -Path $DependencyRoot -Filter '*.nupkg' -File -Recurse | ForEach-Object FullName)
Write-ApiDocsProvenance $ProvenancePath $selectedPackageVersion $selectedDocsMediaPackageVersion $ManifestPath `
    $productArchives $resolverArchives $selectedAssets

# Report the stable product package root consumed by Generate-ApiDocs.ps1.
Write-Host "Prepared API documentation packages in $PackageRoot."
