<#
.SYNOPSIS
Generates ECMA API XML from the prepared package workspace.

.DESCRIPTION
Selects one reference-first assembly asset for each product package, runs mdoc
with its adjacent compiler XML, and replaces generated output while preserving
OpenPublishing infrastructure. mdoc restores itself to artifacts/downloads
when needed.

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

function Remove-AssemblyInformationalVersionMetadata([string] $root) {
    # Strip volatile SourceLink build metadata from generated AttributeName nodes below $root.
    foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.xml' -File -Recurse) {
        if (-not (Select-String -LiteralPath $file.FullName -SimpleMatch -Quiet 'AssemblyInformationalVersion')) {
            continue
        }
        $document = [Xml.XmlDocument]::new()
        $document.PreserveWhitespace = $true
        $document.Load($file.FullName)
        $changed = $false
        foreach ($node in @($document.SelectNodes('//AttributeName'))) {
            $normalized = $node.InnerText -replace '^(System\.Reflection\.AssemblyInformationalVersion\(")([^"+]+)\+[^"]+("\))$', '$1$2$3'
            if ($normalized -ne $node.InnerText) {
                $node.InnerText = $normalized
                $changed = $true
            }
        }
        if ($changed) {
            $document.Save($file.FullName)
        }
    }
}

# Find managed product assemblies and require the compiler XML beside every one.
$assets = foreach ($assembly in @(Get-ChildItem -LiteralPath $ProductRoot -Filter '*.dll' -File -Recurse)) {
    $relativePath = $assembly.FullName.Substring($ProductRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
    if ($relativePath -notmatch '[\\/](ref|lib)[\\/]([^\\/]+)[\\/]') {
        continue
    }
    $packageId = $relativePath.Split([IO.Path]::DirectorySeparatorChar)[0]
    if ($packageId -eq 'SkiaSharp.Views.Uno.WinUI') {
        continue
    }
    $documentation = [IO.Path]::ChangeExtension($assembly.FullName, '.xml')
    if (-not (Test-Path -LiteralPath $documentation)) {
        throw "Missing adjacent compiler XML for '$relativePath'."
    }
    [PSCustomObject]@{
        PackageId = $packageId
        Assembly = $assembly
        Documentation = $documentation
        Role = $Matches[1]
        Framework = $Matches[2]
    }
}

# Keep one ref-first asset for each package and assembly name.
$selectedAssets = @($assets | Group-Object { "$($_.PackageId)|$($_.Assembly.Name)" } | ForEach-Object {
    $_.Group | Sort-Object @{ Expression = { if ($_.Role -eq 'ref') { 0 } else { 1 } } },
        @{ Expression = { Get-FrameworkRank $_.Framework } }, Framework | Select-Object -First 1
} | Sort-Object PackageId, @{ Expression = { $_.Assembly.Name } })
if ($selectedAssets.Count -eq 0) {
    throw "No documentable product assets were found under '$ProductRoot'."
}

# Stage each assembly under its public Learn moniker for mdoc framework mode.
$frameworksRoot = Join-Path $WorkspaceRoot 'frameworks'
Remove-Item -Recurse -Force $frameworksRoot -ErrorAction Ignore
New-Item -ItemType Directory -Force $frameworksRoot | Out-Null
$stagedAssets = foreach ($asset in $selectedAssets) {
    $moniker = Get-Moniker $asset.PackageId
    $frameworkDirectory = Join-Path $frameworksRoot $moniker
    New-Item -ItemType Directory -Force $frameworkDirectory | Out-Null
    $stagedAssembly = Join-Path $frameworkDirectory $asset.Assembly.Name
    if (Test-Path -LiteralPath $stagedAssembly) {
        throw "Multiple selected assets map to '$stagedAssembly'."
    }
    $stagedDocumentation = Join-Path $frameworkDirectory ([IO.Path]::GetFileName($asset.Documentation))
    Copy-Item -LiteralPath $asset.Assembly.FullName -Destination $stagedAssembly
    Copy-Item -LiteralPath $asset.Documentation -Destination $stagedDocumentation
    [PSCustomObject]@{
        PackageId = $asset.PackageId
        Moniker = $moniker
        Assembly = $asset.Assembly
        Documentation = $stagedDocumentation
        StagedAssembly = $stagedAssembly
    }
}

# Describe the staged public monikers so mdoc emits FrameworksIndex metadata.
$frameworksPath = Join-Path $frameworksRoot 'frameworks.xml'
$frameworksDocument = [Xml.XmlDocument]::new()
[void]$frameworksDocument.AppendChild($frameworksDocument.CreateXmlDeclaration('1.0', 'utf-8', $null))
$frameworksElement = $frameworksDocument.CreateElement('Frameworks')
[void]$frameworksDocument.AppendChild($frameworksElement)
foreach ($moniker in $stagedAssets.Moniker | Sort-Object -Unique) {
    $frameworkElement = $frameworksDocument.CreateElement('Framework')
    $frameworkElement.SetAttribute('Name', $moniker)
    $frameworkElement.SetAttribute('Source', $moniker)
    [void]$frameworksElement.AppendChild($frameworkElement)
}
$frameworksDocument.Save($frameworksPath)

# Generate ECMA structure into a disposable staging directory.
$stagingRoot = Join-Path $WorkspaceRoot 'staging'
Remove-Item -Recurse -Force $stagingRoot -ErrorAction Ignore
New-Item -ItemType Directory -Force $stagingRoot | Out-Null

$libraryArguments = @('--lib', $DependencyRoot)
foreach ($frameworkDirectory in Get-ChildItem -LiteralPath $frameworksRoot -Directory | Sort-Object Name) {
    $libraryArguments += @('--lib', $frameworkDirectory.FullName)
}
$compilerXmlArguments = foreach ($asset in $stagedAssets) {
    @('--import', $asset.Documentation)
}
$arguments = @('update', '--delete', '--lang=DocId', '--out', $stagingRoot, '--frameworks', $frameworksPath) +
    $libraryArguments + $compilerXmlArguments
if ($MDocDebug) {
    $arguments += '--debug'
}
Push-Location $frameworksRoot
try {
    Invoke-MDoc -Arguments $arguments
}
finally {
    Pop-Location
}

# Exclude generated resource scaffolding and the lowercase YCbCr compatibility type from published API output.
$excludedTypes = @('SkiaSharp.GrVkYcbcrConversionInfo') + @(Get-AndroidDesignerResourceTypes $stagingRoot)
$removedTypes = @(Remove-GeneratedTypes $stagingRoot ($excludedTypes | Sort-Object -Unique))
Write-Host "Removed $($removedTypes.Count) excluded generated type(s)."
Remove-AssemblyInformationalVersionMetadata $stagingRoot

# Replace generated API output while preserving only non-ECMA publishing infrastructure.
$preservedItems = @('docfx.json', '_filter.xml', 'SkiaSharpAPI-breadcrumb', 'xml')
Get-ChildItem -LiteralPath $OutputRoot -Force | Where-Object { $_.Name -notin $preservedItems } | Remove-Item -Recurse -Force
Get-ChildItem -LiteralPath $stagingRoot -Force | Where-Object { $_.Name -notin $preservedItems } | Copy-Item -Destination $OutputRoot -Recurse -Force

# Replace the published image set from Fetch's clean media directory.
if (@(Get-ChildItem -LiteralPath $MediaRoot -File).Count -gt 0) {
    $outputImages = Join-Path $OutputRoot 'images'
    Remove-Item -Recurse -Force $outputImages -ErrorAction Ignore
    Copy-Item -LiteralPath $MediaRoot -Destination $outputImages -Recurse -Force
}

Write-Host "Generated API documentation from $($stagedAssets.Count) selected assemblies."
