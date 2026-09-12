Set-StrictMode -Version Latest

# Converts an exact NuGet version or range into a concrete package version.
# Resolver packages use the lower bound, which is compatible with the declared range.
function Resolve-NuGetPackageVersion([string] $PackageVersion) {
    if ($PackageVersion -notmatch '^[\[(]') {
        return $PackageVersion
    }
    if ($PackageVersion -match '^[\[(]\s*([^,\]\)]+)') {
        return $Matches[1].Trim()
    }
    if ($PackageVersion -match ',\s*([^\]\)]+)\s*[\]\)]$') {
        return $Matches[1].Trim()
    }
    throw "Cannot resolve an exact version from NuGet range '$PackageVersion'."
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

Export-ModuleMember -Function `
    Resolve-NuGetPackageVersion, `
    Get-NuGetPackageVersions, `
    Select-LatestMainTransportPackageVersion, `
    Resolve-DocsMediaPackageVersion, `
    Download-NuGetPackage, `
    Get-NuGetPackageDependencies, `
    Expand-NuGetPackageArchives, `
    Get-NuGetPackageId, `
    Get-NuGetPackageArchiveInfo, `
    Get-NuGetPackageArchiveId, `
    Resolve-NuGetPackageSource
