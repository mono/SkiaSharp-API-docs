Set-StrictMode -Version Latest

# Converts the legacy constructor and nested-type forms emitted by mdoc exports
# into the standard DocId identities used by compiler XML and OpenPublishing.
function Convert-MdocImportDocId([string] $DocId) {
    if ([string]::IsNullOrEmpty($DocId)) {
        return $DocId
    }

    $normalized = $DocId -replace '^C:([^(]+)(\(.*\))?$', 'M:$1.#ctor$2'
    return $normalized.Replace('+', '.')
}

# Normalizes DocId-valued XML attributes without changing prose or XML structure.
function Normalize-MdocImportDocumentation([string] $DocumentationPath) {
    [xml] $documentation = Get-Content -Raw -Path $DocumentationPath
    $changed = $false
    foreach ($element in $documentation.SelectNodes('//*[@name or @cref]')) {
        foreach ($attributeName in @('name', 'cref')) {
            $attribute = $element.Attributes[$attributeName]
            if ($null -eq $attribute) {
                continue
            }

            $normalized = Convert-MdocImportDocId $attribute.Value
            if ($normalized -ne $attribute.Value) {
                $attribute.Value = $normalized
                $changed = $true
            }
        }
    }
    if ($changed) {
        $documentation.Save($DocumentationPath)
    }

    return $changed
}

# A known mdoc case-insensitive collision. The legacy type is explicitly marked
# obsolete in the package API and mdoc can emit only one of the two identities.
function Get-MdocObsoleteTypeCanonicalizations {
    return @(
        [PSCustomObject]@{
            LegacyType = 'SkiaSharp.GrVkYcbcrConversionInfo'
            CanonicalType = 'SkiaSharp.GRVkYcbcrConversionInfo'
            RequiredObsoleteMessage = 'Use GRVkYcbcrConversionInfo instead.'
            Framework = 'skiasharp'
            Assembly = 'SkiaSharp.dll'
        }
    )
}

function Get-XmlDocIdValues([xml] $Document) {
    return @(
        $Document.SelectNodes('//*[@Value]') |
        Where-Object { $_.GetAttribute('Language') -eq 'DocId' } |
        ForEach-Object { $_.GetAttribute('Value') }
    )
}

function Test-ShouldExcludeExplicitInterfaceMember(
    [bool[]] $AccessorIsPublic,
    [bool] $HasPublicImplementation
) {
    return $AccessorIsPublic.Count -gt 0 -and
        -not ($AccessorIsPublic -contains $true) -and
        -not $HasPublicImplementation
}

function Test-ShouldExcludeGeneratedResourceConstructor(
    [string] $BaseTypeName
) {
    return $BaseTypeName -eq '_Microsoft.Android.Resource.Designer.Resource'
}

function Get-MetadataTypeFullName([Reflection.Metadata.MetadataReader] $Metadata, [Reflection.Metadata.TypeDefinitionHandle] $TypeHandle) {
    $type = $Metadata.GetTypeDefinition($TypeHandle)
    $name = $Metadata.GetString($type.Name)
    $declaringType = $type.GetDeclaringType()
    if ($declaringType.IsNil) {
        $namespace = $Metadata.GetString($type.Namespace)
        if ($namespace) {
            return "$namespace.$name"
        }
        return $name
    }

    return "$(Get-MetadataTypeFullName $Metadata $declaringType).$name"
}

# Returns DocIds for explicit-interface members whose implementation methods
# are all non-public in the shipped metadata.
function Get-NonPublicExplicitInterfaceMemberDocIds([string[]] $AssemblyPaths) {
    $accessorsByDocId = @{}
    foreach ($assemblyPath in $AssemblyPaths) {
        $stream = [IO.File]::OpenRead($assemblyPath)
        try {
            $peReader = [Reflection.PortableExecutable.PEReader]::new($stream)
            try {
                if (-not $peReader.HasMetadata) {
                    continue
                }
                $metadata = [Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($peReader)
                foreach ($typeHandle in $metadata.TypeDefinitions) {
                    $type = $metadata.GetTypeDefinition($typeHandle)
                    $typeName = Get-MetadataTypeFullName $metadata $typeHandle
                    foreach ($methodHandle in $type.GetMethods()) {
                        $method = $metadata.GetMethodDefinition($methodHandle)
                        $methodName = $metadata.GetString($method.Name)
                        $match = [regex]::Match($methodName, '^(?<interface>.+)\.(?<accessor>get_|set_|add_|remove_)(?<member>.+)$')
                        if (-not $match.Success) {
                            continue
                        }

                        $prefix = if ($match.Groups['accessor'].Value -in @('get_', 'set_')) { 'P' } else { 'E' }
                        $interfaceName = $match.Groups['interface'].Value.Replace('.', '#')
                        $docId = "${prefix}:$typeName.$interfaceName#$($match.Groups['member'].Value)"
                        if (-not $accessorsByDocId.ContainsKey($docId)) {
                            $accessorsByDocId[$docId] = @()
                        }
                        $accessorsByDocId[$docId] += $method.Attributes.HasFlag([Reflection.MethodAttributes]::Public)
                        $publicImplementationName = "$($match.Groups['accessor'].Value)$($match.Groups['member'].Value)"
                        $hasPublicImplementation = @(
                            $type.GetMethods() |
                            ForEach-Object { $metadata.GetMethodDefinition($_) } |
                            Where-Object {
                                $metadata.GetString($_.Name) -eq $publicImplementationName -and
                                $_.Attributes.HasFlag([Reflection.MethodAttributes]::Public)
                            }
                        ).Count -gt 0
                        if ($hasPublicImplementation) {
                            # Preserve the public API even if metadata also has
                            # a private explicit-interface forwarding accessor.
                            $accessorsByDocId[$docId] += $true
                        }
                    }
                }
            }
            finally {
                $peReader.Dispose()
            }
        }
        finally {
            $stream.Dispose()
        }
    }

    return @(
        $accessorsByDocId.GetEnumerator() |
        Where-Object { Test-ShouldExcludeExplicitInterfaceMember $_.Value $false } |
        ForEach-Object Key
    )
}

# Returns synthetic constructors emitted by mdoc for resource-designer types
# that have no public instance constructor in package metadata.
function Get-GeneratedResourceDesignerConstructorDocIds([string[]] $AssemblyPaths) {
    $docIds = @()
    foreach ($assemblyPath in $AssemblyPaths) {
        $stream = [IO.File]::OpenRead($assemblyPath)
        try {
            $peReader = [Reflection.PortableExecutable.PEReader]::new($stream)
            try {
                if (-not $peReader.HasMetadata) {
                    continue
                }
                $metadata = [Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($peReader)
                foreach ($typeHandle in $metadata.TypeDefinitions) {
                    $type = $metadata.GetTypeDefinition($typeHandle)
                    $baseType = $type.BaseType
                    if ($baseType.Kind -ne [Reflection.Metadata.HandleKind]::TypeReference) {
                        continue
                    }
                    $baseTypeReference = $metadata.GetTypeReference([Reflection.Metadata.TypeReferenceHandle]$baseType)
                    $baseTypeName = "$($metadata.GetString($baseTypeReference.Namespace)).$($metadata.GetString($baseTypeReference.Name))"
                    if (Test-ShouldExcludeGeneratedResourceConstructor $baseTypeName) {
                        $docIds += "M:$(Get-MetadataTypeFullName $metadata $typeHandle).#ctor"
                    }
                }
            }
            finally {
                $peReader.Dispose()
            }
        }
        finally {
            $stream.Dispose()
        }
    }
    return $docIds
}

# Removes only metadata-proven implementation details from disposable mdoc
# staging output. No existing documentation tree content is consulted.
function Remove-GeneratedMemberDocIds([string] $OutputRoot, [string[]] $DocIds) {
    $removed = @()
    foreach ($file in Get-ChildItem -Path $OutputRoot -Filter '*.xml' -File -Recurse) {
        [xml] $document = Get-Content -Raw -Path $file.FullName
        if ($document.DocumentElement.LocalName -ne 'Type') {
            continue
        }
        foreach ($member in $document.SelectNodes('/Type/Members/Member')) {
            $docId = $member.SelectSingleNode('./MemberSignature[@Language="DocId"]').GetAttribute('Value')
            $shouldRemove = $false
            foreach ($candidateDocId in $DocIds) {
                if ([string]::Equals($candidateDocId, $docId, [StringComparison]::Ordinal)) {
                    $shouldRemove = $true
                    break
                }
            }
            if ($shouldRemove) {
                [void]$member.ParentNode.RemoveChild($member)
                $removed += $docId
            }
        }
        $document.Save($file.FullName)
    }
    return $removed
}

# Removes only an explicitly verified obsolete mdoc collision before the
# caller regenerates the canonical type from the same package XML and DLL.
function Remove-MdocObsoleteTypeCollision(
    [string] $OutputRoot,
    [string] $LegacyType,
    [string] $CanonicalType,
    [string] $RequiredObsoleteMessage
) {
    $legacyFile = Join-Path $OutputRoot (($LegacyType -replace '\.', [IO.Path]::DirectorySeparatorChar) + '.xml')
    if (-not (Test-Path $legacyFile)) {
        throw "mdoc did not emit the expected obsolete type '$LegacyType'."
    }

    [xml] $typeDocument = Get-Content -Raw -Path $legacyFile
    $type = $typeDocument.DocumentElement
    if ($type.GetAttribute('Name') -ne ($LegacyType.Split('.')[-1]) -or
        $type.GetAttribute('FullName') -ne $LegacyType) {
        throw "The mdoc output '$legacyFile' does not represent '$LegacyType'."
    }
    $obsoleteAttribute = $type.SelectSingleNode('./Attributes/Attribute/AttributeName[contains(text(), "Obsolete")]')
    if ($null -eq $obsoleteAttribute -or $obsoleteAttribute.InnerText -notlike "*$RequiredObsoleteMessage*") {
        throw "The legacy type '$LegacyType' is not explicitly obsolete in favor of '$CanonicalType'."
    }

    Remove-Item -Force $legacyFile

    return [PSCustomObject]@{
        LegacyType = $LegacyType
        CanonicalType = $CanonicalType
        Reason = "Explicit obsolete replacement: $RequiredObsoleteMessage"
    }
}

Export-ModuleMember -Function `
    Convert-MdocImportDocId, `
    Normalize-MdocImportDocumentation, `
    Get-MdocObsoleteTypeCanonicalizations, `
    Get-XmlDocIdValues, `
    Test-ShouldExcludeExplicitInterfaceMember, `
    Test-ShouldExcludeGeneratedResourceConstructor, `
    Get-NonPublicExplicitInterfaceMemberDocIds, `
    Get-GeneratedResourceDesignerConstructorDocIds, `
    Remove-GeneratedMemberDocIds, `
    Remove-MdocObsoleteTypeCollision
