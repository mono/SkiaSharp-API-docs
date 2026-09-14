Set-StrictMode -Version Latest

function Get-CompletenessMetadataTypeFullName(
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
    return "$(Get-CompletenessMetadataTypeFullName $Metadata $declaringType).$name"
}

function Test-SubstantiveEcmaDocs([System.Xml.XmlElement] $Docs) {
    if ($null -eq $Docs) {
        return $false
    }

    $text = [regex]::Replace($Docs.InnerText, '\s+', ' ').Trim()
    return -not [string]::IsNullOrWhiteSpace($text) -and
        $text -notmatch '(?i)\bto\s+be\s+added\b'
}

function Get-EcmaDocumentationEntries([string] $OutputRoot) {
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $OutputRoot -Filter '*.xml' -File -Recurse | Sort-Object FullName) {
        [xml] $document = Get-Content -Raw -LiteralPath $file.FullName
        if ($document.DocumentElement.LocalName -ne 'Type') {
            continue
        }

        foreach ($api in @($document.DocumentElement) + @($document.SelectNodes('/Type/Members/Member'))) {
            $signatureName = if ($api.LocalName -eq 'Type') { 'TypeSignature' } else { 'MemberSignature' }
            $signature = $api.SelectSingleNode("./$signatureName[@Language=""DocId""]")
            $docId = if ($null -eq $signature) { '' } else { $signature.GetAttribute('Value') }
            $docs = $api.SelectSingleNode('./Docs')
            $entries.Add([PSCustomObject]@{
                docId = $docId
                kind = if ($api.LocalName -eq 'Type') { 'type' } else { 'member' }
                path = $file.FullName
                substantiveDocs = Test-SubstantiveEcmaDocs $docs
            })
        }
    }
    return @($entries)
}

function Get-CompilerXmlDocumentationEntries([object[]] $DocumentationPaths) {
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($input in $DocumentationPaths) {
        $source = if ($input -is [string]) {
            [PSCustomObject]@{ Path = $input; PackageId = ''; Asset = '' }
        } else {
            $input
        }
        [xml] $document = Get-Content -Raw -LiteralPath $source.Path
        if ($document.DocumentElement.LocalName -ne 'doc') {
            continue
        }
        foreach ($member in $document.SelectNodes('/doc/members/member')) {
            $docId = $member.GetAttribute('name')
            if ([string]::IsNullOrWhiteSpace($docId)) {
                throw "Compiler XML '$($source.Path)' contains a member without a DocId."
            }
            $entries.Add([PSCustomObject]@{
                docId = $docId
                packageId = $source.PackageId
                asset = $source.Asset
                path = $source.Path
            })
        }
    }
    return @($entries)
}

function Test-ExternallyVisibleType(
    [Reflection.Metadata.MetadataReader] $Metadata,
    [Reflection.Metadata.TypeDefinitionHandle] $TypeHandle
) {
    $type = $Metadata.GetTypeDefinition($TypeHandle)
    $visibility = $type.Attributes -band [Reflection.TypeAttributes]::VisibilityMask
    $visible = $visibility -in @(
        [Reflection.TypeAttributes]::Public,
        [Reflection.TypeAttributes]::NestedPublic,
        [Reflection.TypeAttributes]::NestedFamily,
        [Reflection.TypeAttributes]::NestedFamORAssem
    )
    if (-not $visible) {
        return $false
    }

    $declaringType = $type.GetDeclaringType()
    return $declaringType.IsNil -or (Test-ExternallyVisibleType $Metadata $declaringType)
}

function Test-ExternallyVisibleMethod(
    [Reflection.Metadata.MetadataReader] $Metadata,
    [Reflection.Metadata.MethodDefinitionHandle] $MethodHandle
) {
    if ($MethodHandle.IsNil) {
        return $false
    }
    $access = ($Metadata.GetMethodDefinition($MethodHandle).Attributes -band [Reflection.MethodAttributes]::MemberAccessMask)
    return $access -in @(
        [Reflection.MethodAttributes]::Public,
        [Reflection.MethodAttributes]::Family,
        [Reflection.MethodAttributes]::FamORAssem
    )
}

function Get-SelectedAssemblyDocIdCandidates([string[]] $AssemblyPaths) {
    $candidates = [Collections.Generic.List[object]]::new()
    foreach ($assemblyPath in $AssemblyPaths | Sort-Object -Unique) {
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
                    $typeName = Get-CompletenessMetadataTypeFullName $metadata $typeHandle
                    $typeIsPublic = Test-ExternallyVisibleType $metadata $typeHandle
                    $candidates.Add([PSCustomObject]@{
                        prefix = "T:$typeName"
                        acceptsSuffix = $false
                        isPublic = $typeIsPublic
                        assembly = $assemblyPath
                    })

                    foreach ($methodHandle in $type.GetMethods()) {
                        $method = $metadata.GetMethodDefinition($methodHandle)
                        $methodName = $metadata.GetString($method.Name).Replace('.', '#')
                        $candidates.Add([PSCustomObject]@{
                            prefix = "M:$typeName.$methodName"
                            acceptsSuffix = $true
                            isPublic = $typeIsPublic -and (Test-ExternallyVisibleMethod $metadata $methodHandle)
                            assembly = $assemblyPath
                        })
                    }
                    foreach ($fieldHandle in $type.GetFields()) {
                        $field = $metadata.GetFieldDefinition($fieldHandle)
                        $access = $field.Attributes -band [Reflection.FieldAttributes]::FieldAccessMask
                        $candidates.Add([PSCustomObject]@{
                            prefix = "F:$typeName.$($metadata.GetString($field.Name).Replace('.', '#'))"
                            acceptsSuffix = $false
                            isPublic = $typeIsPublic -and $access -in @(
                                [Reflection.FieldAttributes]::Public,
                                [Reflection.FieldAttributes]::Family,
                                [Reflection.FieldAttributes]::FamORAssem
                            )
                            assembly = $assemblyPath
                        })
                    }
                    foreach ($propertyHandle in $type.GetProperties()) {
                        $property = $metadata.GetPropertyDefinition($propertyHandle)
                        $accessors = $property.GetAccessors()
                        $isPublic = @(
                            @($accessors.Getter, $accessors.Setter) + @($accessors.Others) |
                            Where-Object { Test-ExternallyVisibleMethod $metadata $_ }
                        ).Count -gt 0
                        $candidates.Add([PSCustomObject]@{
                            prefix = "P:$typeName.$($metadata.GetString($property.Name).Replace('.', '#'))"
                            acceptsSuffix = $true
                            isPublic = $typeIsPublic -and $isPublic
                            assembly = $assemblyPath
                        })
                    }
                    foreach ($eventHandle in $type.GetEvents()) {
                        $event = $metadata.GetEventDefinition($eventHandle)
                        $accessors = $event.GetAccessors()
                        $isPublic = @(
                            @($accessors.Adder, $accessors.Remover, $accessors.Raiser) + @($accessors.Others) |
                            Where-Object { Test-ExternallyVisibleMethod $metadata $_ }
                        ).Count -gt 0
                        $candidates.Add([PSCustomObject]@{
                            prefix = "E:$typeName.$($metadata.GetString($event.Name).Replace('.', '#'))"
                            acceptsSuffix = $false
                            isPublic = $typeIsPublic -and $isPublic
                            assembly = $assemblyPath
                        })
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
    return @($candidates)
}

function Get-DocIdMetadataCandidates([string] $DocId, [object[]] $Candidates) {
    return @($Candidates | Where-Object {
        if (-not $DocId.StartsWith($_.prefix, [StringComparison]::Ordinal)) {
            return $false
        }
        if (-not $_.acceptsSuffix) {
            return $DocId.Length -eq $_.prefix.Length
        }
        if ($DocId.Length -eq $_.prefix.Length) {
            return $true
        }
        return $DocId[$_.prefix.Length] -in @('(', '`', '~')
    })
}

function Test-CanonicalizedLegacyDocId([string] $DocId, [object[]] $Canonicalizations) {
    foreach ($canonicalization in $Canonicalizations) {
        $legacy = $canonicalization.LegacyType
        if ($DocId -eq "T:$legacy" -or
            $DocId.StartsWith("M:$legacy.", [StringComparison]::Ordinal) -or
            $DocId.StartsWith("P:$legacy.", [StringComparison]::Ordinal) -or
            $DocId.StartsWith("F:$legacy.", [StringComparison]::Ordinal) -or
            $DocId.StartsWith("E:$legacy.", [StringComparison]::Ordinal)) {
            return $true
        }
    }
    return $false
}

function Write-ApiDocsCompletenessReport([string] $ReportPath, [object] $Report) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ReportPath) | Out-Null
    $Report | ConvertTo-Json -Depth 32 | Set-Content -NoNewline -LiteralPath $ReportPath
}

function Assert-ApiDocsCompleteness(
    [string] $OutputRoot,
    [object[]] $DocumentationPaths,
    [string[]] $AssemblyPaths,
    [object[]] $SelectedAssets,
    [string[]] $ImportedDocIds,
    [string[]] $FilteredDocIds,
    [object[]] $Canonicalizations,
    [string] $ReportPath
) {
    $ecmaEntries = @(Get-EcmaDocumentationEntries $OutputRoot)
    $compilerEntries = @(Get-CompilerXmlDocumentationEntries $DocumentationPaths)
    $metadataCandidates = @(Get-SelectedAssemblyDocIdCandidates $AssemblyPaths)
    $ecmaByDocId = @{}
    $invalidEcma = [Collections.Generic.List[object]]::new()
    foreach ($entry in $ecmaEntries) {
        if ([string]::IsNullOrWhiteSpace($entry.docId)) {
            $invalidEcma.Add([PSCustomObject]@{ path = $entry.path; kind = $entry.kind; reason = 'missing-doc-id' })
        } elseif ($ecmaByDocId.ContainsKey($entry.docId)) {
            $invalidEcma.Add([PSCustomObject]@{ docId = $entry.docId; path = $entry.path; kind = $entry.kind; reason = 'duplicate-doc-id' })
        } else {
            $ecmaByDocId[$entry.docId] = $entry
        }
        if (-not $entry.substantiveDocs) {
            $invalidEcma.Add([PSCustomObject]@{ docId = $entry.docId; path = $entry.path; kind = $entry.kind; reason = 'missing-or-placeholder-docs' })
        }
    }

    $imported = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $ImportedDocIds | ForEach-Object { [void]$imported.Add($_) }
    $filtered = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $FilteredDocIds | ForEach-Object { [void]$filtered.Add($_) }
    $compilerByDocId = @{}
    foreach ($entry in $compilerEntries) {
        if (-not $compilerByDocId.ContainsKey($entry.docId)) {
            $compilerByDocId[$entry.docId] = [Collections.Generic.List[object]]::new()
        }
        $compilerByDocId[$entry.docId].Add($entry)
    }

    $absentCompilerDocs = [Collections.Generic.List[object]]::new()
    $unimportedCompilerDocs = [Collections.Generic.List[string]]::new()
    $missingPublicApis = [Collections.Generic.List[string]]::new()
    foreach ($docId in $compilerByDocId.Keys | Sort-Object) {
        $ecma = $ecmaByDocId[$docId]
        $matches = @(Get-DocIdMetadataCandidates $docId $metadataCandidates)
        $hasPublicMatch = @($matches | Where-Object isPublic).Count -gt 0
        if ($null -ne $ecma -and -not $imported.Contains($docId)) {
            $unimportedCompilerDocs.Add($docId)
        }
        if ($hasPublicMatch -and ($null -eq $ecma -or -not $ecma.substantiveDocs)) {
            $missingPublicApis.Add($docId)
        }
        if ($null -ne $ecma) {
            continue
        }

        $classification = if ($filtered.Contains($docId)) {
            'filtered-java-peer-infrastructure'
        } elseif (Test-CanonicalizedLegacyDocId $docId $Canonicalizations) {
            'mdoc-obsolete-type-collision'
        } elseif ($matches.Count -gt 0 -and -not $hasPublicMatch) {
            'non-public-selected-api'
        } elseif ($docId.StartsWith('N:', [StringComparison]::Ordinal)) {
            'non-ecma-documentation-kind'
        } else {
            'unexplained'
        }
        $absentCompilerDocs.Add([PSCustomObject]@{
            docId = $docId
            classification = $classification
            sources = @($compilerByDocId[$docId])
        })
    }
    $unexplained = @($absentCompilerDocs | Where-Object classification -eq 'unexplained')
    $report = [ordered]@{
        schemaVersion = 1
        status = if ($invalidEcma.Count -eq 0 -and $unimportedCompilerDocs.Count -eq 0 -and
            $missingPublicApis.Count -eq 0 -and $unexplained.Count -eq 0) { 'passed' } else { 'failed' }
        selectedAssets = @($SelectedAssets | ForEach-Object {
            [PSCustomObject]@{ packageId = $_.PackageId; asset = $_.Asset; moniker = $_.Moniker }
        })
        ecma = [ordered]@{
            emittedApiCount = $ecmaEntries.Count
            invalidApis = @($invalidEcma)
        }
        compilerXml = [ordered]@{
            entryCount = $compilerEntries.Count
            uniqueDocIdCount = $compilerByDocId.Count
            unimportedDocIds = @($unimportedCompilerDocs | Sort-Object -Unique)
            absentFromEcma = @($absentCompilerDocs)
        }
        publicSelectedApi = [ordered]@{
            exactDocIdCandidates = @($compilerByDocId.Keys | Where-Object {
                @((Get-DocIdMetadataCandidates $_ $metadataCandidates) | Where-Object isPublic).Count -gt 0
            } | Sort-Object)
            missingEcmaOrDocs = @($missingPublicApis | Sort-Object -Unique)
        }
        filters = [ordered]@{
            javaPeerInfrastructureRemovedDocIds = @($FilteredDocIds | Sort-Object -Unique)
        }
    }
    Write-ApiDocsCompletenessReport $ReportPath $report
    if ($report.status -ne 'passed') {
        throw "API documentation completeness validation failed; see '$ReportPath'."
    }
    return [PSCustomObject]$report
}

Export-ModuleMember -Function `
    Test-SubstantiveEcmaDocs, `
    Get-EcmaDocumentationEntries, `
    Get-CompilerXmlDocumentationEntries, `
    Assert-ApiDocsCompleteness
