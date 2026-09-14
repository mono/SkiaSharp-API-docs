Set-StrictMode -Version Latest

# A known mdoc case-insensitive collision. The legacy type is explicitly marked
# obsolete in the package API and mdoc can emit only one of the two identities.
function Get-MdocObsoleteTypeCanonicalizations {
    return @(
        [PSCustomObject]@{
            LegacyType = 'SkiaSharp.GrVkYcbcrConversionInfo'
            CanonicalType = 'SkiaSharp.GRVkYcbcrConversionInfo'
            RequiredObsoleteMessage = 'Use GRVkYcbcrConversionInfo instead.'
            PackageId = 'SkiaSharp'
            Asset = 'ref/net10.0/SkiaSharp.dll'
        }
    )
}

function Remove-CompilerXmlMarkdownIndentation([System.Xml.XmlElement] $Member) {
    foreach ($format in $Member.SelectNodes('.//format[@type="text/markdown"]')) {
        foreach ($textNode in @($format.ChildNodes | Where-Object {
            $_.NodeType -in @([System.Xml.XmlNodeType]::Text, [System.Xml.XmlNodeType]::CDATA)
        })) {
            $indents = @(
                [regex]::Matches($textNode.Value, '(?m)^(?<indent>[ \t]+)\S') |
                ForEach-Object { $_.Groups['indent'].Value }
            )
            if ($indents.Count -eq 0) {
                continue
            }

            $commonIndent = $indents[0]
            if ($indents.Count -gt 1) {
                foreach ($indent in $indents[1..($indents.Count - 1)]) {
                    $length = [Math]::Min($commonIndent.Length, $indent.Length)
                    $index = 0
                    while ($index -lt $length -and $commonIndent[$index] -eq $indent[$index]) {
                        $index++
                    }
                    $commonIndent = $commonIndent.Substring(0, $index)
                    if ($commonIndent.Length -eq 0) {
                        break
                    }
                }
            }
            if ($commonIndent.Length -gt 0) {
                $textNode.Value = $textNode.Value -replace "(?m)^$([regex]::Escape($commonIndent))", ''
            }
        }
    }
}

function ConvertTo-CompilerXmlSemanticValue([System.Xml.XmlNode] $Node) {
    if ($Node.NodeType -in @([System.Xml.XmlNodeType]::Whitespace, [System.Xml.XmlNodeType]::SignificantWhitespace)) {
        return ''
    }
    if ($Node.NodeType -in @([System.Xml.XmlNodeType]::Text, [System.Xml.XmlNodeType]::CDATA)) {
        return "text:$($Node.Value)"
    }
    if ($Node.NodeType -ne [System.Xml.XmlNodeType]::Element) {
        return ''
    }

    $attributeValues = [Collections.Generic.List[string]]::new()
    foreach ($attribute in $Node.Attributes) {
        $attributeValues.Add(" $($attribute.NamespaceURI):$($attribute.LocalName)=$($attribute.Value)")
    }
    $attributeValues.Sort([StringComparer]::Ordinal)
    $childValues = [Collections.Generic.List[string]]::new()
    foreach ($child in $Node.ChildNodes) {
        $childValues.Add((ConvertTo-CompilerXmlSemanticValue $child))
    }
    $attributes = $attributeValues -join ''
    $children = $childValues -join ''
    return "<$($Node.NamespaceURI):$($Node.LocalName)$attributes>$children</$($Node.NamespaceURI):$($Node.LocalName)>"
}

function Get-CompilerXmlSidecarPrecedence(
    [object[]] $DocumentationPaths,
    [object[]] $ManifestPrecedence = @()
) {
    $precedenceByDocId = @{}
    foreach ($precedence in $ManifestPrecedence) {
        if ([string]::IsNullOrWhiteSpace($precedence.docId) -or
            [string]::IsNullOrWhiteSpace($precedence.packageId) -or
            [string]::IsNullOrWhiteSpace($precedence.asset) -or
            $precedenceByDocId.ContainsKey($precedence.docId)) {
            throw 'Documentation precedence entries must have one unique docId, packageId, and asset.'
        }
        $precedenceByDocId[$precedence.docId] = [PSCustomObject]@{
            docId = $precedence.docId
            packageId = $precedence.packageId
            asset = $precedence.asset
        }
    }

    $documentsByDocId = [Collections.Generic.Dictionary[string, System.Xml.XmlElement]]::new([StringComparer]::Ordinal)
    $sourcesByDocId = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($documentationSource in @($DocumentationPaths | Sort-Object Order)) {
        [xml] $compilerDocument = Get-Content -Raw -LiteralPath $documentationSource.Path
        if ($compilerDocument.DocumentElement.LocalName -ne 'doc') {
            continue
        }
        foreach ($member in $compilerDocument.SelectNodes('/doc/members/member')) {
            $docId = $member.GetAttribute('name')
            if ([string]::IsNullOrWhiteSpace($docId)) {
                throw "Compiler XML '$($documentationSource.Path)' contains a member without a DocId."
            }
            Remove-CompilerXmlMarkdownIndentation $member
            if (-not $documentsByDocId.ContainsKey($docId)) {
                $documentsByDocId[$docId] = $member
                $sourcesByDocId[$docId] = $documentationSource
                continue
            }
            if ((ConvertTo-CompilerXmlSemanticValue $documentsByDocId[$docId]) -cne
                (ConvertTo-CompilerXmlSemanticValue $member) -and
                -not $precedenceByDocId.ContainsKey($docId)) {
                $source = $sourcesByDocId[$docId]
                $precedenceByDocId[$docId] = [PSCustomObject]@{
                    docId = $docId
                    packageId = $source.PackageId
                    asset = $source.Asset
                }
            }
        }
    }
    return @($precedenceByDocId.Values | Sort-Object docId)
}

function Get-MetadataTypeFullName(
    [Reflection.Metadata.MetadataReader] $Metadata,
    [Reflection.Metadata.TypeDefinitionHandle] $TypeHandle
) {
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

function Test-ShouldExcludeUndocumentedJavaPeerInfrastructureMember(
    [bool] $IsPrivate,
    [string] $MethodName,
    [bool] $HasCompilerDocumentation
) {
    return $IsPrivate -and
        $MethodName.StartsWith('Java.Interop.IJavaPeerable.', [StringComparison]::Ordinal) -and
        -not $HasCompilerDocumentation
}

# mdoc exposes this Android infrastructure implementation as a public ECMA
# member even though its PE method is private. Other interface implementations
# are normal API-doc content and must remain in the generated tree.
function Remove-UndocumentedJavaPeerInfrastructureMembers(
    [string] $OutputRoot,
    [string[]] $AssemblyPaths,
    [string[]] $ImportedDocIds
) {
    $documented = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $ImportedDocIds | ForEach-Object { [void]$documented.Add($_) }
    $excluded = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

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
                        $isPrivate = ($method.Attributes -band [Reflection.MethodAttributes]::MemberAccessMask) -eq [Reflection.MethodAttributes]::Private
                        $docId = "M:$typeName.$($methodName.Replace('.', '#'))"
                        if (Test-ShouldExcludeUndocumentedJavaPeerInfrastructureMember $isPrivate $methodName $documented.Contains($docId)) {
                            [void]$excluded.Add($docId)
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

    $removed = @()
    foreach ($file in Get-ChildItem -Path $OutputRoot -Filter '*.xml' -File -Recurse) {
        [xml] $document = Get-Content -Raw -Path $file.FullName
        if ($document.DocumentElement.LocalName -ne 'Type') {
            continue
        }
        foreach ($member in @($document.SelectNodes('/Type/Members/Member'))) {
            $signature = $member.SelectSingleNode('./MemberSignature[@Language="DocId"]')
            if ($null -ne $signature -and $excluded.Contains($signature.GetAttribute('Value'))) {
                [void]$member.ParentNode.RemoveChild($member)
                $removed += $signature.GetAttribute('Value')
            }
        }
        $document.Save($file.FullName)
    }
    return $removed
}

# Imports package compiler XML into clean mdoc ECMA output by exact DocId.
# It has no fallback to repository XML and does not perform identity rewrites.
function Import-CompilerXmlDocumentation(
    [string] $OutputRoot,
    [object[]] $DocumentationPaths,
    [object[]] $DocumentationPrecedence = @()
) {
    $orderedDocumentationPaths = @($DocumentationPaths)
    $hasExplicitOrder = @($orderedDocumentationPaths | Where-Object {
        $null -ne $_ -and $_ -isnot [string] -and
        $null -ne $_.PSObject.Properties['Order']
    }).Count -gt 0
    if ($hasExplicitOrder) {
        if (@($orderedDocumentationPaths | Where-Object {
            $_ -is [string] -or $null -eq $_.PSObject.Properties['Order']
        }).Count -gt 0) {
            throw 'Compiler XML sidecar metadata must specify an order for every input.'
        }
        $orderedDocumentationPaths = @($orderedDocumentationPaths | Sort-Object Order)
        for ($index = 0; $index -lt $orderedDocumentationPaths.Count; $index++) {
            if ([Int64]$orderedDocumentationPaths[$index].Order -ne $index) {
                throw 'Compiler XML sidecar metadata must use consecutive zero-based order values.'
            }
        }
    }

    $compilerDocs = [Collections.Generic.Dictionary[string, System.Xml.XmlElement]]::new([StringComparer]::Ordinal)
    $compilerDocSources = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $precedenceByDocId = @{}
    foreach ($precedence in $DocumentationPrecedence) {
        if ([string]::IsNullOrWhiteSpace($precedence.docId) -or
            [string]::IsNullOrWhiteSpace($precedence.packageId) -or
            [string]::IsNullOrWhiteSpace($precedence.asset) -or
            $precedenceByDocId.ContainsKey($precedence.docId)) {
            throw 'Documentation precedence entries must have one unique docId, packageId, and asset.'
        }
        $precedenceByDocId[$precedence.docId] = $precedence
    }
    foreach ($documentationInput in $orderedDocumentationPaths) {
        $documentationSource = if ($documentationInput -is [string]) {
            [PSCustomObject]@{ Path = $documentationInput; PackageId = ''; Asset = '' }
        } else {
            $documentationInput
        }
        $documentationPath = $documentationSource.Path
        if ([string]::IsNullOrWhiteSpace($documentationPath)) {
            throw 'Compiler XML input has no path.'
        }
        [xml] $compilerDocument = Get-Content -Raw -Path $documentationPath
        if ($compilerDocument.DocumentElement.LocalName -ne 'doc') {
            continue
        }
        foreach ($member in $compilerDocument.SelectNodes('/doc/members/member')) {
            $docId = $member.GetAttribute('name')
            if ([string]::IsNullOrWhiteSpace($docId)) {
                throw "Compiler XML '$documentationPath' contains a member without a DocId."
            }
            Remove-CompilerXmlMarkdownIndentation $member
            if ($compilerDocs.ContainsKey($docId)) {
                $sameDocumentation = (ConvertTo-CompilerXmlSemanticValue $compilerDocs[$docId]) -ceq
                    (ConvertTo-CompilerXmlSemanticValue $member)
                if (-not $sameDocumentation) {
                    if (-not $precedenceByDocId.ContainsKey($docId)) {
                        throw "Compiler XML inputs have conflicting content for exact DocId '$docId'. Add explicit manifest precedence."
                    }
                    $precedence = $precedenceByDocId[$docId]
                    $isPreferred = $documentationSource.PackageId -ieq $precedence.packageId -and
                        $documentationSource.Asset -ceq $precedence.asset
                    $existingSource = $compilerDocSources[$docId]
                    $existingIsPreferred = $existingSource.PackageId -ieq $precedence.packageId -and
                        $existingSource.Asset -ceq $precedence.asset
                    if (-not $isPreferred -and -not $existingIsPreferred) {
                        throw "Documentation precedence for '$docId' does not identify either conflicting selected asset."
                    }
                    if ($isPreferred) {
                        $compilerDocs[$docId] = $member
                        $compilerDocSources[$docId] = $documentationSource
                    }
                }
                continue
            }
            $compilerDocs[$docId] = $member
            $compilerDocSources[$docId] = $documentationSource
        }
    }

    $imported = @()
    foreach ($file in Get-ChildItem -Path $OutputRoot -Filter '*.xml' -File -Recurse) {
        [xml] $ecmaDocument = Get-Content -Raw -Path $file.FullName
        if ($ecmaDocument.DocumentElement.LocalName -ne 'Type') {
            continue
        }
        foreach ($api in @($ecmaDocument.DocumentElement) + @($ecmaDocument.SelectNodes('/Type/Members/Member'))) {
            $signatureName = if ($api.LocalName -eq 'Type') { 'TypeSignature' } else { 'MemberSignature' }
            $signature = $api.SelectSingleNode("./$signatureName[@Language=""DocId""]")
            if ($null -eq $signature) {
                continue
            }
            $docId = $signature.GetAttribute('Value')
            if (-not $compilerDocs.ContainsKey($docId)) {
                continue
            }
            $docs = $api.SelectSingleNode('./Docs')
            if ($null -eq $docs) {
                $docs = $ecmaDocument.CreateElement('Docs')
                [void]$api.AppendChild($docs)
            }
            $docs.RemoveAll()
            $documentationElementOrder = @{
                'typeparam' = 0
                'param' = 1
                'summary' = 2
                'value' = 3
                'returns' = 4
                'remarks' = 5
                'exception' = 6
                'seealso' = 7
                'altmember' = 8
            }
            $nodes = @($compilerDocs[$docId].ChildNodes | Where-Object {
                $_.NodeType -eq [System.Xml.XmlNodeType]::Element
            })
            for ($index = 0; $index -lt $nodes.Count; $index++) {
                $nodes[$index] | Add-Member -NotePropertyName ImportOrder -NotePropertyValue $index
            }
            foreach ($node in $nodes | Sort-Object @{
                Expression = {
                    if ($documentationElementOrder.ContainsKey($_.LocalName)) {
                        $documentationElementOrder[$_.LocalName]
                    } else {
                        [int]::MaxValue
                    }
                }
            }, ImportOrder) {
                [void]$docs.AppendChild($ecmaDocument.ImportNode($node, $true))
            }
            $imported += $docId
        }
        $ecmaDocument.Save($file.FullName)
    }
    $uniqueImported = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $imported | ForEach-Object { [void]$uniqueImported.Add($_) }
    $result = @($uniqueImported)
    [Array]::Sort($result, [StringComparer]::Ordinal)
    return $result
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
    Get-MdocObsoleteTypeCanonicalizations, `
    Remove-CompilerXmlMarkdownIndentation, `
    ConvertTo-CompilerXmlSemanticValue, `
    Get-CompilerXmlSidecarPrecedence, `
    Test-ShouldExcludeUndocumentedJavaPeerInfrastructureMember, `
    Remove-UndocumentedJavaPeerInfrastructureMembers, `
    Import-CompilerXmlDocumentation, `
    Remove-MdocObsoleteTypeCollision
