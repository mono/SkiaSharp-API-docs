Set-StrictMode -Version Latest

function Initialize-ApiDocsDocIdEnumerator {
    if ('SkiaSharp.ApiDocs.PublicApiDocIdEnumerator' -as [type]) {
        return
    }
    $root = Split-Path -Parent $PSScriptRoot
    $cecil = Join-Path $root 'artifacts/api-docs/tools/mdoc/5.9.3/tools/net6.0/Mono.Cecil.dll'
    if (-not (Test-Path -LiteralPath $cecil)) {
        throw "Pinned Mono.Cecil dependency '$cecil' is unavailable. Run eng/MDoc.ps1 first."
    }
    $project = Join-Path $PSScriptRoot 'ApiDocs.DocIds.csproj'
    $output = Join-Path $root 'artifacts/api-docs/tools/docids'
    $assembly = Join-Path $output 'ApiDocs.DocIds.dll'
    if (-not (Test-Path -LiteralPath $assembly)) {
        $null = & dotnet build $project --nologo --configuration Release --output $output
        if ($LASTEXITCODE -ne 0) {
            throw 'Failed to build the pinned API documentation identity helper.'
        }
    }
    $null = Add-Type -Path $assembly
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
                substantiveDocs = -not [string]::IsNullOrWhiteSpace([regex]::Replace($member.InnerText, '\s+', ' ').Trim())
            })
        }
    }
    return @($entries)
}

function Get-SelectedAssemblyDocIds([string[]] $AssemblyPaths, [switch] $IncludeNonPublic) {
    Initialize-ApiDocsDocIdEnumerator
    $docIds = @{}
    foreach ($assemblyPath in $AssemblyPaths | Sort-Object -Unique) {
        $entries = if ($IncludeNonPublic) {
            [SkiaSharp.ApiDocs.PublicApiDocIdEnumerator]::EnumerateAll($assemblyPath)
        } else {
            [SkiaSharp.ApiDocs.PublicApiDocIdEnumerator]::Enumerate($assemblyPath)
        }
        foreach ($entry in $entries) {
            if (-not $docIds.ContainsKey($entry.DocId)) {
                [void]($docIds[$entry.DocId] = [PSCustomObject]@{
                    docId = $entry.DocId; assembly = $entry.Assembly
                    metadataToken = $entry.MetadataToken; signature = $entry.Signature
                    isPublic = $entry.IsPublic; isErrorObsolete = $entry.IsErrorObsolete
                })
            }

        }
    }
    return [PSCustomObject]@{ ByDocId = $docIds }
}

function Get-SelectedAssemblyPublicDocIds([string[]] $AssemblyPaths) {
    return Get-SelectedAssemblyDocIds $AssemblyPaths
}

function Get-SelectedAssemblyReferencedTypes([string[]] $AssemblyPaths) {
    Initialize-ApiDocsDocIdEnumerator
    $types = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($assemblyPath in $AssemblyPaths | Sort-Object -Unique) {
        foreach ($typeName in [SkiaSharp.ApiDocs.PublicApiDocIdEnumerator]::EnumerateReferencedTypes($assemblyPath)) {
            [void]$types.Add($typeName)
        }
    }
    return [PSCustomObject]@{ Types = $types }
}

function Get-DocIdDeclaringType([string] $DocId) {
    $identity = $DocId.Substring(2)
    if ($DocId.StartsWith('T:', [StringComparison]::Ordinal)) {
        return $identity
    }
    $identity = $identity.Split(@('(', '~'), 2)[0]
    $separator = $identity.LastIndexOf('.')
    if ($separator -gt 0) {
        return $identity.Substring(0, $separator)
    }
    return ''
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
    $metadataByDocId = (Get-SelectedAssemblyPublicDocIds $AssemblyPaths).ByDocId
    $ecmaByDocId = @{}
    $invalidEcma = [Collections.Generic.List[object]]::new()
    foreach ($entry in $ecmaEntries) {
        if ([string]::IsNullOrWhiteSpace($entry.docId)) {
            $invalidEcma.Add([PSCustomObject]@{ path = $entry.path; kind = $entry.kind; reason = 'missing-doc-id' })
        } elseif ($ecmaByDocId.ContainsKey($entry.docId)) {
            $invalidEcma.Add([PSCustomObject]@{ docId = $entry.docId; path = $entry.path; kind = $entry.kind; reason = 'duplicate-doc-id' })
        } else {
            [void]($ecmaByDocId[$entry.docId] = $entry)
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
            [void]($compilerByDocId[$entry.docId] = [Collections.Generic.List[object]]::new())
        }
        $compilerByDocId[$entry.docId].Add($entry)
    }

    $absentCompilerDocs = [Collections.Generic.List[object]]::new()
    $unimportedCompilerDocs = [Collections.Generic.List[string]]::new()
    $missingPublicApis = [Collections.Generic.List[object]]::new()
    $missingCompilerDocs = [Collections.Generic.List[object]]::new()
    foreach ($metadataDocId in $metadataByDocId.Keys | Sort-Object) {
        if (-not $compilerByDocId.ContainsKey($metadataDocId)) {
            $missingCompilerDocs.Add($metadataByDocId[$metadataDocId])
        }
        $ecma = $ecmaByDocId[$metadataDocId]
        if ($null -eq $ecma -or -not $ecma.substantiveDocs) {
            $missingPublicApis.Add($metadataByDocId[$metadataDocId])
        }
    }
    $ecmaAbsentFromReference = @($ecmaByDocId.Keys | Where-Object { -not $metadataByDocId.ContainsKey($_) })
    foreach ($docId in $compilerByDocId.Keys | Sort-Object) {
        $ecma = $ecmaByDocId[$docId]
        $publicMetadata = $metadataByDocId[$docId]
        if ($null -ne $ecma -and -not $imported.Contains($docId)) {
            $unimportedCompilerDocs.Add($docId)
        }
        if ($null -ne $ecma) {
            continue
        }

        $classification = if ($filtered.Contains($docId)) {
            'filtered-java-peer-infrastructure'
        } elseif (Test-CanonicalizedLegacyDocId $docId $Canonicalizations) {
            'mdoc-obsolete-type-collision'
        } else { 'implementation-only-sidecar' }
        $absentCompilerDocs.Add([PSCustomObject]@{
            docId = $docId
            classification = $classification
            sources = @($compilerByDocId[$docId])
        })
    }
    $report = [ordered]@{
        schemaVersion = 1
        status = if ($invalidEcma.Count -eq 0 -and $unimportedCompilerDocs.Count -eq 0 -and
            $missingPublicApis.Count -eq 0 -and $missingCompilerDocs.Count -eq 0 -and
            $ecmaAbsentFromReference.Count -eq 0) { 'passed' } else { 'failed' }
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
            implementationOnlySidecarCount = @($absentCompilerDocs | Where-Object classification -eq 'implementation-only-sidecar').Count
        }
        referenceSurface = [ordered]@{
            ecmaAbsentFromReference = @($ecmaAbsentFromReference | Sort-Object)
        }
        publicSelectedApi = [ordered]@{
            count = $metadataByDocId.Count
            docIds = @($metadataByDocId.Keys | Sort-Object)
            missingCompilerXml = @($missingCompilerDocs | Sort-Object docId)
            missingEcmaOrDocs = @($missingPublicApis | Sort-Object docId)
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
    Get-SelectedAssemblyPublicDocIds, `
    Assert-ApiDocsCompleteness
