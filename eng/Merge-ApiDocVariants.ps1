<#
.SYNOPSIS
Folds internal mdoc platform framework sources into one public Views moniker.

.DESCRIPTION
mdoc creates the structural union. This script uses isolated single-variant
donors to select canonical metadata and remove mdoc's internal framework
metadata before publishing the existing skiasharp-views moniker.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $StagingRoot,
    [Parameter(Mandatory)][object[]] $Variants
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-DocId([Xml.XmlElement] $Node, [bool] $Member) {
    $path = if ($Member) { "MemberSignature[@Language='DocId']" } else { "TypeSignature[@Language='DocId']" }
    $signature = $Node.SelectSingleNode($path)
    if ($null -eq $signature -or [string]::IsNullOrWhiteSpace($signature.GetAttribute('Value'))) {
        throw "A $($Node.Name) node is missing its DocId signature."
    }
    return $signature.GetAttribute('Value')
}

function Get-TypeDocuments([string] $Root) {
    $documents = @{}
    foreach ($file in Get-ChildItem -LiteralPath $Root -Filter '*.xml' -File -Recurse) {
        if ($file.Directory.Name -eq 'FrameworksIndex') { continue }
        $document = [Xml.XmlDocument]::new()
        $document.PreserveWhitespace = $true
        $document.Load($file.FullName)
        if ($null -eq $document.DocumentElement.SelectSingleNode("TypeSignature[@Language='DocId']")) { continue }
        $id = Get-DocId $document.DocumentElement $false
        if ($documents.ContainsKey($id)) { throw "Duplicate type DocId '$id' in '$Root'." }
        $documents[$id] = [PSCustomObject]@{ File = $file.FullName; Document = $document; Type = $document.DocumentElement }
    }
    return $documents
}

function Get-Presence([string] $IndexPath) {
    if (-not (Test-Path -LiteralPath $IndexPath)) { throw "Missing donor FrameworksIndex '$IndexPath'." }
    $document = [Xml.XmlDocument]::new()
    $document.PreserveWhitespace = $true
    $document.Load($IndexPath)
    $types = @{}
    $members = @{}
    foreach ($type in @($document.SelectNodes('/Framework/Namespace/Type'))) {
        $typeId = $type.GetAttribute('Id')
        if ([string]::IsNullOrWhiteSpace($typeId) -or $types.ContainsKey($typeId)) {
            throw "Ambiguous type identity in '$IndexPath'."
        }
        $types[$typeId] = $true
        foreach ($member in @($type.SelectNodes('Member'))) {
            $memberId = $member.GetAttribute('Id')
            if ([string]::IsNullOrWhiteSpace($memberId) -or $members.ContainsKey($memberId)) {
                throw "Ambiguous member identity in '$IndexPath'."
            }
            $members[$memberId] = $true
        }
    }
    return [PSCustomObject]@{ Document = $document; Types = $types; Members = $members }
}

function Get-ExtensionMethods([string] $IndexPath) {
    $document = [Xml.XmlDocument]::new()
    $document.PreserveWhitespace = $true
    $document.Load($IndexPath)
    $methods = @{}
    foreach ($extension in @($document.SelectNodes('/Overview/ExtensionMethods/ExtensionMethod'))) {
        $member = $extension.SelectSingleNode('Member')
        if ($null -eq $member) { throw "Extension method without a member in '$IndexPath'." }
        $id = Get-DocId $member $true
        if ($methods.ContainsKey($id)) { throw "Duplicate donor extension DocId '$id' in '$IndexPath'." }
        $methods[$id] = $extension
    }
    return $methods
}

function Get-AssemblyOverview([string] $IndexPath, [string] $AssemblyName) {
    $document = [Xml.XmlDocument]::new()
    $document.PreserveWhitespace = $true
    $document.Load($IndexPath)
    $matches = @($document.SelectNodes("/Overview/Assemblies/Assembly[@Name='$AssemblyName']"))
    if ($matches.Count -ne 1) {
        throw "Expected exactly one '$AssemblyName' assembly overview in '$IndexPath'."
    }
    return $matches[0]
}

function Get-DonorMember([object] $Variant, [string] $TypeId, [string] $MemberId) {
    if (-not $Variant.TypeDocuments.ContainsKey($TypeId)) { return $null }
    $matches = @($Variant.TypeDocuments[$TypeId].Type.SelectNodes('Members/Member') | Where-Object { (Get-DocId $_ $true) -eq $MemberId })
    if ($matches.Count -gt 1) { throw "Ambiguous donor member '$MemberId' in '$($Variant.Key)'." }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

function Select-Donor([object[]] $Group, [string] $Id, [bool] $Member) {
    $present = @($Group | Where-Object { if ($Member) { $_.Presence.Members.ContainsKey($Id) } else { $_.Presence.Types.ContainsKey($Id) } })
    if ($present.Count -eq 0) { throw "No donor owns '$Id'." }
    $canonical = @($present | Where-Object Canonical)
    if ($canonical.Count -gt 1) { throw "Multiple canonical donors own '$Id'." }
    if ($canonical.Count -eq 1) { return $canonical[0] }
    if ($present.Count -eq 1) { return $present[0] }
    throw "Multiple non-canonical donors own '$Id'."
}

function Replace-Children([Xml.XmlElement] $Target, [Xml.XmlElement] $Source, [string[]] $Preserve) {
    $preserved = @{}
    foreach ($name in $Preserve) {
        $preserved[$name] = @($Target.SelectNodes($name))
    }
    $depth = 0
    $parent = $Target.ParentNode
    while ($parent -is [Xml.XmlElement]) {
        $depth++
        $parent = $parent.ParentNode
    }
    $childWhitespace = "`n" + ('  ' * ($depth + 1))
    $closingWhitespace = "`n" + ('  ' * $depth)
    foreach ($child in @($Target.ChildNodes)) {
        [void]$Target.RemoveChild($child)
    }
    foreach ($child in @($Source.ChildNodes)) {
        if ($child.NodeType -ne [Xml.XmlNodeType]::Element) { continue }
        if ($child.Name -in $Preserve) {
            foreach ($preservedNode in $preserved[$child.Name]) {
                [void]$Target.AppendChild($Target.OwnerDocument.CreateWhitespace($childWhitespace))
                [void]$Target.AppendChild($preservedNode)
            }
        }
        else {
            [void]$Target.AppendChild($Target.OwnerDocument.CreateWhitespace($childWhitespace))
            [void]$Target.AppendChild($Target.OwnerDocument.ImportNode($child, $true))
        }
    }
    [void]$Target.AppendChild($Target.OwnerDocument.CreateWhitespace($closingWhitespace))
}

function Get-NonEmptyDocs([Xml.XmlElement] $Node) {
    $docs = $Node.SelectSingleNode('Docs')
    return $null -ne $docs -and -not [string]::IsNullOrWhiteSpace(($docs.InnerText -replace '\s+', ' ').Trim())
}

function Select-DocumentationDonor([object[]] $Group, [string] $Id, [bool] $Member, [string] $TypeId, [object] $Selected) {
    $selectedNode = if ($Member) { Get-DonorMember $Selected $TypeId $Id } else { $Selected.TypeDocuments[$Id].Type }
    if (Get-NonEmptyDocs $selectedNode) { return $selectedNode }
    foreach ($variant in $Group) {
        $present = if ($Member) { $variant.Presence.Members.ContainsKey($Id) } else { $variant.Presence.Types.ContainsKey($Id) }
        if (-not $present) { continue }
        $candidate = if ($Member) { Get-DonorMember $variant $TypeId $Id } else { $variant.TypeDocuments[$Id].Type }
        if (Get-NonEmptyDocs $candidate) { return $candidate }
    }
    return $selectedNode
}

function Copy-Docs([Xml.XmlElement] $Target, [Xml.XmlElement] $Source) {
    $existing = $Target.SelectSingleNode('Docs')
    $docs = $Source.SelectSingleNode('Docs')
    if ($null -ne $existing -and $null -ne $docs) {
        [void]$Target.ReplaceChild($Target.OwnerDocument.ImportNode($docs, $true), $existing)
    }
    elseif ($null -ne $existing) {
        [void]$Target.RemoveChild($existing)
    }
    elseif ($null -ne $docs) {
        [void]$Target.AppendChild($Target.OwnerDocument.ImportNode($docs, $true))
    }
}

function Assert-AssemblyProviders([Xml.XmlElement] $Target, [Xml.XmlElement] $Donor, [string] $Id) {
    foreach ($provider in @($Donor.SelectNodes('AssemblyInfo'))) {
        $name = $provider.SelectSingleNode('AssemblyName').InnerText
        $version = $provider.SelectSingleNode('AssemblyVersion').InnerText
        $found = @($Target.SelectNodes('AssemblyInfo') | Where-Object {
            $_.SelectSingleNode('AssemblyName').InnerText -eq $name -and $_.SelectSingleNode('AssemblyVersion').InnerText -eq $version
        })
        if ($found.Count -ne 1) { throw "mdoc did not retain exactly one real AssemblyInfo provider '$name $version' for '$Id'." }
    }
}

function Add-Note([Xml.XmlElement] $Node, [string] $Text) {
    $docs = $Node.SelectSingleNode('Docs')
    if ($null -eq $docs) {
        $docs = $Node.OwnerDocument.CreateElement('Docs')
        [void]$Node.AppendChild($docs)
    }
    $remarks = $docs.SelectSingleNode('remarks')
    if ($null -eq $remarks) {
        $remarks = $Node.OwnerDocument.CreateElement('remarks')
        [void]$docs.AppendChild($remarks)
    }
    foreach ($paragraph in @($remarks.SelectNodes('para'))) {
        if ($paragraph.InnerText -eq $Text) { return }
    }
    $paragraph = $Node.OwnerDocument.CreateElement('para')
    $paragraph.InnerText = $Text
    [void]$remarks.AppendChild($paragraph)
}

function Get-StructuralFingerprint([Xml.XmlElement] $Node, [bool] $Member) {
    $copy = [Xml.XmlDocument]::new()
    $element = $copy.ImportNode($Node, $true)
    [void]$copy.AppendChild($element)
    foreach ($child in @($element.ChildNodes)) {
        if ($child.NodeType -eq [Xml.XmlNodeType]::Element -and ($child.Name -in @('AssemblyInfo', 'Docs') -or (-not $Member -and $child.Name -eq 'Members'))) {
            [void]$element.RemoveChild($child)
        }
    }
    Remove-FormattingWhitespace $element
    return ($element.OuterXml -replace '\s+', '')
}

function Remove-FormattingWhitespace([Xml.XmlNode] $Node) {
    foreach ($child in @($Node.ChildNodes)) {
        if ($child.NodeType -eq [Xml.XmlNodeType]::Whitespace -or
            ($child.NodeType -eq [Xml.XmlNodeType]::Text -and [string]::IsNullOrWhiteSpace($child.Value))) {
            [void]$Node.RemoveChild($child)
        }
        elseif ($child.NodeType -eq [Xml.XmlNodeType]::Element) {
            Remove-FormattingWhitespace $child
        }
    }
}

function Add-VariantNotes([Xml.XmlElement] $Target, [object[]] $Group, [string] $Id, [bool] $Member, [object] $Selected) {
    $present = @($Group | Where-Object { if ($Member) { $_.Presence.Members.ContainsKey($Id) } else { $_.Presence.Types.ContainsKey($Id) } })
    if ($present.Count -ne $Group.Count) {
        if ($Group[0].Group -eq 'apple' -and $Group.Count -eq 2) {
            $other = @($Group | Where-Object { $_.Key -ne $present[0].Key })[0]
            Add-Note $Target "This API is available in the $($present[0].Label) but not in the $($other.Label)."
        }
        else {
            Add-Note $Target "This API is available only in the $($present[0].Label)."
        }
        return
    }
    $nodes = foreach ($variant in $present) {
        $node = if ($Member) { Get-DonorMember $variant ($Target.GetAttribute('__typeDocId')) $Id } else { $variant.TypeDocuments[$Id].Type }
        if ($null -eq $node) { throw "Donor '$($variant.Key)' has no node for '$Id'." }
        [PSCustomObject]@{ Variant = $variant; Node = $node }
    }
    $signaturePath = if ($Member) { "MemberSignature[@Language='C#']" } else { "TypeSignature[@Language='C#']" }
    $csharp = @($nodes | ForEach-Object { $_.Node.SelectSingleNode($signaturePath) } | ForEach-Object { $_.GetAttribute('Value') })
    if (@($csharp | Sort-Object -Unique).Count -gt 1) {
        $parts = foreach ($entry in $nodes) {
            $signature = $entry.Node.SelectSingleNode($signaturePath)
            "$($entry.Variant.ShortLabel): $($signature.GetAttribute('Value'))"
        }
        Add-Note $Target "Platform signature: $($parts -join '; ') Displayed signature: $($Selected.ShortLabel)."
    }
    elseif (@($nodes | ForEach-Object { Get-StructuralFingerprint $_.Node $Member } | Sort-Object -Unique).Count -gt 1) {
        Add-Note $Target "Platform metadata differs between variants. Displayed metadata: $($Selected.ShortLabel)."
    }
}

function Add-SortedChild(
    [Xml.XmlElement] $Parent,
    [Xml.XmlElement] $Child,
    [string] $ExistingPath,
    [scriptblock] $GetSortKey,
    [int] $Indent
) {
    $document = $Parent.OwnerDocument
    $imported = $document.ImportNode($Child, $true)
    $sortKey = & $GetSortKey $Child
    foreach ($existing in @($Parent.SelectNodes($ExistingPath))) {
        if ([StringComparer]::OrdinalIgnoreCase.Compare($sortKey, (& $GetSortKey $existing)) -lt 0) {
            [void]$Parent.InsertBefore($imported, $existing)
            [void]$Parent.InsertBefore($document.CreateWhitespace("`n" + (' ' * $Indent)), $existing)
            return
        }
    }
    $closingWhitespace = if ($Parent.LastChild.NodeType -eq [Xml.XmlNodeType]::Whitespace) { $Parent.LastChild } else { $null }
    if ($null -ne $closingWhitespace) {
        [void]$Parent.InsertBefore($document.CreateWhitespace("`n" + (' ' * $Indent)), $closingWhitespace)
        [void]$Parent.InsertBefore($imported, $closingWhitespace)
    }
    else {
        [void]$Parent.AppendChild($document.CreateWhitespace("`n" + (' ' * $Indent)))
        [void]$Parent.AppendChild($imported)
    }
}

function Move-VariantAssemblyOverviews([Xml.XmlDocument] $Index, [object[]] $Variants) {
    $assemblies = $Index.SelectSingleNode('/Overview/Assemblies')
    $nodes = @{}
    foreach ($assemblyGroup in @($Variants | Group-Object { [IO.Path]::GetFileNameWithoutExtension($_.Asset.Assembly.Name) })) {
        $name = $assemblyGroup.Name
        $matches = @($assemblies.SelectNodes("Assembly[@Name='$name']"))
        if ($matches.Count -ne 1) {
            throw "Expected exactly one assembly overview for variant assembly '$name'."
        }
        $selected = @($assemblyGroup.Group | Where-Object Canonical)
        if ($selected.Count -gt 1) {
            throw "Multiple canonical donors provide assembly overview '$name'."
        }
        if ($selected.Count -eq 0) {
            if ($assemblyGroup.Count -ne 1) {
                throw "Multiple non-canonical donors provide assembly overview '$name'."
            }
            $selected = @($assemblyGroup.Group)
        }
        $nodes[$name] = $selected[0].AssemblyOverview
    }
    foreach ($name in $nodes.Keys) {
        $node = $assemblies.SelectSingleNode("Assembly[@Name='$name']")
        $whitespace = $node.PreviousSibling
        [void]$assemblies.RemoveChild($node)
        if ($null -ne $whitespace -and $whitespace.NodeType -eq [Xml.XmlNodeType]::Whitespace) {
            [void]$assemblies.RemoveChild($whitespace)
        }
    }
    foreach ($name in @($nodes.Keys | Sort-Object)) {
        Add-SortedChild $assemblies $nodes[$name] "Assembly[starts-with(@Name, 'SkiaSharp.Views.') and not(starts-with(@Name, 'SkiaSharp.Views.Maui'))]" {
            param($node)
            $node.GetAttribute('Name')
        } 4
    }
}

function Merge-FrameworkIndex([Xml.XmlDocument] $Public, [Xml.XmlDocument] $Internal) {
    $publicFramework = $Public.DocumentElement
    foreach ($assembly in @($Internal.SelectNodes('/Framework/Assemblies/Assembly'))) {
        $name = $assembly.GetAttribute('Name')
        $version = $assembly.GetAttribute('Version')
        if (@($publicFramework.SelectNodes("Assemblies/Assembly[@Name='$name' and @Version='$version']")).Count -eq 0) {
            Add-SortedChild ($publicFramework.SelectSingleNode('Assemblies')) $assembly 'Assembly' {
                param($node)
                "$($node.GetAttribute('Name'))|$($node.GetAttribute('Version'))"
            } 4
        }
    }
    foreach ($sourceNamespace in @($Internal.SelectNodes('/Framework/Namespace'))) {
        $name = $sourceNamespace.GetAttribute('Name')
        $targetNamespace = $publicFramework.SelectSingleNode("Namespace[@Name='$name']")
        if ($null -eq $targetNamespace) {
            Add-SortedChild $publicFramework $sourceNamespace 'Namespace' {
                param($node)
                $node.GetAttribute('Name')
            } 2
            continue
        }
        foreach ($sourceType in @($sourceNamespace.SelectNodes('Type'))) {
            $id = $sourceType.GetAttribute('Id')
            $targetType = $targetNamespace.SelectSingleNode("Type[@Id='$id']")
            if ($null -eq $targetType) {
                Add-SortedChild $targetNamespace $sourceType 'Type' {
                    param($node)
                    $node.GetAttribute('Id')
                } 4
                continue
            }
            foreach ($sourceMember in @($sourceType.SelectNodes('Member'))) {
                $memberId = $sourceMember.GetAttribute('Id')
                if (@($targetType.SelectNodes("Member[@Id='$memberId']")).Count -eq 0) {
                    Add-SortedChild $targetType $sourceMember 'Member' {
                        param($node)
                        $node.GetAttribute('Id')
                    } 6
                }
            }
        }
    }
}

function Remove-InternalMetadata([Xml.XmlNode] $Node) {
    if ($Node -is [Xml.XmlElement]) {
        foreach ($name in @('FrameworkAlternate', 'FrameworkOnly', 'Index')) {
            [void]$Node.RemoveAttribute($name)
        }
    }
    foreach ($child in @($Node.ChildNodes)) {
        if ($null -eq $child) { continue }
        if ($child.NodeType -eq [Xml.XmlNodeType]::Element -and $child.Name -in @('FrameworkAlternate', 'FrameworkOnly')) {
            [void]$Node.RemoveChild($child)
        }
        elseif ($child.NodeType -eq [Xml.XmlNodeType]::Element) { Remove-InternalMetadata $child }
    }
}

foreach ($variant in $Variants) {
    $variant | Add-Member -NotePropertyName Presence -NotePropertyValue (Get-Presence (Join-Path $variant.DonorRoot "FrameworksIndex/$($variant.Key).xml"))
    $variant | Add-Member -NotePropertyName TypeDocuments -NotePropertyValue (Get-TypeDocuments $variant.DonorRoot)
    $variant | Add-Member -NotePropertyName ExtensionMethods -NotePropertyValue (Get-ExtensionMethods (Join-Path $variant.DonorRoot 'index.xml'))
    $assemblyName = [IO.Path]::GetFileNameWithoutExtension($variant.Asset.Assembly.Name)
    $variant | Add-Member -NotePropertyName AssemblyOverview -NotePropertyValue (Get-AssemblyOverview (Join-Path $variant.DonorRoot 'index.xml') $assemblyName)
}

$publicTypes = Get-TypeDocuments $StagingRoot
foreach ($group in @($Variants | Group-Object Group)) {
    $variantsInGroup = @($group.Group)
    foreach ($variant in $variantsInGroup) {
        foreach ($typeId in $variant.Presence.Types.Keys) {
            if (-not $variant.TypeDocuments.ContainsKey($typeId)) { throw "Donor '$($variant.Key)' index references missing type '$typeId'." }
        }
    }
    $typeIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($variant in $variantsInGroup) {
        foreach ($id in $variant.Presence.Types.Keys) { [void]$typeIds.Add($id) }
    }
    foreach ($typeId in @($typeIds | Sort-Object)) {
        if (-not $publicTypes.ContainsKey($typeId)) { throw "mdoc structural union omitted type '$typeId'." }
        $targetType = $publicTypes[$typeId].Type
        $selected = Select-Donor $variantsInGroup $typeId $false
        $sourceType = $selected.TypeDocuments[$typeId].Type
        Replace-Children $targetType $sourceType @('AssemblyInfo', 'Members')
        foreach ($providerVariant in @($variantsInGroup | Where-Object { $_.Presence.Types.ContainsKey($typeId) })) {
            Assert-AssemblyProviders $targetType $providerVariant.TypeDocuments[$typeId].Type $typeId
        }
        Copy-Docs $targetType (Select-DocumentationDonor $variantsInGroup $typeId $false $null $selected)
        $targetType.SetAttribute('__typeDocId', $typeId)
        Add-VariantNotes $targetType $variantsInGroup $typeId $false $selected
        $publicMembers = @{}
        foreach ($member in @($targetType.SelectNodes('Members/Member'))) {
            $memberId = Get-DocId $member $true
            if ($publicMembers.ContainsKey($memberId)) { throw "Ambiguous public member '$memberId'." }
            $publicMembers[$memberId] = $member
        }
        $memberPrefix = "$($typeId.Substring(2))."
        $memberIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($variant in $variantsInGroup) {
            foreach ($id in $variant.Presence.Members.Keys) {
                if ($id.Length -gt 2 -and $id.Substring(2).StartsWith($memberPrefix, [StringComparison]::Ordinal)) { [void]$memberIds.Add($id) }
            }
        }
        foreach ($memberId in @($memberIds | Sort-Object)) {
            if (-not $publicMembers.ContainsKey($memberId)) { throw "mdoc structural union omitted member '$memberId'." }
            $selectedMember = Select-Donor $variantsInGroup $memberId $true
            $sourceMember = Get-DonorMember $selectedMember $typeId $memberId
            if ($null -eq $sourceMember) { throw "Donor '$($selectedMember.Key)' index does not match member '$memberId'." }
            $targetMember = $publicMembers[$memberId]
            Replace-Children $targetMember $sourceMember @('AssemblyInfo')
            foreach ($providerVariant in @($variantsInGroup | Where-Object { $_.Presence.Members.ContainsKey($memberId) })) {
                Assert-AssemblyProviders $targetMember (Get-DonorMember $providerVariant $typeId $memberId) $memberId
            }
            Copy-Docs $targetMember (Select-DocumentationDonor $variantsInGroup $memberId $true $typeId $selectedMember)
            $targetMember.SetAttribute('__typeDocId', $typeId)
            Add-VariantNotes $targetMember $variantsInGroup $memberId $true $selectedMember
            $targetMember.RemoveAttribute('__typeDocId')
            $targetFingerprint = Get-StructuralFingerprint $targetMember $true
            $sourceFingerprint = Get-StructuralFingerprint $sourceMember $true
            if ($targetFingerprint -ne $sourceFingerprint) { throw "Canonical structural comparison failed for member '$memberId'." }
        }
        $targetType.RemoveAttribute('__typeDocId')
        if ((Get-StructuralFingerprint $targetType $false) -ne (Get-StructuralFingerprint $sourceType $false)) {
            throw "Canonical structural comparison failed for type '$typeId'."
        }
    }
}

$publicTypes.Values | ForEach-Object { $_.Document.Save($_.File) }

$publicIndexPath = Join-Path $StagingRoot 'FrameworksIndex/skiasharp-views.xml'
if (-not (Test-Path -LiteralPath $publicIndexPath)) { throw "The public skiasharp-views FrameworksIndex was not generated." }
$publicIndex = [Xml.XmlDocument]::new()
$publicIndex.PreserveWhitespace = $true
$publicIndex.Load($publicIndexPath)
foreach ($variant in $Variants) {
    Merge-FrameworkIndex $publicIndex $variant.Presence.Document
    Remove-Item -LiteralPath (Join-Path $StagingRoot "FrameworksIndex/$($variant.Key).xml") -Force -ErrorAction Stop
}
Remove-InternalMetadata $publicIndex
$publicIndex.Save($publicIndexPath)

$indexPath = Join-Path $StagingRoot 'index.xml'
$index = [Xml.XmlDocument]::new()
$index.PreserveWhitespace = $true
$index.Load($indexPath)
Move-VariantAssemblyOverviews $index $Variants
$extensionGroups = @{}
foreach ($extension in @($index.SelectNodes('/Overview/ExtensionMethods/ExtensionMethod'))) {
    $member = $extension.SelectSingleNode('Member')
    if ($null -eq $member) { throw 'Public extension method has no member.' }
    $id = Get-DocId $member $true
    if (-not $extensionGroups.ContainsKey($id)) { $extensionGroups[$id] = [Collections.Generic.List[Xml.XmlElement]]::new() }
    $extensionGroups[$id].Add($extension)
}
foreach ($id in $extensionGroups.Keys) {
    $extensions = $extensionGroups[$id]
    if ($extensions.Count -le 1) { continue }
    $owners = @($Variants | Where-Object { $_.Presence.Members.ContainsKey($id) })
    if ($owners.Count -eq 0) {
        throw "Duplicate non-variant extension DocId '$id'."
    }
    $owner = Select-Donor $owners $id $true
    if (-not $owner.ExtensionMethods.ContainsKey($id)) {
        throw "Donor '$($owner.Key)' has no extension index entry for '$id'."
    }
    $replacement = $index.ImportNode($owner.ExtensionMethods[$id], $true)
    [void]$extensions[0].ParentNode.ReplaceChild($replacement, $extensions[0])
    foreach ($duplicate in @($extensions | Select-Object -Skip 1)) { [void]$duplicate.ParentNode.RemoveChild($duplicate) }
}
Remove-InternalMetadata $index
$publicExtensionIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($extension in @($index.SelectNodes('/Overview/ExtensionMethods/ExtensionMethod'))) {
    $member = $extension.SelectSingleNode('Member')
    $id = Get-DocId $member $true
    if (-not $publicExtensionIds.Add($id)) {
        throw "Duplicate public extension DocId '$id' after variant reconciliation."
    }
}
foreach ($variant in $Variants) {
    foreach ($id in $variant.ExtensionMethods.Keys) {
        if (-not $publicExtensionIds.Contains($id)) {
            throw "Public extension index omitted donor method '$id' from '$($variant.Key)'."
        }
    }
}
$index.Save($indexPath)

foreach ($file in Get-ChildItem -LiteralPath $StagingRoot -Filter '*.xml' -File -Recurse) {
    $document = [Xml.XmlDocument]::new()
    $document.PreserveWhitespace = $true
    $document.Load($file.FullName)
    Remove-InternalMetadata $document
    foreach ($returnValue in @($document.SelectNodes('//ReturnValue'))) {
        if ($null -eq $returnValue.SelectSingleNode('*')) { throw "Empty ReturnValue in '$($file.FullName)'." }
    }
    $document.Save($file.FullName)
    $xml = Get-Content -LiteralPath $file.FullName -Raw
    foreach ($variant in $Variants) {
        if ($xml.Contains($variant.Key)) { throw "Internal framework key '$($variant.Key)' leaked into '$($file.FullName)'." }
    }
}
