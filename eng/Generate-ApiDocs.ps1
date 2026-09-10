[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]] $NuGetsPath,
    [Parameter(Mandatory)]
    [string[]] $DocsMediaPath,
    [Parameter(Mandatory)]
    [string] $MdocPath,
    [Parameter(Mandatory)]
    [string[]] $ReferencePath,
    [string] $OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'SkiaSharpAPI'),
    [string] $DotnetPath = 'dotnet',
    [switch] $KeepStaging
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Expand-PackageArchives([string] $inputPath, [string] $destinationRoot) {
    if (-not (Test-Path $inputPath)) {
        throw "Package input '$inputPath' does not exist."
    }

    New-Item -ItemType Directory -Force -Path $destinationRoot | Out-Null
    $archives = if ((Get-Item $inputPath).PSIsContainer) {
        Get-ChildItem -Path $inputPath -Filter '*.nupkg' -File -Recurse
    } else {
        Get-Item $inputPath
    }
    if (-not $archives) {
        throw "Package input '$inputPath' does not contain any .nupkg files."
    }

    $expandedPaths = @()
    $processedArchives = @{}
    while ($archives.Count -gt 0) {
        $archive = $archives[0]
        $archives = @($archives | Select-Object -Skip 1)
        if ($processedArchives.ContainsKey($archive.FullName)) {
            continue
        }
        $processedArchives[$archive.FullName] = $true
        $expandedPath = Join-Path $destinationRoot ([IO.Path]::GetFileNameWithoutExtension($archive.Name))
        Expand-Archive -Path $archive.FullName -DestinationPath $expandedPath -Force
        $expandedPaths += $expandedPath
        $archives += Get-ChildItem -Path $expandedPath -Filter '*.nupkg' -File -Recurse
    }
    return $expandedPaths
}

function Get-PackageId([string] $packagePath) {
    $nuspec = Get-ChildItem -Path $packagePath -Filter '*.nuspec' -File | Select-Object -First 1
    if ($null -eq $nuspec) {
        return $null
    }

    [xml] $metadata = Get-Content -Raw -Path $nuspec.FullName
    return $metadata.package.metadata.id
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

if (-not (Test-Path $MdocPath)) {
    throw "mdoc '$MdocPath' does not exist."
}
if (-not (Test-Path $OutputRoot)) {
    throw "Output root '$OutputRoot' does not exist."
}
if ($ReferencePath | Where-Object { -not (Test-Path $_) }) {
    throw 'One or more supplied reference paths do not exist.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$workRoot = Join-Path $repositoryRoot '.artifacts/api-docs'
$nuGetsExtractionPath = Join-Path $workRoot 'nugets'
$mediaExtractionPath = Join-Path $workRoot 'media'
$frameworksRoot = Join-Path $workRoot 'frameworks'
$stagingPath = Join-Path $workRoot 'staging'

Remove-Item -Recurse -Force $workRoot -ErrorAction Ignore
New-Item -ItemType Directory -Force -Path $nuGetsExtractionPath, $mediaExtractionPath, $frameworksRoot, $stagingPath | Out-Null

$nuGetsPackages = foreach ($path in $NuGetsPath) {
    Expand-PackageArchives $path $nuGetsExtractionPath
}
$mediaPackages = foreach ($path in $DocsMediaPath) {
    Expand-PackageArchives $path $mediaExtractionPath
}

$frameworks = New-Object System.Xml.XmlDocument
$frameworkRoot = $frameworks.CreateElement('Frameworks')
[void] $frameworks.AppendChild($frameworkRoot)
$monikerDirectories = @()

foreach ($packagePath in $nuGetsPackages) {
    $packageId = Get-PackageId $packagePath
    if ($null -eq $packageId -or
        $packageId -notmatch '^(HarfBuzzSharp|SkiaSharp)(\.|$)' -or
        $packageId -match '^SkiaSharp\.Views\.Uno' -or
        $packageId -match 'NativeAssets') {
        continue
    }

    $referenceAssemblies = Get-ChildItem -Path (Join-Path $packagePath 'ref') -Filter '*.dll' -Recurse -ErrorAction Ignore
    $assemblies = if ($referenceAssemblies) {
        $referenceAssemblies
    } else {
        Get-ChildItem -Path (Join-Path $packagePath 'lib') -Filter '*.dll' -Recurse -ErrorAction Ignore
    }
    if (-not $assemblies) {
        continue
    }

    $moniker = Get-Moniker $packageId
    $monikerPath = Join-Path $frameworksRoot $moniker
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
    throw 'The supplied _NuGets input contains no managed SkiaSharp or HarfBuzzSharp assemblies.'
}

$stagingXmlPath = Join-Path $stagingPath 'xml'
New-Item -ItemType Directory -Force -Path $stagingXmlPath | Out-Null
Copy-Item -Force (Join-Path $OutputRoot 'xml/_filter.xml') $stagingXmlPath
Copy-Item -Force (Join-Path $OutputRoot '_filter.xml') $stagingPath

$mediaFiles = $mediaPackages |
    ForEach-Object { Get-ChildItem -Path $_ -File -Recurse } |
    Where-Object { $_.Extension -match '^\.(gif|jpe?g|png|svg|webp)$' }
if (-not $mediaFiles) {
    throw 'The supplied _DocsMedia input contains no supported media files.'
}

$stagingMediaPath = Join-Path $stagingPath 'images'
foreach ($mediaFile in $mediaFiles) {
    $imagesRoot = $mediaFile.Directory
    while ($imagesRoot -and $imagesRoot.Name -ne 'images') {
        $imagesRoot = $imagesRoot.Parent
    }
    if ($null -eq $imagesRoot) {
        throw "Unable to determine the images root for '$($mediaFile.FullName)'."
    }

    $destination = Join-Path $stagingMediaPath ([IO.Path]::GetRelativePath($imagesRoot.FullName, $mediaFile.FullName))
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -Force $mediaFile.FullName $destination
}
if (-not (Get-ChildItem -Path $stagingMediaPath -File -Recurse | Where-Object Length -GT 0)) {
    throw 'The supplied _DocsMedia input did not produce usable media.'
}

$frameworksPath = Join-Path $frameworksRoot 'frameworks.xml'
$frameworks.Save($frameworksPath)
$libraryArguments = @()
foreach ($path in @($ReferencePath) + $monikerDirectories | Select-Object -Unique) {
    $libraryArguments += @('--lib', $path)
}

Push-Location $frameworksRoot
try {
    & $DotnetPath $MdocPath update --delete --fno-assembly-versions --fignore-missing-types `
        --lang DocId --frameworks $frameworksPath --out $stagingPath @libraryArguments
    if ($LASTEXITCODE -ne 0) {
        throw "mdoc failed with exit code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}

$preservedItems = @('docfx.json', 'SkiaSharpAPI-breadcrumb', 'xml')
Get-ChildItem -Path $OutputRoot -Force | Where-Object { $_.Name -notin $preservedItems } | Remove-Item -Recurse -Force
Get-ChildItem -Path $stagingPath -Force | Where-Object { $_.Name -ne 'xml' } | Copy-Item -Destination $OutputRoot -Recurse -Force

Write-Host "Replaced generated ECMA XML and media in $OutputRoot from blank staging."
if (-not $KeepStaging) {
    Remove-Item -Recurse -Force $workRoot
}
