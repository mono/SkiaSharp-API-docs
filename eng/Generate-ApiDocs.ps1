[CmdletBinding()]
param(
    [string] $PackageRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts/api-docs/packages'),
    [string] $DependencyRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts/api-docs/dependencies'),
    [string] $OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'SkiaSharpAPI')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'ApiDocs.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'ApiDocs.Normalization.psm1') -Force -DisableNameChecking

# Maps related package IDs into the public OpenPublishing moniker layout.
# Views MAUI remains distinct from the general SkiaSharp Views moniker.
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

# Counts metadata type definitions without loading the target assembly.
# This retains the richest TFM variant when packages contain colliding assembly names.
function Get-AssemblyTypeCount([string] $assemblyPath) {
    $stream = [IO.File]::OpenRead($assemblyPath)
    try {
        $reader = [Reflection.PortableExecutable.PEReader]::new($stream)
        try {
            if (-not $reader.HasMetadata) {
                return 0
            }
            return [Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($reader).TypeDefinitions.Count
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

# Finds compiler XML alongside an implementation assembly when a package's ref/ assets omit it.
function Get-AssemblyDocumentationPath([string] $packagePath, [IO.FileInfo] $assembly) {
    $documentationName = [IO.Path]::ChangeExtension($assembly.Name, '.xml')
    $adjacentDocumentationPath = Join-Path $assembly.DirectoryName $documentationName
    if (Test-Path $adjacentDocumentationPath) {
        return $adjacentDocumentationPath
    }

    $referenceRoot = Join-Path $packagePath 'ref'
    if ($assembly.FullName.StartsWith($referenceRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $relativeDirectory = [IO.Path]::GetRelativePath($referenceRoot, $assembly.DirectoryName)
        $implementationDocumentationPath = Join-Path (Join-Path $packagePath 'lib') (Join-Path $relativeDirectory $documentationName)
        if (Test-Path $implementationDocumentationPath) {
            return $implementationDocumentationPath
        }
    }

    return Get-ChildItem -Path (Join-Path $packagePath 'lib') -Filter $documentationName -File -Recurse -ErrorAction Ignore |
        Sort-Object FullName |
        Select-Object -First 1 -ExpandProperty FullName
}

# Ensures every managed assembly selected for ECMA generation has package-authored XML.
function Assert-AssemblyDocumentation([string] $packagePath, [IO.FileInfo[]] $assemblies) {
    $missingDocumentation = @(
        foreach ($assembly in $assemblies) {
            if (-not (Get-AssemblyDocumentationPath $packagePath $assembly)) {
                $assembly.FullName
            }
        }
    )
    if ($missingDocumentation) {
        throw "Managed assemblies without matching XML documentation:`n$($missingDocumentation -join [Environment]::NewLine)"
    }
}

# Collects only downloaded product and resolver assemblies for mdoc resolution.
function Get-ReferencePaths([string[]] $packageExtractionPaths) {
    $referencesRoot = Join-Path $workRoot 'references'
    New-Item -ItemType Directory -Force -Path $referencesRoot | Out-Null
    Get-ChildItem -Path $packageExtractionPaths -Filter '*.dll' -File -Recurse |
        Sort-Object FullName |
        ForEach-Object {
            $destination = Join-Path $referencesRoot $_.Name
            if (-not (Test-Path $destination)) {
                Copy-Item -Force $_.FullName $destination
            }
        }

    return $referencesRoot
}

# Removes indentation from otherwise blank generated lines without changing documentation text.
function Remove-WhitespaceOnlyLines([string] $root) {
    foreach ($file in Get-ChildItem -Path $root -Filter '*.xml' -File -Recurse) {
        $content = [IO.File]::ReadAllText($file.FullName)
        $normalizedContent = [regex]::Replace($content, '(?m)^[\t ]+(?=\r?$)', '')
        if ($normalizedContent -ne $content) {
            [IO.File]::WriteAllText($file.FullName, $normalizedContent)
        }
    }
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
if (-not (Test-Path $DependencyRoot)) {
    throw "Prepared dependency root '$DependencyRoot' does not exist. Run eng/Setup-ApiDocs.ps1 first."
}

# Create a clean conversion workspace without altering publishing infrastructure.
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$workRoot = Join-Path $repositoryRoot 'artifacts/api-docs'
$conversionRoot = Join-Path $workRoot 'conversion'
$nuGetsExtractionPath = Join-Path $conversionRoot 'nugets'
$dependencyExtractionPath = Join-Path $conversionRoot 'dependencies'
$mediaExtractionPath = Join-Path $conversionRoot 'media'
$frameworksRoot = Join-Path $conversionRoot 'frameworks'
$stagingPath = Join-Path $conversionRoot 'staging'
$referencesRoot = Join-Path $workRoot 'references'

Remove-Item -Recurse -Force $conversionRoot -ErrorAction Ignore
New-Item -ItemType Directory -Force -Path $nuGetsExtractionPath, $dependencyExtractionPath, $mediaExtractionPath, $frameworksRoot, $stagingPath | Out-Null

$nuGetsArchives = Get-ChildItem -Path $packageRoot -Filter '_nugets*.nupkg' -File -Recurse
$mediaArchives = Get-ChildItem -Path $packageRoot -Filter '_docsmedia*.nupkg' -File -Recurse
if (-not $nuGetsArchives) {
    throw "Prepared package root '$PackageRoot' does not contain _NuGets."
}

# Expand product, resolver, and required media packages into isolated staging inputs.
$nuGetsPackages = Expand-NuGetPackageArchives $nuGetsArchives.FullName $nuGetsExtractionPath
$dependencyArchives = Get-ChildItem -Path $DependencyRoot -Filter '*.nupkg' -File -Recurse
$dependencyPackages = if ($dependencyArchives) {
    Expand-NuGetPackageArchives $dependencyArchives.FullName $dependencyExtractionPath
} else {
    @()
}
if (-not $mediaArchives) {
    throw "Prepared package root '$PackageRoot' does not contain _DocsMedia."
}
$mediaPackages = Expand-NuGetPackageArchives $mediaArchives.FullName $mediaExtractionPath
$monikerDirectories = @()

# Stage the richest assembly variant and its paired compiler XML under each public moniker.
foreach ($packagePath in $nuGetsPackages) {
    $packageId = Get-NuGetPackageId $packagePath
    if ($null -eq $packageId -or
        $packageId -notmatch '^(HarfBuzzSharp|SkiaSharp)(\.|$)' -or
        $packageId -match '^SkiaSharp\.Views\.Uno' -or
        $packageId -match 'NativeAssets') {
        continue
    }

    $referenceAssemblies = Get-ChildItem -Path (Join-Path $packagePath 'ref') -Filter '*.dll' -Recurse -ErrorAction Ignore
    $assemblies = if ($referenceAssemblies) { $referenceAssemblies } else {
        Get-ChildItem -Path (Join-Path $packagePath 'lib') -Filter '*.dll' -Recurse -ErrorAction Ignore
    }
    if (-not $assemblies) {
        continue
    }
    Assert-AssemblyDocumentation $packagePath $assemblies

    $moniker = Get-Moniker $packageId
    $monikerPath = Join-Path $frameworksRoot $moniker
    if ($monikerDirectories -notcontains $monikerPath) {
        New-Item -ItemType Directory -Force -Path $monikerPath | Out-Null
        $monikerDirectories += $monikerPath
    }
    foreach ($assembly in $assemblies | Sort-Object FullName) {
        $destination = Join-Path $monikerPath $assembly.Name
        if (-not (Test-Path $destination) -or
            (Get-AssemblyTypeCount $assembly.FullName) -gt (Get-AssemblyTypeCount $destination)) {
            Copy-Item -Force $assembly.FullName $destination
            $documentationPath = Get-AssemblyDocumentationPath $packagePath $assembly
            $documentationDestination = [IO.Path]::ChangeExtension($destination, '.xml')
            if ($documentationPath -and (Test-Path $documentationPath)) {
                Copy-Item -Force $documentationPath $documentationDestination
            } else {
                Remove-Item -Force $documentationDestination -ErrorAction Ignore
            }
        }
    }
}
if ($monikerDirectories.Count -eq 0) {
    throw 'The downloaded _NuGets package set contains no managed SkiaSharp or HarfBuzzSharp assemblies.'
}

# Package XML is an mdoc export in the current transport contract. Normalize
# only its legacy DocId encodings before mdoc matches it to generated metadata.
foreach ($documentation in Get-ChildItem -Path $frameworksRoot -Filter '*.xml' -File -Recurse) {
    if ($documentation.Name -ne 'frameworks.xml') {
        [void](Normalize-MdocImportDocumentation $documentation.FullName)
    }
}

$stagingXmlPath = Join-Path $stagingPath 'xml'
New-Item -ItemType Directory -Force -Path $stagingXmlPath | Out-Null
Copy-Item -Force (Join-Path $OutputRoot 'xml/_filter.xml') $stagingXmlPath
Copy-Item -Force (Join-Path $OutputRoot '_filter.xml') $stagingPath

# Let mdoc derive framework-scoped compiler XML imports from the staged DLL/XML pairs.
$frameworksPath = Join-Path $frameworksRoot 'frameworks.xml'
& (Join-Path $PSScriptRoot 'MDoc.ps1') fx-bootstrap --frameworks $frameworksRoot --importContent true
if ($LASTEXITCODE -ne 0) {
    throw "mdoc fx-bootstrap failed with exit code $LASTEXITCODE."
}
[xml] $frameworks = Get-Content -Raw -Path $frameworksPath
foreach ($import in $frameworks.SelectNodes('/Frameworks/Framework/import')) {
    $import.InnerText = $import.InnerText -replace '[\\/]', [IO.Path]::DirectorySeparatorChar
}
$frameworks.Save($frameworksPath)
$libraryArguments = @()
foreach ($path in @(Get-ReferencePaths @($nuGetsExtractionPath, $dependencyExtractionPath)) + $monikerDirectories | Select-Object -Unique) {
    $libraryArguments += @('--lib', $path)
}

Push-Location $frameworksRoot
try {
    & (Join-Path $PSScriptRoot 'MDoc.ps1') update --debug --delete --fno-assembly-versions --fignore-missing-types `
        --lang DocId --frameworks $frameworksPath --out $stagingPath @libraryArguments
    if ($LASTEXITCODE -ne 0) {
        throw "mdoc failed with exit code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}

$canonicalizations = @(Get-MdocObsoleteTypeCanonicalizations)
foreach ($canonicalization in $canonicalizations) {
    [void](Remove-MdocObsoleteTypeCollision `
        -OutputRoot $stagingPath `
        -LegacyType $canonicalization.LegacyType `
        -CanonicalType $canonicalization.CanonicalType `
        -RequiredObsoleteMessage $canonicalization.RequiredObsoleteMessage)
    $frameworkPath = Join-Path $frameworksRoot $canonicalization.Framework
    $assemblyPath = Join-Path $frameworkPath $canonicalization.Assembly
    $importPath = [IO.Path]::ChangeExtension($assemblyPath, '.xml')
    if (-not (Test-Path $assemblyPath) -or -not (Test-Path $importPath)) {
        throw "Canonical type '$($canonicalization.CanonicalType)' does not have its required package DLL/XML input."
    }

    # mdoc conflates this explicitly obsolete type with its case-distinct
    # replacement in framework mode. Generate the canonical metadata identity
    # directly and import its exact package XML rather than reusing ECMA prose.
    & (Join-Path $PSScriptRoot 'MDoc.ps1') update --delete --fno-assembly-versions --fignore-missing-types `
        --lang DocId "--type=$($canonicalization.CanonicalType)" --import $importPath --out $stagingPath `
        --lib $referencesRoot --lib $frameworkPath $assemblyPath
    if ($LASTEXITCODE -ne 0) {
        throw "mdoc canonical-type generation for '$($canonicalization.CanonicalType)' failed with exit code $LASTEXITCODE."
    }
}
$canonicalizations | ConvertTo-Json | Set-Content -NoNewline -Path (Join-Path $conversionRoot 'mdoc-canonicalizations.json')

$stagedAssemblies = Get-ChildItem -Path $monikerDirectories -Filter '*.dll' -File -Recurse
$filteredDocIds = @(
    Get-NonPublicExplicitInterfaceMemberDocIds $stagedAssemblies.FullName
    Get-GeneratedResourceDesignerConstructorDocIds $stagedAssemblies.FullName
) | Select-Object -Unique
$filteredDocIds = @(Remove-GeneratedMemberDocIds $stagingPath $filteredDocIds)
$filteredDocIds | ConvertTo-Json | Set-Content -NoNewline -Path (Join-Path $conversionRoot 'mdoc-filtered-members.json')

Remove-WhitespaceOnlyLines $stagingPath

# Copy required package media before promoting the complete generated tree.
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

# Atomically replace generated content while retaining DocFX, filters, and breadcrumbs.
$preservedItems = @('docfx.json', '_filter.xml', 'SkiaSharpAPI-breadcrumb', 'xml')
Get-ChildItem -Path $OutputRoot -Force | Where-Object { $_.Name -notin $preservedItems } | Remove-Item -Recurse -Force
Get-ChildItem -Path $stagingPath -Force | Where-Object { $_.Name -ne 'xml' } | Copy-Item -Destination $OutputRoot -Recurse -Force

Write-Host "Replaced generated ECMA XML and media in $OutputRoot from blank staging."
