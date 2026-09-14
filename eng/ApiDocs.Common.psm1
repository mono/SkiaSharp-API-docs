Set-StrictMode -Version Latest

# Validates an exact NuGet version. Resolver ranges are resolved through
# Restore-NuGetResolverPackage so NuGet records its decision.
function Resolve-NuGetPackageVersion([string] $PackageVersion) {
    if ([string]::IsNullOrWhiteSpace($PackageVersion) -or
        $PackageVersion -match '[\[\]\(\),*]') {
        throw "An exact NuGet package version is required; got '$PackageVersion'."
    }
    return $PackageVersion
}

function Get-FileSha256([string] $Path) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

# Resolves ordinary packages with NuGet's dependency solver and a lock file.
# DotnetPlatform packages are intentionally PackageDownload items: NuGet forbids
# them as PackageReference items (NU1213), but PackageDownload supports their
# exact, pre-pinned version without adding them to compilation.
function Restore-NuGetResolverPackage(
    [string] $PackageId,
    [string] $VersionRange,
    [string] $Source,
    [string] $ConfigFile,
    [string] $RestoreRoot,
    [switch] $PackageDownload
) {
    if ($PackageDownload -and (
        [string]::IsNullOrWhiteSpace($VersionRange) -or
        $VersionRange -match '[\[\]\(\),*]')) {
        throw "PackageDownload resolver package '$PackageId' requires an exact pinned version."
    }

    $requestedVersion = if ($PackageDownload) {
        "[$VersionRange]"
    } elseif ([string]::IsNullOrWhiteSpace($VersionRange)) {
        '*'
    } else {
        $VersionRange
    }
    $projectDirectory = Join-Path $RestoreRoot (($PackageId -replace '[^A-Za-z0-9._-]', '_').ToLowerInvariant())
    New-Item -ItemType Directory -Force -Path $projectDirectory | Out-Null
    $projectPath = Join-Path $projectDirectory 'resolver.csproj'
    $lockPath = Join-Path $projectDirectory 'packages.lock.json'
    $itemName = if ($PackageDownload) { 'PackageDownload' } else { 'PackageReference' }
    $privateAssets = if ($PackageDownload) { '' } else { ' PrivateAssets="all"' }
    @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <RestorePackagesWithLockFile>true</RestorePackagesWithLockFile>
  </PropertyGroup>
  <ItemGroup>
    <$itemName Include="$PackageId" Version="$requestedVersion"$privateAssets />
  </ItemGroup>
</Project>
"@ | Set-Content -NoNewline -LiteralPath $projectPath

    & dotnet restore $projectPath --configfile $ConfigFile --source $Source | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "NuGet restore failed for resolver package '$PackageId'."
    }

    if ($PackageDownload) {
        # PackageDownload accepts only an exact version and records it in the
        # restore spec, providing the same repeatability for a leaf download.
        return $VersionRange
    }

    & dotnet restore $projectPath --configfile $ConfigFile --source $Source --locked-mode --lock-file-path $lockPath | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "NuGet locked restore failed for resolver package '$PackageId'."
    }

    $lock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json -Depth 32
    $resolvedVersion = $null
    foreach ($target in $lock.dependencies.PSObject.Properties.Value) {
        $package = $target.PSObject.Properties |
            Where-Object { $_.Name -ieq $PackageId } |
            Select-Object -First 1 -ExpandProperty Value
        if ($null -ne $package) {
            if ($resolvedVersion -and $resolvedVersion -ne $package.resolved) {
                throw "NuGet lock file resolved '$PackageId' to inconsistent versions."
            }
            $resolvedVersion = $package.resolved
        }
    }
    if ([string]::IsNullOrWhiteSpace($resolvedVersion)) {
        throw "NuGet lock file did not resolve '$PackageId'."
    }
    return $resolvedVersion
}

    function Read-ApiDocsManifest([string] $ManifestPath) {
        if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
            throw "API documentation classification manifest '$ManifestPath' does not exist."
        }

        $manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json -Depth 32
        if ($manifest.schemaVersion -ne 1 -or $null -eq $manifest.packages -or
            [string]::IsNullOrWhiteSpace($manifest.mdocVersion)) {
            throw "API documentation classification manifest '$ManifestPath' has an unsupported format."
        }

        $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($package in $manifest.packages) {
            if ([string]::IsNullOrWhiteSpace($package.id) -or -not $ids.Add($package.id)) {
                throw "API documentation classification manifest '$ManifestPath' contains a missing or duplicate package id."
            }
            if ($package.classification -notin @('generate', 'alias', 'exclude')) {
                throw "Package '$($package.id)' must be classified as generate, alias, or exclude."
            }
            if ([string]::IsNullOrWhiteSpace($package.reason)) {
                throw "Package '$($package.id)' must record a classification reason."
            }
            if ($package.classification -in @('generate', 'alias')) {
                if ([string]::IsNullOrWhiteSpace($package.moniker) -or @($package.assetRoots).Count -eq 0) {
                    throw "Generated package '$($package.id)' must declare a moniker and one or more asset roots."
                }
                $assetRoots = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                foreach ($assetRoot in $package.assetRoots) {
                    if ($assetRoot -notin @('ref', 'lib') -or -not $assetRoots.Add($assetRoot)) {
                        throw "Package '$($package.id)' has an invalid or duplicate asset root '$assetRoot'."
                    }
                }
            }
        }
        return $manifest
    }

    function Write-ApiDocsProvenance(
        [string] $ProvenancePath,
        [string] $TransportVersion,
        [string] $DocsMediaVersion,
        [string] $ManifestPath,
        [string[]] $ProductArchives,
        [string[]] $DependencyArchives,
        [object[]] $SelectedAssets
    ) {
        $archives = @(
            foreach ($archive in @($ProductArchives) + @($DependencyArchives) | Sort-Object) {
                $info = Get-NuGetPackageArchiveInfo (Get-Item -LiteralPath $archive)
                [PSCustomObject]@{
                    id = $info.Id
                    version = $info.Version
                    sha256 = Get-FileSha256 $archive
                    kind = if ($ProductArchives -contains $archive) { 'product' } else { 'resolver' }
                }
            }
        )
        $provenance = [ordered]@{
            schemaVersion = 1
            transportVersion = $TransportVersion
            docsMediaVersion = $DocsMediaVersion
            classificationManifestSha256 = Get-FileSha256 $ManifestPath
            archives = @($archives | Sort-Object id, version, kind)
            selectedAssets = @($SelectedAssets | Sort-Object packageId, asset)
        }
        $provenance | ConvertTo-Json -Depth 32 | Set-Content -NoNewline -LiteralPath $ProvenancePath
}

# Gets all published versions for a package from a NuGet v3 feed's flat container.
function Get-NuGetPackageVersions([string] $PackageId, [string] $Source) {
    if ($Source -notmatch '^https://') {
        throw "Package version discovery requires an HTTPS NuGet v3 feed; '$Source' is not a feed URL."
    }

    $serviceIndex = Invoke-RestMethod -Uri $Source
    $packageBaseAddress = $serviceIndex.resources |
        Where-Object { @($_.'@type') -match '^PackageBaseAddress/' } |
        Select-Object -First 1 -ExpandProperty '@id'
    if (-not $packageBaseAddress) {
        throw "NuGet v3 feed '$Source' does not expose a PackageBaseAddress resource."
    }

    $packageIndexUrl = '{0}/{1}/index.json' -f $packageBaseAddress.TrimEnd('/'), $PackageId.ToLowerInvariant()
    $packageIndex = Invoke-RestMethod -Uri $packageIndexUrl
    if (-not $packageIndex.versions) {
        throw "NuGet v3 package index '$packageIndexUrl' contains no versions for '$PackageId'."
    }

    return @($packageIndex.versions)
}

# Selects the highest build number from the production main-branch transport package family.
function Select-LatestMainTransportPackageVersion([string[]] $Versions) {
    $candidates = foreach ($version in $Versions) {
        if ($version -match '^0\.0\.0-branch\.main\.(\d+)$') {
            [PSCustomObject]@{
                Version = $version
                Build = [Int64]$Matches[1]
            }
        }
    }
    $latest = $candidates | Sort-Object Build, Version -Descending | Select-Object -First 1
    if (-not $latest) {
        throw 'No eligible _NuGets version matching 0.0.0-branch.main.<build> was found.'
    }

    return $latest.Version
}

# Couples the media package to the selected transport package version.
function Resolve-DocsMediaPackageVersion([string] $PackageVersion, [string] $DocsMediaPackageVersion) {
    $selectedPackageVersion = Resolve-NuGetPackageVersion $PackageVersion
    $selectedDocsMediaPackageVersion = if ($DocsMediaPackageVersion) {
        Resolve-NuGetPackageVersion $DocsMediaPackageVersion
    } else {
        $selectedPackageVersion
    }
    if ($selectedDocsMediaPackageVersion -ne $selectedPackageVersion) {
        throw "_DocsMedia version '$selectedDocsMediaPackageVersion' must exactly match _NuGets version '$selectedPackageVersion'."
    }

    return $selectedDocsMediaPackageVersion
}

# Downloads one exact package into the requested cache root.
# Reuses a versioned shared cache, then copies the package into the caller's workspace.
function Download-NuGetPackage(
    [string] $PackageId,
    [string] $PackageVersion,
    [string] $Source,
    [string] $OutputRoot,
    [string] $DownloadCacheRoot,
    [string] $ConfigFile,
    [switch] $AllowMissing
) {
    $resolvedVersion = Resolve-NuGetPackageVersion $PackageVersion
    $packageCacheRoot = Join-Path $DownloadCacheRoot $PackageId.ToLowerInvariant()
    $cachedPackageDirectory = if ($resolvedVersion) {
        Join-Path $packageCacheRoot $resolvedVersion
    } elseif (Test-Path $packageCacheRoot) {
        Get-ChildItem -Path $packageCacheRoot -Directory |
            Sort-Object LastWriteTimeUtc |
            Select-Object -Last 1 -ExpandProperty FullName
    }

    if (-not $cachedPackageDirectory -or -not (Test-Path $cachedPackageDirectory)) {
        $packageReference = if ($resolvedVersion) { "${PackageId}@${resolvedVersion}" } else { $PackageId }
        Write-Host "Downloading $packageReference from $Source into $DownloadCacheRoot."
        New-Item -ItemType Directory -Force -Path $DownloadCacheRoot | Out-Null
        & dotnet package download $packageReference --prerelease `
            --output $DownloadCacheRoot `
            --configfile $ConfigFile `
            --source $Source
        if ($LASTEXITCODE -ne 0) {
            if ($AllowMissing) {
                return $false
            }
            Write-Host "ERROR: Failed to download $packageReference from $Source."
            throw "Downloading $PackageId from '$Source' failed with exit code $LASTEXITCODE."
        }

        $cachedPackageDirectory = Get-ChildItem -Path $packageCacheRoot -Directory |
            Sort-Object LastWriteTimeUtc |
            Select-Object -Last 1 -ExpandProperty FullName
    } else {
        Write-Host "Reusing cached $PackageId $(Split-Path -Leaf $cachedPackageDirectory)."
    }
    if (-not $cachedPackageDirectory -or -not (Test-Path $cachedPackageDirectory)) {
        throw "No cached package directory was found for '$PackageId'."
    }

    $destinationRoot = Join-Path $OutputRoot $PackageId.ToLowerInvariant()
    $destination = Join-Path $destinationRoot (Split-Path -Leaf $cachedPackageDirectory)
    if (-not (Test-Path $destination)) {
        New-Item -ItemType Directory -Force -Path $destinationRoot | Out-Null
        Copy-Item -Recurse -Path $cachedPackageDirectory -Destination $destinationRoot
    }
    return $true
}

# Reads a package manifest directly from its ZIP archive and returns declared dependencies.
# Avoids temporary extraction when setup walks a large dependency closure.
function Get-NuGetPackageDependencies([IO.FileInfo] $PackageArchive) {
    $archive = [IO.Compression.ZipFile]::OpenRead($PackageArchive.FullName)
    try {
        $nuspecEntry = $archive.Entries |
            Where-Object { $_.FullName -match '\.nuspec$' } |
            Select-Object -First 1
        if (-not $nuspecEntry) {
            throw "Package archive '$($PackageArchive.FullName)' does not contain a .nuspec manifest."
        }

        $reader = [IO.StreamReader]::new($nuspecEntry.Open())
        try {
            [xml] $nuspec = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $archive.Dispose()
    }

    return $nuspec.SelectNodes('//*[local-name() = "dependency"]') | ForEach-Object {
        [PSCustomObject]@{
            Id = $_.GetAttribute('id')
            Version = $_.GetAttribute('version')
        }
    }
}

# Recursively expands package archives, including transport packages that embed product packages.
# Returns every extracted package directory for manifest inspection or generation staging.
function Expand-NuGetPackageArchives([string[]] $InputPaths, [string] $DestinationRoot) {
    New-Item -ItemType Directory -Force -Path $DestinationRoot | Out-Null
    $archives = @(foreach ($inputPath in $InputPaths) {
        if ((Get-Item $inputPath).PSIsContainer) {
            Get-ChildItem -Path $inputPath -Filter '*.nupkg' -File -Recurse
        } else {
            Get-Item $inputPath
        }
    })
    $processedArchives = @{}
    $expandedPaths = @()
    while ($archives.Count -gt 0) {
        $archive = $archives[0]
        $archives = @($archives | Select-Object -Skip 1)
        if ($processedArchives.ContainsKey($archive.FullName)) {
            continue
        }

        $processedArchives[$archive.FullName] = $true
        $expandedPath = Join-Path $DestinationRoot ([IO.Path]::GetFileNameWithoutExtension($archive.Name))
        Expand-Archive -Path $archive.FullName -DestinationPath $expandedPath -Force
        $expandedPaths += $expandedPath
        $archives += Get-ChildItem -Path $expandedPath -Filter '*.nupkg' -File -Recurse
    }
    return $expandedPaths
}

# Reads the NuGet package identifier from an extracted package manifest.
# Returns null for archives that do not represent a NuGet package.
function Get-NuGetPackageId([string] $PackagePath) {
    $nuspec = Get-ChildItem -Path $PackagePath -Filter '*.nuspec' -File | Select-Object -First 1
    if ($null -eq $nuspec) {
        return $null
    }

    [xml] $metadata = Get-Content -Raw -Path $nuspec.FullName
    return $metadata.package.metadata.id
}

# Reads package identity metadata from a NuGet archive without extracting it.
function Get-NuGetPackageArchiveInfo([IO.FileInfo] $PackageArchive) {
    $archive = [IO.Compression.ZipFile]::OpenRead($PackageArchive.FullName)
    try {
        $nuspecEntry = $archive.Entries |
            Where-Object { $_.FullName -match '\.nuspec$' } |
            Select-Object -First 1
        if (-not $nuspecEntry) {
            return $null
        }

        $reader = [IO.StreamReader]::new($nuspecEntry.Open())
        try {
            [xml] $nuspec = $reader.ReadToEnd()
            return [PSCustomObject]@{
                Id = $nuspec.package.metadata.id
                Version = $nuspec.package.metadata.version
            }
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $archive.Dispose()
    }
}

# Reads the package identifier from a NuGet archive without extracting it.
# Setup uses this to select only packages that contribute generated API content.
function Get-NuGetPackageArchiveId([IO.FileInfo] $PackageArchive) {
    $packageInfo = Get-NuGetPackageArchiveInfo $PackageArchive
    if ($null -eq $packageInfo) {
        return $null
    }
    return $packageInfo.Id
}

# Converts a local NuGet source directory to an absolute path.
# Feed URLs pass through unchanged.
function Resolve-NuGetPackageSource([string] $Source) {
    if (Test-Path -Path $Source -PathType Container) {
        return (Resolve-Path -Path $Source).Path
    }
    return $Source
}

function Get-ApiDocsFrameworkName(
    [string] $Moniker,
    [string] $PackageId,
    [string] $Asset
) {
    $segments = @($Asset -split '[\\/]')
    if ($segments.Count -lt 3 -or $segments[0] -notin @('lib', 'ref') -or
        [string]::IsNullOrWhiteSpace($segments[1])) {
        throw "Selected asset '$Asset' must begin with lib/<TFM>/ or ref/<TFM>/."
    }

    $name = "$Moniker--$PackageId--$($segments[0])-$($segments[1])".ToLowerInvariant()
    $name = $name -replace '[^a-z0-9]+', '-'
    return $name.Trim('-')
}

function Write-MdocFrameworkConfiguration(
    [string] $FrameworksRoot,
    [object[]] $SelectedAssets
) {
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($selectedAsset in $SelectedAssets) {
        if ([string]::IsNullOrWhiteSpace($selectedAsset.FrameworkName) -or
            -not $names.Add($selectedAsset.FrameworkName)) {
            throw "Each selected asset must have one unique mdoc framework name; '$($selectedAsset.FrameworkName)' is not unique."
        }
        if ([IO.Path]::GetFileName($selectedAsset.FrameworkSource) -ne $selectedAsset.FrameworkSource) {
            throw "Framework source '$($selectedAsset.FrameworkSource)' must be an immediate directory under the frameworks root."
        }
    }

    $configurationPath = Join-Path $FrameworksRoot 'frameworks.xml'
    $settings = [Xml.XmlWriterSettings]::new()
    $settings.Encoding = [Text.UTF8Encoding]::new($false)
    $settings.Indent = $true
    $writer = [Xml.XmlWriter]::Create($configurationPath, $settings)
    try {
        $writer.WriteStartDocument()
        $writer.WriteStartElement('Frameworks')
        foreach ($selectedAsset in $SelectedAssets | Sort-Object FrameworkName) {
            $writer.WriteStartElement('Framework')
            $writer.WriteAttributeString('Name', $selectedAsset.FrameworkName)
            $writer.WriteAttributeString('Source', $selectedAsset.FrameworkSource)
            $writer.WriteEndElement()
        }
        $writer.WriteEndElement()
        $writer.WriteEndDocument()
    }
    finally {
        $writer.Dispose()
    }

    return $configurationPath
}

Export-ModuleMember -Function `
    Resolve-NuGetPackageVersion, `
    Get-FileSha256, `
    Restore-NuGetResolverPackage, `
    Read-ApiDocsManifest, `
    Write-ApiDocsProvenance, `
    Get-NuGetPackageVersions, `
    Select-LatestMainTransportPackageVersion, `
    Resolve-DocsMediaPackageVersion, `
    Download-NuGetPackage, `
    Get-NuGetPackageDependencies, `
    Expand-NuGetPackageArchives, `
    Get-NuGetPackageId, `
    Get-NuGetPackageArchiveInfo, `
    Get-NuGetPackageArchiveId, `
    Resolve-NuGetPackageSource, `
    Get-ApiDocsFrameworkName, `
    Write-MdocFrameworkConfiguration
