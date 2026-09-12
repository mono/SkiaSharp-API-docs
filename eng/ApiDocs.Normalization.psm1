Set-StrictMode -Version Latest

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

# Imports package compiler XML into clean mdoc ECMA output by exact DocId.
# It has no fallback to repository XML and does not perform identity rewrites.
function Import-CompilerXmlDocumentation([string] $OutputRoot, [string[]] $DocumentationPaths) {
    $compilerDocs = [Collections.Generic.Dictionary[string, System.Xml.XmlElement]]::new([StringComparer]::Ordinal)
    $compilerDocSources = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($documentationPath in $DocumentationPaths) {
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
            if ($compilerDocs.ContainsKey($docId) -and
                $compilerDocSources[$docId] -eq $documentationPath -and
                $compilerDocs[$docId].OuterXml -cne $member.OuterXml) {
                throw "Compiler XML '$documentationPath' has conflicting content for exact DocId '$docId'."
            }
            # mdoc framework imports are ordered; later framework-specific XML
            # deliberately supersedes an earlier duplicate for the same API.
            $compilerDocs[$docId] = $member
            $compilerDocSources[$docId] = $documentationPath
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
    return $imported
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
    Import-CompilerXmlDocumentation, `
    Remove-MdocObsoleteTypeCollision
