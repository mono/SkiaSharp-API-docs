[CmdletBinding()]
param(
    [string] $PackageRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) '.artifacts/api-docs/packages'),
    [string] $OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'SkiaSharpAPI'),
    [switch] $KeepStaging
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Expand-PackageArchives([string[]] $inputPaths, [string] $destinationRoot) {
    New-Item -ItemType Directory -Force -Path $destinationRoot | Out-Null
    $archives = foreach ($inputPath in $inputPaths) {
        if (-not (Test-Path $inputPath)) {
            throw "Package input '$inputPath' does not exist."
        }
        if ((Get-Item $inputPath).PSIsContainer) {
            Get-ChildItem -Path $inputPath -Filter '*.nupkg' -File -Recurse
        } else {
            Get-Item $inputPath
        }
    }
    if (-not $archives) {
        throw 'The supplied package input did not contain any .nupkg files.'
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

function Get-DotnetRoot {
    if ($env:DOTNET_ROOT -and (Test-Path $env:DOTNET_ROOT)) {
        return $env:DOTNET_ROOT
    }

    $sdkDirectory = (& dotnet --list-sdks | Select-Object -Last 1) -replace '^.+ \[(.+)[\\/]sdk\]$', '$1'
    if (-not $sdkDirectory -or -not (Test-Path $sdkDirectory)) {
        throw 'Unable to locate the installed .NET SDK root. Set DOTNET_ROOT explicitly.'
    }
    return $sdkDirectory
}

function Get-ReferencePaths([string] $dotnetRoot, [string] $packageExtractionPath) {
    $referencesRoot = Join-Path $workRoot 'references'
    New-Item -ItemType Directory -Force -Path $referencesRoot | Out-Null
    Get-ChildItem -Path $packageExtractionPath -Filter '*.dll' -File -Recurse |
        Sort-Object FullName |
        ForEach-Object {
            $destination = Join-Path $referencesRoot $_.Name
            if (-not (Test-Path $destination)) {
                Copy-Item -Force $_.FullName $destination
            }
        }

    $packNames = @(
        'Microsoft.NETCore.App.Ref',
        'Microsoft.WindowsDesktop.App.Ref',
        'Microsoft.Android.Ref',
        'Microsoft.iOS.Ref',
        'Microsoft.MacCatalyst.Ref',
        'Microsoft.macOS.Ref',
        'Microsoft.tvOS.Ref',
        'Microsoft.Maui.Controls.Ref'
    )
    $paths = @($referencesRoot)
    foreach ($packName in $packNames) {
        $packPath = Join-Path $dotnetRoot "packs/$packName"
        if (Test-Path $packPath) {
            $paths += Get-ChildItem -Path $packPath -Directory | ForEach-Object {
                Get-ChildItem -Path (Join-Path $_.FullName 'ref') -Directory -ErrorAction SilentlyContinue
            } | Select-Object -ExpandProperty FullName
        }
    }
    return $paths | Select-Object -Unique
}

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw 'The .NET SDK required to run mdoc is not available.'
}
if (-not (Test-Path $OutputRoot)) {
    throw "Output root '$OutputRoot' does not exist."
}
if (-not (Test-Path $PackageRoot)) {
    throw "Prepared package root '$PackageRoot' does not exist. Run eng/Setup-ApiDocs.ps1 first."
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$workRoot = Join-Path $repositoryRoot '.artifacts/api-docs'
$conversionRoot = Join-Path $workRoot 'conversion'
$nuGetsExtractionPath = Join-Path $conversionRoot 'nugets'
$mediaExtractionPath = Join-Path $conversionRoot 'media'
$frameworksRoot = Join-Path $conversionRoot 'frameworks'
$stagingPath = Join-Path $conversionRoot 'staging'
$compilerDocumentationPath = Join-Path $conversionRoot 'compiler-documentation.xml'

Remove-Item -Recurse -Force $conversionRoot -ErrorAction Ignore
New-Item -ItemType Directory -Force -Path $nuGetsExtractionPath, $mediaExtractionPath, $frameworksRoot, $stagingPath | Out-Null

$nuGetsArchives = Get-ChildItem -Path $packageRoot -Filter '_nugets*.nupkg' -File -Recurse
$mediaArchives = Get-ChildItem -Path $packageRoot -Filter '_docsmedia*.nupkg' -File -Recurse
if (-not $nuGetsArchives) {
    throw "Prepared package root '$PackageRoot' does not contain _NuGets."
}
if (-not $mediaArchives) {
    throw "Prepared package root '$PackageRoot' does not contain _DocsMedia."
}

$nuGetsPackages = Expand-PackageArchives $nuGetsArchives.FullName $nuGetsExtractionPath
$mediaPackages = Expand-PackageArchives $mediaArchives.FullName $mediaExtractionPath

$frameworks = New-Object System.Xml.XmlDocument
$frameworkRoot = $frameworks.CreateElement('Frameworks')
[void] $frameworks.AppendChild($frameworkRoot)
$compilerDocumentation = New-Object System.Xml.XmlDocument
$compilerDocumentationRoot = $compilerDocumentation.CreateElement('doc')
[void] $compilerDocumentation.AppendChild($compilerDocumentationRoot)
$compilerDocumentationAssembly = $compilerDocumentation.CreateElement('assembly')
$compilerDocumentationName = $compilerDocumentation.CreateElement('name')
$compilerDocumentationName.InnerText = 'SkiaSharp API packages'
[void] $compilerDocumentationAssembly.AppendChild($compilerDocumentationName)
[void] $compilerDocumentationRoot.AppendChild($compilerDocumentationAssembly)
$compilerDocumentationMembers = $compilerDocumentation.CreateElement('members')
[void] $compilerDocumentationRoot.AppendChild($compilerDocumentationMembers)
$compilerDocumentationIds = @{}
$monikerDirectories = @()
foreach ($packagePath in $nuGetsPackages) {
    $packageId = Get-PackageId $packagePath
    if ($null -eq $packageId -or
        $packageId -notmatch '^(HarfBuzzSharp|SkiaSharp)(\.|$)' -or
        $packageId -match '^SkiaSharp\.Views\.Uno' -or
        $packageId -match 'NativeAssets') {
        continue
    }

    Get-ChildItem -Path $packagePath -Filter '*.xml' -File -Recurse | ForEach-Object {
        [xml] $documentation = Get-Content -Raw -Path $_.FullName
        foreach ($member in $documentation.SelectNodes('/doc/members/member')) {
            $documentationId = $member.GetAttribute('name')
            if ($documentationId -and -not $compilerDocumentationIds.ContainsKey($documentationId)) {
                [void] $compilerDocumentationMembers.AppendChild($compilerDocumentation.ImportNode($member, $true))
                $compilerDocumentationIds[$documentationId] = $true
            }
        }
    }

    $referenceAssemblies = Get-ChildItem -Path (Join-Path $packagePath 'ref') -Filter '*.dll' -Recurse -ErrorAction Ignore
    $assemblies = if ($referenceAssemblies) { $referenceAssemblies } else {
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
    throw 'The downloaded _NuGets package set contains no managed SkiaSharp or HarfBuzzSharp assemblies.'
}
if ($compilerDocumentationIds.Count -eq 0) {
    throw 'The downloaded _NuGets package set contains no compiler XML documentation.'
}

$stagingXmlPath = Join-Path $stagingPath 'xml'
New-Item -ItemType Directory -Force -Path $stagingXmlPath | Out-Null
Copy-Item -Force (Join-Path $OutputRoot 'xml/_filter.xml') $stagingXmlPath
Copy-Item -Force (Join-Path $OutputRoot '_filter.xml') $stagingPath

$mediaFiles = $mediaPackages |
    ForEach-Object { Get-ChildItem -Path $_ -File -Recurse } |
    Where-Object { $_.Extension -match '^\.(gif|jpe?g|png|svg|webp)$' }
if (-not $mediaFiles) {
    throw 'The downloaded _DocsMedia package contains no supported media files.'
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
    throw 'The downloaded _DocsMedia package did not produce usable media.'
}

$frameworksPath = Join-Path $frameworksRoot 'frameworks.xml'
$frameworks.Save($frameworksPath)
$compilerDocumentation.Save($compilerDocumentationPath)
$libraryArguments = @()
foreach ($path in @(Get-ReferencePaths (Get-DotnetRoot) $nuGetsExtractionPath) + $monikerDirectories | Select-Object -Unique) {
    $libraryArguments += @('--lib', $path)
}

Push-Location $frameworksRoot
try {
    & (Join-Path $PSScriptRoot 'MDoc.ps1') update --delete --fno-assembly-versions --fignore-missing-types `
        --import $compilerDocumentationPath `
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
    Remove-Item -Recurse -Force $conversionRoot
}
