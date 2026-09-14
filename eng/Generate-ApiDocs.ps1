[CmdletBinding()]
param(
    [string] $PackageRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts/api-docs/packages'),
    [string] $DependencyRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts/api-docs/dependencies'),
    [string] $OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'SkiaSharpAPI'),
    [string] $ManifestPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'eng/api-docs-packages.json'),
    [string] $ProvenancePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts/api-docs/provenance.json'),
    [string] $CompletenessReportPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts/api-docs/completeness.json')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'ApiDocs.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'ApiDocs.Normalization.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'ApiDocs.Completeness.psm1') -Force -DisableNameChecking

# Collects only downloaded product and resolver assemblies for mdoc resolution.
function Get-ReferencePaths([string[]] $packageExtractionPaths) {
    $referencesRoot = Join-Path $workRoot 'references'
    New-Item -ItemType Directory -Force -Path $referencesRoot | Out-Null
    $referencePaths = @()
    foreach ($assembly in @(Get-ChildItem -Path $packageExtractionPaths -Filter '*.dll' -File -Recurse |
        Sort-Object FullName)) {
        $referencePath = Join-Path $referencesRoot (Get-FileSha256 $assembly.FullName)
        New-Item -ItemType Directory -Force -Path $referencePath | Out-Null
        $destination = Join-Path $referencePath $assembly.Name
        if (-not (Test-Path $destination)) {
            Copy-Item -Force $assembly.FullName $destination
        }
        $referencePaths += $referencePath
    }

    return @($referencePaths | Sort-Object -Unique)
}

function Assert-SelectedAssetInputs([object[]] $SelectedAssets) {
    $destinations = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $sources = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($selectedAsset in $SelectedAssets) {
        if (-not (Test-Path -LiteralPath $selectedAsset.AssemblyPath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $selectedAsset.DocumentationPath -PathType Leaf)) {
            throw "Selected package input '$($selectedAsset.PackageId):$($selectedAsset.Asset)' is incomplete."
        }
        if (-not $destinations.Add($selectedAsset.StagedAssemblyPath)) {
            throw "Selected package assets collide at '$($selectedAsset.StagedAssemblyPath)'."
        }
        if (-not $sources.Add($selectedAsset.FrameworkSource)) {
            throw "Selected package assets collide in mdoc framework source '$($selectedAsset.FrameworkSource)'."
        }
        if ((Split-Path -Parent $selectedAsset.StagedAssemblyPath) -ne
            (Join-Path $frameworksRoot $selectedAsset.FrameworkSource)) {
            throw "Selected package asset '$($selectedAsset.PackageId):$($selectedAsset.Asset)' is not staged directly beneath the frameworks root."
        }
    }
}

function Assert-DeterministicAssetOrder([object[]] $SelectedAssets) {
    $actual = @($SelectedAssets | ForEach-Object { "$($_.PackageId)`n$($_.Asset)" })
    $expected = @($actual | Sort-Object)
    if (($actual -join "`0") -cne ($expected -join "`0")) {
        throw 'Selected package assets must be processed in deterministic package and asset order.'
    }
}

function Assert-FrameworkStaging([object[]] $SelectedAssets) {
    foreach ($selectedAsset in $SelectedAssets) {
        $sourceDirectory = Join-Path $frameworksRoot $selectedAsset.FrameworkSource
        if ((Split-Path -Parent $sourceDirectory) -ne $frameworksRoot) {
            throw "Framework source '$sourceDirectory' is not an immediate child of '$frameworksRoot'."
        }
        $sourceAssemblies = @(Get-ChildItem -LiteralPath $sourceDirectory -Filter '*.dll' -File)
        if ($sourceAssemblies.Count -ne 1 -or $sourceAssemblies[0].FullName -ne $selectedAsset.StagedAssemblyPath) {
            throw "Framework source '$sourceDirectory' must contain exactly its selected DLL."
        }
        if (-not (Test-Path -LiteralPath $selectedAsset.StagedDocumentationPath -PathType Leaf)) {
            throw "Framework source '$sourceDirectory' is missing its selected adjacent compiler XML."
        }
    }

    $unoAssets = @($SelectedAssets | Where-Object { $_.PackageId -eq 'SkiaSharp.Views.Uno.WinUI' })
    if ($unoAssets.Count -lt 2 -or @($unoAssets.FrameworkSource | Sort-Object -Unique).Count -ne $unoAssets.Count) {
        throw 'Same-named Uno assets were not staged in distinct immediate mdoc framework sources.'
    }
    $gtkAssets = @($SelectedAssets | Where-Object { $_.PackageId -in @('SkiaSharp.Views.Gtk3', 'SkiaSharp.Views.Gtk4') })
    if ($gtkAssets.Count -eq 0 -or @($gtkAssets.FrameworkSource | Where-Object { $_ -notmatch 'gtk' }).Count -ne 0) {
        throw 'GTK assets were not staged in their own stable mdoc framework sources.'
    }
}

function Convert-MdocFrameworkAvailabilityToPublicMonikers([string] $StagingPath, [object[]] $SelectedAssets) {
    $monikersByFramework = @{}
    $publicMonikers = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($selectedAsset in $SelectedAssets) {
        $monikersByFramework[$selectedAsset.FrameworkName] = $selectedAsset.Moniker
        [void]$publicMonikers.Add($selectedAsset.Moniker)
    }

    foreach ($file in Get-ChildItem -Path $StagingPath -Filter '*.xml' -File -Recurse | Sort-Object FullName) {
        [xml] $document = Get-Content -Raw -LiteralPath $file.FullName
        foreach ($attribute in @($document.SelectNodes('//@FrameworkAlternate'))) {
            $publicValues = [Collections.Generic.List[string]]::new()
            foreach ($frameworkName in $attribute.Value.Split(';', [StringSplitOptions]::RemoveEmptyEntries)) {
                if (-not $monikersByFramework.ContainsKey($frameworkName)) {
                    throw "mdoc emitted unknown internal framework '$frameworkName' in '$($file.FullName)'."
                }
                $moniker = $monikersByFramework[$frameworkName]
                if (-not $publicValues.Contains($moniker)) {
                    $publicValues.Add($moniker)
                }
            }
            if ($publicValues.Count -eq $publicMonikers.Count) {
                [void]$attribute.OwnerElement.RemoveAttributeNode($attribute)
            }
            else {
                $attribute.Value = $publicValues -join ';'
            }
        }
        $document.Save($file.FullName)
    }
}

function Merge-MdocFrameworkIndexes([string] $StagingPath, [object[]] $SelectedAssets) {
    $indexPath = Join-Path $StagingPath 'FrameworksIndex'
    if (-not (Test-Path -LiteralPath $indexPath -PathType Container)) {
        throw 'mdoc did not emit framework availability indexes.'
    }

    $assetsByMoniker = @{}
    $indexesByFramework = @{}
    foreach ($selectedAsset in $SelectedAssets | Sort-Object FrameworkName) {
        $internalIndexPath = Join-Path $indexPath "$($selectedAsset.FrameworkName).xml"
        if (-not (Test-Path -LiteralPath $internalIndexPath -PathType Leaf)) {
            throw "mdoc did not emit an index for framework '$($selectedAsset.FrameworkName)'."
        }
        [xml] $indexesByFramework[$selectedAsset.FrameworkName] = Get-Content -Raw -LiteralPath $internalIndexPath
        if (-not $assetsByMoniker.ContainsKey($selectedAsset.Moniker)) {
            $assetsByMoniker[$selectedAsset.Moniker] = [Collections.Generic.List[object]]::new()
        }
        $assetsByMoniker[$selectedAsset.Moniker].Add($selectedAsset)
    }

    Get-ChildItem -LiteralPath $indexPath -Filter '*.xml' -File | Remove-Item -Force
    foreach ($moniker in @($assetsByMoniker.Keys | Sort-Object)) {
        $publicIndex = [Xml.XmlDocument]::new()
        [void]$publicIndex.AppendChild($publicIndex.CreateXmlDeclaration('1.0', 'utf-8', $null))
        $framework = $publicIndex.CreateElement('Framework')
        $framework.SetAttribute('Name', $moniker)
        [void]$publicIndex.AppendChild($framework)
        $assemblies = $publicIndex.CreateElement('Assemblies')
        [void]$framework.AppendChild($assemblies)
        $assemblyKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $typesByKey = @{}

        foreach ($selectedAsset in $assetsByMoniker[$moniker] | Sort-Object FrameworkName) {
            $internalIndex = $indexesByFramework[$selectedAsset.FrameworkName]
            foreach ($assembly in @($internalIndex.SelectNodes('/Framework/Assemblies/Assembly'))) {
                $key = "$($assembly.GetAttribute('Name'))`n$($assembly.GetAttribute('Version'))"
                if ($assemblyKeys.Add($key)) {
                    [void]$assemblies.AppendChild($publicIndex.ImportNode($assembly, $true))
                }
            }
            foreach ($sourceNamespace in @($internalIndex.SelectNodes('/Framework/Namespace'))) {
                $namespaceName = $sourceNamespace.GetAttribute('Name')
                # XmlDocument does not offer a safe parameterized XPath API; compare attributes directly.
                $targetNamespace = @($framework.SelectNodes('Namespace') | Where-Object {
                    $_.GetAttribute('Name') -eq $namespaceName
                }) | Select-Object -First 1
                if ($null -eq $targetNamespace) {
                    $targetNamespace = $publicIndex.CreateElement('Namespace')
                    $targetNamespace.SetAttribute('Name', $namespaceName)
                    [void]$framework.AppendChild($targetNamespace)
                }
                foreach ($sourceType in @($sourceNamespace.SelectNodes('Type'))) {
                    $typeKey = "$namespaceName`n$($sourceType.GetAttribute('Id'))"
                    $targetType = $typesByKey[$typeKey]
                    if ($null -eq $targetType) {
                        $targetType = $publicIndex.CreateElement('Type')
                        foreach ($attribute in $sourceType.Attributes) {
                            $targetType.SetAttribute($attribute.Name, $attribute.Value)
                        }
                        [void]$targetNamespace.AppendChild($targetType)
                        $typesByKey[$typeKey] = $targetType
                    }
                    $memberIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                    foreach ($member in @($targetType.SelectNodes('Member'))) {
                        [void]$memberIds.Add($member.GetAttribute('Id'))
                    }
                    foreach ($member in @($sourceType.SelectNodes('Member'))) {
                        if ($memberIds.Add($member.GetAttribute('Id'))) {
                            [void]$targetType.AppendChild($publicIndex.ImportNode($member, $true))
                        }
                    }
                }
            }
        }
        if ($assemblies.ChildNodes.Count -eq 0) {
            [void]$framework.RemoveChild($assemblies)
        }
        $publicIndex.Save((Join-Path $indexPath "$moniker.xml"))
    }
}

function Assert-GeneratedDocumentation([string] $StagingPath, [object[]] $SelectedAssets) {
    if ($SelectedAssets.Count -eq 0) {
        throw 'No selected package assets were available for generation.'
    }
    $typeFiles = @(Get-ChildItem -Path $StagingPath -Filter '*.xml' -File -Recurse |
        Where-Object {
            [xml] $document = Get-Content -Raw -LiteralPath $_.FullName
            $document.DocumentElement.LocalName -eq 'Type'
        })
    if ($typeFiles.Count -eq 0) {
        throw 'mdoc did not generate any ECMA type documentation from the selected assets.'
    }
}

function Promote-GeneratedApiDocs([string] $OutputRoot, [string] $StagingPath) {
    $parent = Split-Path -Parent $OutputRoot
    $leaf = Split-Path -Leaf $OutputRoot
    $candidate = Join-Path $parent ".$leaf.next"
    $backup = Join-Path $parent ".$leaf.previous"
    Remove-Item -Recurse -Force $candidate, $backup -ErrorAction Ignore
    try {
        Copy-Item -Recurse -Force $OutputRoot $candidate
        $preservedItems = @('docfx.json', '_filter.xml', 'SkiaSharpAPI-breadcrumb', 'xml')
        Get-ChildItem -Path $candidate -Force | Where-Object { $_.Name -notin $preservedItems } | Remove-Item -Recurse -Force
        Get-ChildItem -Path $StagingPath -Force | Where-Object { $_.Name -ne 'xml' } |
            Copy-Item -Destination $candidate -Recurse -Force
        if (-not (Get-ChildItem -Path $candidate -Filter '*.xml' -File -Recurse)) {
            throw 'Generated candidate contains no ECMA XML files.'
        }
        Rename-Item -LiteralPath $OutputRoot -NewName (Split-Path -Leaf $backup)
        try {
            Rename-Item -LiteralPath $candidate -NewName $leaf
        }
        catch {
            Rename-Item -LiteralPath $backup -NewName $leaf
            throw
        }
        Remove-Item -Recurse -Force $backup
    }
    catch {
        Remove-Item -Recurse -Force $candidate -ErrorAction Ignore
        if (-not (Test-Path -LiteralPath $OutputRoot) -and (Test-Path -LiteralPath $backup)) {
            Rename-Item -LiteralPath $backup -NewName $leaf
        }
        throw
    }
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
$manifest = Read-ApiDocsManifest $ManifestPath
if (-not (Test-Path -LiteralPath $ProvenancePath -PathType Leaf)) {
    throw "Package provenance '$ProvenancePath' does not exist. Run eng/Setup-ApiDocs.ps1 first."
}
$provenance = Get-Content -Raw -LiteralPath $ProvenancePath | ConvertFrom-Json -Depth 32
if ($provenance.schemaVersion -ne 1 -or
    $provenance.classificationManifestSha256 -cne (Get-FileSha256 $ManifestPath)) {
    throw 'Package provenance does not match the committed classification manifest. Run setup again.'
}
Remove-Item -Force $CompletenessReportPath -ErrorAction Ignore
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
$selectedAssets = @()
$frameworkDirectories = @()

# The manifest, not a TFM heuristic, is the complete selection authority.
foreach ($classification in $manifest.packages | Sort-Object id) {
    if ($classification.classification -eq 'exclude') {
        continue
    }
    $packagePaths = @($nuGetsPackages | Where-Object { (Get-NuGetPackageId $_) -ieq $classification.id })
    if ($packagePaths.Count -ne 1) {
        throw "Manifest package '$($classification.id)' must occur exactly once in the transport archives; found $($packagePaths.Count)."
    }
    $packagePath = $packagePaths[0]
    $assets = @(
        foreach ($assetRoot in $classification.assetRoots) {
            Get-ChildItem -Path (Join-Path $packagePath $assetRoot) -Filter '*.dll' -File -Recurse -ErrorAction Ignore
        }
    )
    if ($assets.Count -eq 0) {
        throw "Package '$($classification.id)' has no managed assets in its declared asset roots."
    }
    foreach ($assetFile in $assets | Sort-Object FullName) {
        $asset = [IO.Path]::GetRelativePath($packagePath, $assetFile.FullName).Replace([IO.Path]::DirectorySeparatorChar, '/')
        $assemblyPath = $assetFile.FullName
        $documentationPath = [IO.Path]::ChangeExtension($assemblyPath, '.xml')
        $frameworkName = Get-ApiDocsFrameworkName $classification.moniker $classification.id $asset
        $frameworkDirectory = Join-Path $frameworksRoot $frameworkName
        $stagedAssemblyPath = Join-Path $frameworkDirectory ([IO.Path]::GetFileName($asset))
        $selectedAssets += [PSCustomObject]@{
            PackageId = $classification.id
            Moniker = $classification.moniker
            Asset = $asset
            AssemblyPath = $assemblyPath
            DocumentationPath = $documentationPath
            FrameworkName = $frameworkName
            FrameworkSource = $frameworkName
            StagedAssemblyPath = $stagedAssemblyPath
            StagedDocumentationPath = [IO.Path]::ChangeExtension($stagedAssemblyPath, '.xml')
        }
        if ($frameworkDirectories -notcontains $frameworkDirectory) {
            $frameworkDirectories += $frameworkDirectory
        }
    }
}
Assert-SelectedAssetInputs $selectedAssets
if ($selectedAssets.Count -eq 0) {
    throw 'The downloaded _NuGets package set contains no managed SkiaSharp or HarfBuzzSharp assemblies.'
}
$selectedAssets = @($selectedAssets | Sort-Object PackageId, Asset)
Assert-DeterministicAssetOrder $selectedAssets
foreach ($selectedAsset in $selectedAssets) {
    $record = @($provenance.selectedAssets | Where-Object {
        $_.packageId -ieq $selectedAsset.PackageId -and $_.asset -ceq $selectedAsset.Asset
    })
    if ($record.Count -ne 1 -or
        $record[0].sha256 -cne (Get-FileSha256 $selectedAsset.AssemblyPath) -or
        $record[0].documentationSha256 -cne (Get-FileSha256 $selectedAsset.DocumentationPath)) {
        throw "Package provenance does not match selected asset '$($selectedAsset.PackageId):$($selectedAsset.Asset)'."
    }
}
foreach ($selectedAsset in $selectedAssets | Sort-Object PackageId, Asset) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $selectedAsset.StagedAssemblyPath) | Out-Null
    Copy-Item -Force $selectedAsset.AssemblyPath $selectedAsset.StagedAssemblyPath
    Copy-Item -Force $selectedAsset.DocumentationPath $selectedAsset.StagedDocumentationPath
}
Assert-FrameworkStaging $selectedAssets

$stagingXmlPath = Join-Path $stagingPath 'xml'
New-Item -ItemType Directory -Force -Path $stagingXmlPath | Out-Null
Copy-Item -Force (Join-Path $OutputRoot 'xml/_filter.xml') $stagingXmlPath
Copy-Item -Force (Join-Path $OutputRoot '_filter.xml') $stagingPath

# mdoc discovers only DLLs immediately under each Framework Source directory.
# Generate that configuration directly from the declared assets.
$frameworksPath = Write-MdocFrameworkConfiguration $frameworksRoot $selectedAssets
$libraryArguments = @()
foreach ($path in @($frameworkDirectories | Sort-Object -Unique) + @(Get-ReferencePaths @($dependencyExtractionPath)) | Select-Object -Unique) {
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
    $canonicalAsset = @($selectedAssets | Where-Object {
        $_.PackageId -eq $canonicalization.PackageId -and $_.Asset -eq $canonicalization.Asset
    })
    if ($canonicalAsset.Count -ne 1) {
        throw "Canonical type '$($canonicalization.CanonicalType)' does not have its required package DLL/XML input."
    }

    # mdoc conflates this explicitly obsolete type with its case-distinct
    # replacement in framework mode. Regenerate only its structure in the
    # complete framework set; compiler XML is imported by the exact sidecar below.
    & (Join-Path $PSScriptRoot 'MDoc.ps1') update --delete --fno-assembly-versions --fignore-missing-types `
        --lang DocId "--type=$($canonicalization.CanonicalType)" --frameworks $frameworksPath --out $stagingPath @libraryArguments
    if ($LASTEXITCODE -ne 0) {
        throw "mdoc canonical-type generation for '$($canonicalization.CanonicalType)' failed with exit code $LASTEXITCODE."
    }
}
$canonicalizations | ConvertTo-Json | Set-Content -NoNewline -Path (Join-Path $conversionRoot 'mdoc-canonicalizations.json')

# The exact compiler XML importer owns an explicit, deterministic sidecar.
# Do not source prose imports from mdoc's framework configuration.
$compilerDocumentation = @(
    for ($index = 0; $index -lt $selectedAssets.Count; $index++) {
        $source = $selectedAssets[$index]
        [PSCustomObject]@{
            Order = $index
            Path = $source.StagedDocumentationPath
            PackageId = $source.PackageId
            Asset = $source.Asset
        }
    }
)
$compilerDocumentationPath = Join-Path $conversionRoot 'compiler-xml-inputs.json'
$compilerXmlSidecar = [ordered]@{
    schemaVersion = 1
    inputs = $compilerDocumentation
    precedence = @(Get-CompilerXmlSidecarPrecedence $compilerDocumentation $manifest.documentationPrecedence)
}
$compilerXmlSidecar | ConvertTo-Json -Depth 32 | Set-Content -NoNewline -Path $compilerDocumentationPath
$compilerXmlSidecar = Get-Content -Raw -LiteralPath $compilerDocumentationPath | ConvertFrom-Json -Depth 32
$compilerDocumentation = @($compilerXmlSidecar.inputs)
$missingCompilerDocumentation = @($compilerDocumentation | Where-Object { -not (Test-Path $_.Path) })
if ($missingCompilerDocumentation) {
    throw "The mdoc framework configuration references missing compiler XML:`n$($missingCompilerDocumentation -join [Environment]::NewLine)"
}
$importedDocIds = @(Import-CompilerXmlDocumentation $stagingPath $compilerDocumentation @($compilerXmlSidecar.precedence))
$importedDocIds | ConvertTo-Json | Set-Content -NoNewline -Path (Join-Path $conversionRoot 'compiler-xml-imports.json')
$stagedAssemblies = Get-ChildItem -Path $frameworkDirectories -Filter '*.dll' -File -Recurse
$filteredDocIds = @(Remove-UndocumentedJavaPeerInfrastructureMembers $stagingPath $stagedAssemblies.FullName $importedDocIds)
$filteredDocIds | ConvertTo-Json | Set-Content -NoNewline -Path (Join-Path $conversionRoot 'filtered-java-peer-infrastructure-members.json')
Convert-MdocFrameworkAvailabilityToPublicMonikers $stagingPath $selectedAssets
Merge-MdocFrameworkIndexes $stagingPath $selectedAssets

Remove-WhitespaceOnlyLines $stagingPath
Assert-GeneratedDocumentation $stagingPath $selectedAssets
[void](Assert-ApiDocsCompleteness `
    -OutputRoot $stagingPath `
    -DocumentationPaths $compilerDocumentation `
    -AssemblyPaths $stagedAssemblies.FullName `
    -SelectedAssets $selectedAssets `
    -ImportedDocIds $importedDocIds `
    -FilteredDocIds $filteredDocIds `
    -Canonicalizations $canonicalizations `
    -ReportPath $CompletenessReportPath)

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

Promote-GeneratedApiDocs $OutputRoot $stagingPath

Write-Host "Atomically replaced generated ECMA XML and media in $OutputRoot from declared package assets."
