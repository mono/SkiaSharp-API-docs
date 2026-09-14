<#
.SYNOPSIS
Prepares an isolated package workspace for API documentation generation.

.DESCRIPTION
Expands managed product packages fetched by Fetch-ApiDocs.ps1 and downloads
and expands their NuGet dependencies. Generation reads the resulting workspace
and Fetch's expanded media folder without accessing a package feed.

.EXAMPLE
./eng/Prepare-ApiDocs.ps1

Prepares artifacts/workspace from artifacts/downloads.
#>
[CmdletBinding()]
param(
    [string] $TransportRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts/downloads/transport'),
    [string] $PackageSource = 'https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-public/nuget/v3/index.json',
    [string] $DependencyCacheRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts/downloads/dependencies'),
    [string] $WorkspaceRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts/workspace')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'ApiDocs.Common.psm1') -Force

# Require Fetch to have produced the local product-package source.
$transportPackageRoot = Join-Path $TransportRoot 'packages'
if (-not (Test-Path -LiteralPath $transportPackageRoot -PathType Container)) {
    throw "No expanded transport package source was found in '$transportPackageRoot'. Run Fetch first."
}

# Rebuild the disposable workspace while retaining reusable downloaded packages.
Remove-Item -Recurse -Force $WorkspaceRoot -ErrorAction Ignore
$productRoot = Join-Path $WorkspaceRoot 'products'
$dependencyRoot = Join-Path $WorkspaceRoot 'dependencies'
New-Item -ItemType Directory -Force $productRoot, $dependencyRoot, $DependencyCacheRoot | Out-Null

# Select the managed SkiaSharp and HarfBuzzSharp packages to document.
$transportPackages = @(Get-ChildItem -LiteralPath $transportPackageRoot -Filter '*.nupkg' -File)
$deferredProductPackageIds = @(
    'SkiaSharp.Views.Gtk3',
    'SkiaSharp.Views.Uno.WinUI'
)
$productPackages = @($transportPackages | Where-Object {
    $identity = Get-NuGetPackageIdentity $_
    $identity.Id -match '^(SkiaSharp|HarfBuzzSharp)(\.|$)' -and
        $identity.Id -notmatch 'NativeAssets' -and
        $identity.Id -notin $deferredProductPackageIds
})
if ($productPackages.Count -eq 0) {
    throw 'The transport dependency packages contained no managed SkiaSharp or HarfBuzzSharp packages.'
}

# Expand product packages into a workspace that Generate can consume without a package feed.
foreach ($package in $productPackages) {
    Expand-NuGetPackage $package.FullName $productRoot | Out-Null
}

# Allow only the external packages required by the selected product packages.
$dependencyPackageIds = @(
    'GirCore.Gtk-4.0',
    'GirCore.Gdk-4.0',
    'GirCore.Gsk-4.0',
    'GirCore.Graphene-1.0',
    'Microsoft.AspNetCore.Components',
    'Microsoft.AspNetCore.Components.Web',
    'Microsoft.Maui.Controls',
    'Microsoft.Maui.Controls.Core',
    'Microsoft.Maui.Core',
    'Microsoft.Maui.Graphics',
    'Microsoft.WindowsAppSDK',
    'OpenTK',
    'OpenTK.GLControl',
    'OpenTK.GLWpfControl',
    'SharpVk',
    'Silk.NET.Vulkan',
    'System.Memory',
    'System.Drawing.Common',
    'System.Runtime.CompilerServices.Unsafe',
    'Vortice.Direct3D12',
    'WinRT.Runtime'
)

# Add only platform references that mdoc explicitly needs to resolve view APIs.
$platformReferencePackages = @(
    [PSCustomObject]@{ Id = 'Microsoft.Android.Ref.36'; Version = '36.1.99-preview.2.154' }
    [PSCustomObject]@{ Id = 'Microsoft.iOS.Ref.net10.0_26.0'; Version = '26.0.11017' }
    [PSCustomObject]@{ Id = 'Microsoft.macOS.Ref.net10.0_26.0'; Version = '26.0.11017' }
    [PSCustomObject]@{ Id = 'Samsung.Tizen.Ref'; Version = '10.0.122' }
    [PSCustomObject]@{ Id = 'Microsoft.tvOS.Ref.net10.0_26.0'; Version = '26.0.11017' }
    [PSCustomObject]@{ Id = 'Microsoft.Windows.SDK.NET.Ref'; Version = '10.0.26100.87' }
    [PSCustomObject]@{ Id = 'Microsoft.WindowsDesktop.App.Ref'; Version = '11.0.0-rc.1.26425.128' }
)

$allowedDependencyPackageIds = @($dependencyPackageIds + $platformReferencePackages.Id)

# Process direct dependencies before considering any deeper allowed dependency.
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$pending = [Collections.Generic.Queue[object]]::new()
foreach ($package in $productPackages) {
    foreach ($dependency in Get-NuGetPackageDependencies $package.FullName) {
        $pending.Enqueue($dependency)
    }
}
# Supply the platform references required by prior mdoc resolution failures.
foreach ($platformReferencePackage in $platformReferencePackages) {
    $pending.Enqueue($platformReferencePackage)
}

while ($pending.Count -gt 0) {
    $dependency = $pending.Dequeue()
    if ($dependency.Id -notin $allowedDependencyPackageIds) {
        continue
    }
    $key = "$($dependency.Id)@$($dependency.Version)"
    if (-not $seen.Add($key)) {
        continue
    }

    $dependencyDirectory = Join-Path $DependencyCacheRoot $dependency.Id.ToLowerInvariant()
    if (-not (Test-Path -LiteralPath $dependencyDirectory -PathType Container)) {
        $packageReference = if ([string]::IsNullOrWhiteSpace($dependency.Version)) {
            $dependency.Id
        }
        else {
            "$($dependency.Id)@$($dependency.Version)"
        }
        dotnet package download $packageReference --prerelease --source $PackageSource --output $DependencyCacheRoot
        if ($LASTEXITCODE -ne 0) {
            throw "Downloading dependency '$packageReference' failed."
        }
    }
    $localPackage = Get-ChildItem -LiteralPath $DependencyCacheRoot -Filter '*.nupkg' -File -Recurse | Where-Object {
        (Get-NuGetPackageIdentity $_.FullName).Id -eq $dependency.Id
    } | Select-Object -Last 1
    if ($null -eq $localPackage) {
        throw "Dependency '$($dependency.Id)' was not downloaded."
    }

    foreach ($transitiveDependency in Get-NuGetPackageDependencies $localPackage.FullName) {
        $pending.Enqueue($transitiveDependency)
    }
    Expand-NuGetPackage $localPackage.FullName $dependencyRoot | Out-Null
}

Write-Host "Prepared $($productPackages.Count) product packages and their dependency workspace."
