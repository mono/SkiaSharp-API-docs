<#
.SYNOPSIS
Generates ECMA API XML from the prepared package workspace.

.DESCRIPTION
Selects reference-first package assets and uses isolated mdoc framework sources
for Views platform variants. The variant sources are folded back into the
existing public Views moniker after mdoc has performed the structural union.
mdoc restores itself to artifacts/downloads when needed.

.EXAMPLE
./eng/Generate-ApiDocs.ps1

Generates SkiaSharpAPI from artifacts/workspace.
#>
[CmdletBinding()]
param(
    [switch] $MDocDebug,
    [string] $WorkspaceRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts/workspace'),
    [string] $OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'SkiaSharpAPI')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'MDoc.ps1')
$ProductRoot = Join-Path $WorkspaceRoot 'products'
$DependencyRoot = Join-Path $WorkspaceRoot 'dependencies'
$MediaRoot = Join-Path (Split-Path -Parent $WorkspaceRoot) 'downloads/transport/media'

function Get-FrameworkRank([string] $framework) {
    if ($framework -eq 'net10.0') { return 0 }
    if ($framework -like 'net10.0-*') { return 1 }
    if ($framework -eq 'netstandard2.0') { return 2 }
    if ($framework -eq 'netstandard2.1') { return 3 }
    if ($framework -eq 'net9.0') { return 4 }
    if ($framework -like 'net9.0-*') { return 5 }
    if ($framework -eq 'net6.0') { return 6 }
    return 10
}

function Get-Moniker([string] $packageId) {
    if ($packageId -like 'SkiaSharp.Views.Maui*') { return 'skiasharp-views-maui' }
    if ($packageId -like 'SkiaSharp.Views*') { return 'skiasharp-views' }
    if ($packageId -like 'SkiaSharp.Direct3D*') { return 'skiasharp-direct3d' }
    if ($packageId -like 'SkiaSharp.Vulkan*') { return 'skiasharp-vulkan' }
    return $packageId.ToLowerInvariant().Replace('.', '-')
}

function Get-AndroidDesignerResourceTypes([string] $root) {
    $types = [Collections.Generic.List[string]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.xml' -File -Recurse) {
        if ($file.Directory.Name -eq 'FrameworksIndex') {
            continue
        }
        $document = [Xml.XmlDocument]::new()
        $document.Load($file.FullName)
        $baseType = $document.SelectSingleNode('/Type/Base/BaseTypeName')
        if ($null -eq $baseType -or $baseType.InnerText -ne '_Microsoft.Android.Resource.Designer.Resource') {
            continue
        }
        [void]$types.Add($document.DocumentElement.GetAttribute('FullName'))
    }
    return @($types)
}

function Remove-GeneratedTypes([string] $root, [string[]] $typeNames) {
    $typeNameSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($typeName in $typeNames) {
        [void]$typeNameSet.Add($typeName)
    }
    $removedTypes = [Collections.Generic.List[string]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.xml' -File -Recurse) {
        if ($file.Directory.Name -eq 'FrameworksIndex') {
            continue
        }
        $document = [Xml.XmlDocument]::new()
        $document.PreserveWhitespace = $true
        $document.Load($file.FullName)
        if ($document.DocumentElement.LocalName -eq 'Overview') {
            $changed = $false
            foreach ($typeName in $typeNameSet) {
                $lastDot = $typeName.LastIndexOf('.')
                $namespaceName = $typeName.Substring(0, $lastDot)
                $shortName = $typeName.Substring($lastDot + 1)
                foreach ($node in @($document.SelectNodes("/Overview/Types/Namespace[@Name='$namespaceName']/Type[@Name='$shortName']"))) {
                    [void]$node.ParentNode.RemoveChild($node)
                    $changed = $true
                }
            }
            if ($changed) {
                $document.Save($file.FullName)
            }
            continue
        }
        $typeName = $document.DocumentElement.GetAttribute('FullName')
        if ($typeNameSet.Contains($typeName)) {
            Remove-Item -LiteralPath $file.FullName -Force
            [void]$removedTypes.Add($typeName)
        }
    }
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'FrameworksIndex') -Filter '*.xml' -File) {
        $document = [Xml.XmlDocument]::new()
        $document.PreserveWhitespace = $true
        $document.Load($file.FullName)
        $changed = $false
        foreach ($typeName in $typeNameSet) {
            foreach ($node in @($document.SelectNodes("//Type[@Id='T:$typeName']"))) {
                [void]$node.ParentNode.RemoveChild($node)
                $changed = $true
            }
        }
        if ($changed) {
            $document.Save($file.FullName)
        }
    }
    return $removedTypes.ToArray()
}

function Test-CompilerProse([object[]] $Variants) {
    foreach ($group in @($Variants | Group-Object Group)) {
        foreach ($pair in @($group.Group | ForEach-Object { $_ })) {
            foreach ($other in @($group.Group | Where-Object { $_.Key -gt $pair.Key })) {
                [xml]$left = Get-Content -LiteralPath $pair.Asset.Documentation -Raw
                [xml]$right = Get-Content -LiteralPath $other.Asset.Documentation -Raw
                $leftDocs = @{}
                foreach ($node in @($left.SelectNodes('/doc/members/member'))) {
                    $prose = ($node.InnerText -replace '\s+', ' ').Trim()
                    if ($prose) { $leftDocs[$node.GetAttribute('name')] = ($node.InnerXml -replace '\s+', ' ').Trim() }
                }
                foreach ($node in @($right.SelectNodes('/doc/members/member'))) {
                    $prose = ($node.InnerText -replace '\s+', ' ').Trim()
                    $id = $node.GetAttribute('name')
                    if ($prose -and $leftDocs.ContainsKey($id) -and $leftDocs[$id] -ne (($node.InnerXml -replace '\s+', ' ').Trim())) {
                        throw "Compiler XML prose conflict for '$id' between $($pair.Label) and $($other.Label)."
                    }
                }
            }
        }
    }
}

function New-FrameworksFile([string] $Path, [object[]] $Sources) {
    $document = [Xml.XmlDocument]::new()
    [void]$document.AppendChild($document.CreateXmlDeclaration('1.0', 'utf-8', $null))
    $frameworks = $document.CreateElement('Frameworks')
    [void]$document.AppendChild($frameworks)
    foreach ($source in @($Sources | Sort-Object SourceKey)) {
        $framework = $document.CreateElement('Framework')
        $framework.SetAttribute('Name', $source.SourceKey)
        $framework.SetAttribute('Source', $source.SourceKey)
        foreach ($searchPath in @($source.SearchPaths | Sort-Object -Unique)) {
            $node = $document.CreateElement('assemblySearchPath')
            $node.InnerText = $searchPath
            [void]$framework.AppendChild($node)
        }
        foreach ($import in @($source.Imports | Sort-Object -Unique)) {
            $node = $document.CreateElement('import')
            $node.InnerText = $import
            [void]$framework.AppendChild($node)
        }
        [void]$frameworks.AppendChild($framework)
    }
    $document.Save($Path)
}

# This table is the only place where public API variants are selected.
$variantSpecs = @(
    [PSCustomObject]@{ Group = 'gtk'; Key = 'views-gtk3'; Label = 'SkiaSharp.Views.Gtk3 package'; ShortLabel = 'GTK 3'; PackageId = 'SkiaSharp.Views.Gtk3'; AssemblyName = 'SkiaSharp.Views.Gtk3.dll'; FrameworkPattern = '.*'; Canonical = $false }
    [PSCustomObject]@{ Group = 'gtk'; Key = 'views-gtk4'; Label = 'SkiaSharp.Views.Gtk4 package'; ShortLabel = 'GTK 4'; PackageId = 'SkiaSharp.Views.Gtk4'; AssemblyName = 'SkiaSharp.Views.Gtk4.dll'; FrameworkPattern = '.*'; Canonical = $true }
    [PSCustomObject]@{ Group = 'apple'; Key = 'views-ios'; Label = 'iOS target-framework assembly'; ShortLabel = 'iOS'; PackageId = 'SkiaSharp.Views'; AssemblyName = 'SkiaSharp.Views.iOS.dll'; FrameworkPattern = '.*-ios.*'; Canonical = $true }
    [PSCustomObject]@{ Group = 'apple'; Key = 'views-maccatalyst'; Label = 'Mac Catalyst target-framework assembly'; ShortLabel = 'Mac Catalyst'; PackageId = 'SkiaSharp.Views'; AssemblyName = 'SkiaSharp.Views.iOS.dll'; FrameworkPattern = '.*-maccatalyst.*'; Canonical = $false }
)

$assets = foreach ($assembly in @(Get-ChildItem -LiteralPath $ProductRoot -Filter '*.dll' -File -Recurse)) {
    $relativePath = $assembly.FullName.Substring($ProductRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
    if ($relativePath -notmatch '[\\/](ref|lib)[\\/]([^\\/]+)[\\/]') { continue }
    $packageId = $relativePath.Split([IO.Path]::DirectorySeparatorChar)[0]
    if ($packageId -eq 'SkiaSharp.Views.Uno.WinUI') { continue }
    $documentation = [IO.Path]::ChangeExtension($assembly.FullName, '.xml')
    if (-not (Test-Path -LiteralPath $documentation)) { throw "Missing adjacent compiler XML for '$relativePath'." }
    [PSCustomObject]@{ PackageId = $packageId; Assembly = $assembly; Documentation = $documentation; Role = $Matches[1]; Framework = $Matches[2] }
}

$variants = foreach ($spec in $variantSpecs) {
    $candidates = @($assets | Where-Object {
        $_.PackageId -eq $spec.PackageId -and $_.Assembly.Name -eq $spec.AssemblyName -and $_.Framework -match $spec.FrameworkPattern
    } | Sort-Object @{ Expression = { if ($_.Role -eq 'ref') { 0 } else { 1 } } }, @{ Expression = { Get-FrameworkRank $_.Framework } }, Framework)
    if ($candidates.Count -eq 0) { throw "No asset matched variant '$($spec.Key)'." }
    $spec | Add-Member -NotePropertyName Asset -NotePropertyValue $candidates[0] -PassThru
}
Test-CompilerProse $variants

$variantPackageAssemblies = @{}
foreach ($variant in $variants) { $variantPackageAssemblies["$($variant.PackageId)|$($variant.AssemblyName)"] = $true }
$ordinaryAssets = @($assets | Where-Object { -not $variantPackageAssemblies.ContainsKey("$($_.PackageId)|$($_.Assembly.Name)") })
$selectedAssets = @($ordinaryAssets | Group-Object { "$($_.PackageId)|$($_.Assembly.Name)" } | ForEach-Object {
    $_.Group | Sort-Object @{ Expression = { if ($_.Role -eq 'ref') { 0 } else { 1 } } }, @{ Expression = { Get-FrameworkRank $_.Framework } }, Framework | Select-Object -First 1
} | Sort-Object PackageId, @{ Expression = { $_.Assembly.Name } })
if (($selectedAssets.Count + $variants.Count) -eq 0) { throw "No documentable product assets were found under '$ProductRoot'." }

$frameworksRoot = Join-Path $WorkspaceRoot 'frameworks'
Remove-Item -Recurse -Force $frameworksRoot -ErrorAction Ignore
New-Item -ItemType Directory -Force $frameworksRoot | Out-Null
$sources = [Collections.Generic.List[object]]::new()
foreach ($asset in $selectedAssets) {
    $key = Get-Moniker $asset.PackageId
    $directory = Join-Path $frameworksRoot $key
    New-Item -ItemType Directory -Force $directory | Out-Null
    $stagedAssembly = Join-Path $directory $asset.Assembly.Name
    if (Test-Path -LiteralPath $stagedAssembly) { throw "Multiple selected assets map to '$stagedAssembly'." }
    $stagedDocumentation = Join-Path $directory ([IO.Path]::GetFileName($asset.Documentation))
    Copy-Item $asset.Assembly.FullName $stagedAssembly
    Copy-Item $asset.Documentation $stagedDocumentation
    $sources.Add([PSCustomObject]@{ SourceKey = $key; SearchPaths = @($DependencyRoot, $directory); Imports = @($stagedDocumentation) })
}
foreach ($variant in $variants) {
    $directory = Join-Path $frameworksRoot $variant.Key
    New-Item -ItemType Directory -Force $directory | Out-Null
    $stagedAssembly = Join-Path $directory $variant.Asset.Assembly.Name
    $stagedDocumentation = Join-Path $directory ([IO.Path]::GetFileName($variant.Asset.Documentation))
    Copy-Item $variant.Asset.Assembly.FullName $stagedAssembly
    Copy-Item $variant.Asset.Documentation $stagedDocumentation
    $sources.Add([PSCustomObject]@{ SourceKey = $variant.Key; SearchPaths = @($DependencyRoot, $directory); Imports = @($stagedDocumentation) })
}

$frameworksPath = Join-Path $frameworksRoot 'frameworks.xml'
$frameworkSources = foreach ($sourceGroup in @($sources | Group-Object SourceKey)) {
    [PSCustomObject]@{
        SourceKey = $sourceGroup.Name
        SearchPaths = @($sourceGroup.Group | ForEach-Object { $_.SearchPaths } | Sort-Object -Unique)
        Imports = @($sourceGroup.Group | ForEach-Object { $_.Imports } | Sort-Object -Unique)
    }
}
New-FrameworksFile -Path $frameworksPath -Sources @($frameworkSources)
$stagingRoot = Join-Path $WorkspaceRoot 'staging'
Remove-Item -Recurse -Force $stagingRoot -ErrorAction Ignore
New-Item -ItemType Directory -Force $stagingRoot | Out-Null
$libraryArguments = @('--lib', $DependencyRoot)
foreach ($directory in @(Get-ChildItem -LiteralPath $frameworksRoot -Directory | Sort-Object Name)) {
    $libraryArguments += @('--lib', $directory.FullName)
}
$arguments = @('update', '--delete', '--lang=DocId', '--out', $stagingRoot, '--frameworks', $frameworksPath) + $libraryArguments
if ($MDocDebug) { $arguments += '--debug' }
Push-Location $frameworksRoot
try { Invoke-MDoc -Arguments $arguments }
finally { Pop-Location }

$excludedTypes = @('SkiaSharp.GrVkYcbcrConversionInfo') + @(Get-AndroidDesignerResourceTypes $stagingRoot)
$removedTypes = @(Remove-GeneratedTypes $stagingRoot ($excludedTypes | Sort-Object -Unique))
Write-Host "Removed $($removedTypes.Count) excluded generated type(s)."

& (Join-Path $PSScriptRoot 'Merge-ApiDocVariants.ps1') -StagingRoot $stagingRoot -Variants $variants

$preservedItems = @('docfx.json', '_filter.xml', 'SkiaSharpAPI-breadcrumb', 'xml')
New-Item -ItemType Directory -Force $OutputRoot | Out-Null
Get-ChildItem -LiteralPath $OutputRoot -Force | Where-Object { $_.Name -notin $preservedItems } | Remove-Item -Recurse -Force
Get-ChildItem -LiteralPath $stagingRoot -Force | Where-Object { $_.Name -notin $preservedItems } | Copy-Item -Destination $OutputRoot -Recurse -Force
if (@(Get-ChildItem -LiteralPath $MediaRoot -File).Count -gt 0) {
    $outputImages = Join-Path $OutputRoot 'images'
    Remove-Item -Recurse -Force $outputImages -ErrorAction Ignore
    Copy-Item -LiteralPath $MediaRoot -Destination $outputImages -Recurse -Force
}
Write-Host "Generated API documentation from $($selectedAssets.Count + $variants.Count) selected assemblies."
