<#
.SYNOPSIS
Publishes the mdoc union of internal Views platform frameworks.

.DESCRIPTION
mdoc already produces the structural, documentation, and provider union. This
script uses its FrameworksIndex presence data only to choose the published
variant metadata and to add platform notes.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $StagingRoot,
    [Parameter(Mandatory)][object[]] $Variants
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-DocId([Xml.XmlElement] $Node, [bool] $Member) {
    $name = if ($Member) { 'MemberSignature' } else { 'TypeSignature' }
    $signature = $Node.SelectSingleNode("$name[@Language='DocId']")
    if ($null -eq $signature -or [string]::IsNullOrWhiteSpace($signature.GetAttribute('Value'))) {
        throw "A $($Node.Name) node is missing its DocId signature."
    }
    $signature.GetAttribute('Value')
}

function Get-TypeDocuments([string] $Root) {
    $result = @{}
    foreach ($file in Get-ChildItem -LiteralPath $Root -Filter '*.xml' -File -Recurse) {
        if ($file.Directory.Name -eq 'FrameworksIndex') { continue }
        $document = [Xml.XmlDocument]::new(); $document.PreserveWhitespace = $true; $document.Load($file.FullName)
        if ($null -eq $document.DocumentElement.SelectSingleNode("TypeSignature[@Language='DocId']")) { continue }
        $id = Get-DocId $document.DocumentElement $false
        if ($result.ContainsKey($id)) { throw "Duplicate type DocId '$id'." }
        $result[$id] = [PSCustomObject]@{ File = $file.FullName; Document = $document; Node = $document.DocumentElement; Changed = $false }
    }
    $result
}

function Get-Presence([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "Missing FrameworksIndex '$Path'." }
    $document = [Xml.XmlDocument]::new(); $document.PreserveWhitespace = $true; $document.Load($Path)
    $types = @{}; $members = @{}
    foreach ($type in @($document.SelectNodes('/Framework/Namespace/Type'))) {
        $typeId = $type.GetAttribute('Id')
        if ([string]::IsNullOrWhiteSpace($typeId) -or $types.ContainsKey($typeId)) { throw "Ambiguous type identity in '$Path'." }
        $memberSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($member in @($type.SelectNodes('Member'))) {
            $id = $member.GetAttribute('Id')
            if ([string]::IsNullOrWhiteSpace($id) -or -not $memberSet.Add($id) -or $members.ContainsKey($id)) { throw "Ambiguous member identity '$id' in '$Path'." }
            $members[$id] = $true
        }
        $types[$typeId] = $memberSet
    }
    [PSCustomObject]@{ Document = $document; Types = $types; Members = $members }
}

function Get-Owners([object[]] $Group, [string] $Id, [bool] $Member) {
    @($Group | Where-Object { if ($Member) { $_.Presence.Members.ContainsKey($Id) } else { $_.Presence.Types.ContainsKey($Id) } })
}

function Get-CanonicalOwner([object[]] $Owners, [string] $Id) {
    if ($Owners.Count -eq 0) { throw "No variant owns '$Id'." }
    if ($Owners.Count -eq 1) { return $Owners[0] }
    $canonical = @($Owners | Where-Object Canonical)
    if ($canonical.Count -ne 1) { throw "Ambiguous canonical variant for '$Id'." }
    $canonical[0]
}

function Add-Note([Xml.XmlElement] $Node, [string] $Text) {
    $docs = $Node.SelectSingleNode('Docs')
    if ($null -eq $docs) { $docs = $Node.OwnerDocument.CreateElement('Docs'); [void]$Node.AppendChild($docs) }
    $remarks = $docs.SelectSingleNode('remarks')
    if ($null -eq $remarks) { $remarks = $Node.OwnerDocument.CreateElement('remarks'); [void]$docs.AppendChild($remarks) }

    foreach ($paragraph in @($remarks.SelectNodes('para') | Where-Object { $_.InnerText -eq $Text })) {
        [void]$remarks.RemoveChild($paragraph)
    }

    $markdownText = $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
    $markdown = "> [!NOTE]`n> $markdownText"
    foreach ($format in @($remarks.SelectNodes("format[@type='text/markdown']") | Where-Object { $_.InnerText.Trim() -eq $markdown })) {
        [void]$remarks.RemoveChild($format)
    }

    $format = $Node.OwnerDocument.CreateElement('format')
    $format.SetAttribute('type', 'text/markdown')
    [void]$format.AppendChild($Node.OwnerDocument.CreateCDataSection("`n$markdown`n"))
    $first = $remarks.FirstChild
    [void]$remarks.InsertBefore($format, $first)
    if ($null -ne $first -and $first.NodeType -ne [Xml.XmlNodeType]::Whitespace) {
        [void]$remarks.InsertBefore($Node.OwnerDocument.CreateWhitespace("`n"), $first)
    }
}

function Get-ScopedElements([Xml.XmlElement] $Node, [bool] $Member, [string] $Name) {
    if ($Member) { return @($Node.SelectNodes("$Name")) }
    @($Node.SelectNodes(".//$Name[not(ancestor::Members)]"))
}

function Get-CSharpSignature([Xml.XmlElement] $Node, [bool] $Member, [object] $Owner) {
    $name = if ($Member) { 'MemberSignature' } else { 'TypeSignature' }
    $signatures = @(Get-ScopedElements $Node $Member "$name[@Language='C#']")
    $marked = @($signatures | Where-Object { $_.GetAttribute('FrameworkAlternate') -eq $Owner.Key })
    if ($marked.Count -eq 1) { return $marked[0].GetAttribute('Value') }
    $unmarked = @($signatures | Where-Object { -not $_.HasAttribute('FrameworkAlternate') })
    if ($unmarked.Count -eq 1 -and $Owner.Canonical) { return $unmarked[0].GetAttribute('Value') }
    if ($signatures.Count -eq 1) { return $signatures[0].GetAttribute('Value') }
    throw "Could not identify the $($Owner.Key) C# signature for '$((Get-DocId $Node $Member))'."
}

function Remove-Alternates([Xml.XmlElement] $Node, [bool] $Member, [string] $CanonicalKey) {
    foreach ($child in @($Node.ChildNodes)) {
        if ($child.NodeType -ne [Xml.XmlNodeType]::Element) { continue }
        if (-not $Member -and $child.Name -eq 'Members') { continue }
        if ($child.GetAttribute('FrameworkAlternate') -and $child.GetAttribute('FrameworkAlternate') -ne $CanonicalKey) {
            [void]$Node.RemoveChild($child)
            continue
        }
        Remove-Alternates $child $true $CanonicalKey
    }
}

function Remove-InternalMetadata([Xml.XmlNode] $Node, [bool] $SkipMembers = $false) {
    $changed = $false
    if ($Node -is [Xml.XmlElement]) {
        foreach ($name in @('FrameworkAlternate', 'FrameworkOnly', 'Index')) {
            if ($Node.HasAttribute($name)) { [void]$Node.RemoveAttribute($name); $changed = $true }
        }
    }
    foreach ($child in @($Node.ChildNodes)) {
        if ($child.NodeType -ne [Xml.XmlNodeType]::Element) { continue }
        if ($SkipMembers -and $child.Name -eq 'Members') { continue }
        if ($child.Name -in @('FrameworkAlternate', 'FrameworkOnly')) { [void]$Node.RemoveChild($child); $changed = $true }
        elseif (Remove-InternalMetadata $child $false) { $changed = $true }
    }
    $changed
}

function Sort-Signatures([Xml.XmlElement] $Node, [bool] $Member) {
    $name = if ($Member) { 'MemberSignature' } else { 'TypeSignature' }
    $signatures = @($Node.SelectNodes($name))
    if ($signatures.Count -lt 2) { return }
    $anchor = @($Node.ChildNodes | Where-Object NodeType -eq ([Xml.XmlNodeType]::Element) | Where-Object Name -ne $name)[0]
    foreach ($signature in $signatures) {
        [void]$Node.RemoveChild($signature)
    }
    foreach ($signature in @($signatures | Sort-Object {
        switch ($_.GetAttribute('Language')) {
            'C#' { 0 }
            'ILAsm' { 1 }
            'DocId' { 2 }
            default { 3 }
        }
    })) {
        [void]$Node.InsertBefore($signature, $anchor)
    }
}

function Format-ElementChildren([Xml.XmlElement] $Node) {
    foreach ($child in @($Node.ChildNodes | Where-Object NodeType -eq ([Xml.XmlNodeType]::Element))) {
        if ($child.Name -ne 'Docs') {
            Format-ElementChildren $child
        }
    }
    if (@($Node.ChildNodes | Where-Object {
        $_.NodeType -eq [Xml.XmlNodeType]::CData -or
        ($_.NodeType -eq [Xml.XmlNodeType]::Text -and -not [string]::IsNullOrWhiteSpace($_.Value))
    }).Count -gt 0) {
        return
    }
    $children = @($Node.ChildNodes | Where-Object NodeType -eq ([Xml.XmlNodeType]::Element))
    if ($children.Count -eq 0) { return }
    foreach ($whitespace in @($Node.ChildNodes | Where-Object {
        $_.NodeType -eq [Xml.XmlNodeType]::Whitespace -or
        ($_.NodeType -eq [Xml.XmlNodeType]::Text -and [string]::IsNullOrWhiteSpace($_.Value))
    })) {
        [void]$Node.RemoveChild($whitespace)
    }
    $depth = 0
    for ($parent = $Node.ParentNode; $parent -is [Xml.XmlElement]; $parent = $parent.ParentNode) {
        $depth++
    }
    foreach ($child in $children) {
        [void]$Node.InsertBefore($Node.OwnerDocument.CreateWhitespace("`n" + ('  ' * ($depth + 1))), $child)
    }
    [void]$Node.AppendChild($Node.OwnerDocument.CreateWhitespace("`n" + ('  ' * $depth)))
}

function Process-Node([Xml.XmlElement] $Node, [object[]] $Group, [string] $Id, [bool] $Member) {
    $owners = Get-Owners $Group $Id $Member
    $canonical = Get-CanonicalOwner $owners $Id
    if ($owners.Count -eq 1) {
        if ($Group[0].Group -eq 'apple' -and $Group.Count -eq 2) {
            $other = @($Group | Where-Object { $_.Key -ne $canonical.Key })[0]
            Add-Note $Node "This API is available in the $($canonical.Label) but not in the $($other.Label)."
        } else { Add-Note $Node "This API is available only in the $($canonical.Label)." }
        [void](Remove-InternalMetadata $Node (-not $Member))
        Sort-Signatures $Node $Member
        return
    }
    $signatures = @($owners | ForEach-Object { [PSCustomObject]@{ Owner = $_; Value = Get-CSharpSignature $Node $Member $_ } })
    if (@($signatures.Value | Sort-Object -Unique).Count -gt 1) {
        $parts = @($signatures | ForEach-Object { "$($_.Owner.ShortLabel): $($_.Value)" })
        Add-Note $Node "Platform signature: $($parts -join '; ') Displayed signature: $($canonical.ShortLabel)."
    } elseif (@(Get-ScopedElements $Node $Member "*[@FrameworkAlternate]").Count -gt 0) {
        Add-Note $Node "Platform metadata differs between variants. Displayed metadata: $($canonical.ShortLabel)."
    }
    Remove-Alternates $Node $Member $canonical.Key
    [void](Remove-InternalMetadata $Node (-not $Member))
    Sort-Signatures $Node $Member
}

function Add-SortedChild([Xml.XmlElement] $Parent, [Xml.XmlElement] $Child, [string] $Path, [scriptblock] $Key) {
    $document = $Parent.OwnerDocument
    $copy = $document.ImportNode($Child, $true)
    $value = & $Key $Child
    $depth = 0
    for ($node = $Parent.ParentNode; $node -is [Xml.XmlElement]; $node = $node.ParentNode) {
        $depth++
    }
    $whitespace = $document.CreateWhitespace("`n" + ('  ' * ($depth + 1)))
    foreach ($existing in @($Parent.SelectNodes($Path))) {
        if ([StringComparer]::OrdinalIgnoreCase.Compare($value, (& $Key $existing)) -lt 0) {
            [void]$Parent.InsertBefore($copy, $existing)
            [void]$Parent.InsertBefore($whitespace, $existing)
            return
        }
    }
    if ($Parent.LastChild -is [Xml.XmlWhitespace]) {
        [void]$Parent.InsertBefore($whitespace, $Parent.LastChild)
        [void]$Parent.InsertBefore($copy, $Parent.LastChild)
    } else {
        [void]$Parent.AppendChild($whitespace)
        [void]$Parent.AppendChild($copy)
    }
}

function Merge-FrameworkIndex([Xml.XmlDocument] $Public, [Xml.XmlDocument] $Internal) {
    $framework = $Public.DocumentElement
    foreach ($assembly in @($Internal.SelectNodes('/Framework/Assemblies/Assembly'))) {
        $name = $assembly.GetAttribute('Name'); $version = $assembly.GetAttribute('Version')
        if (@($framework.SelectNodes("Assemblies/Assembly[@Name='$name' and @Version='$version']")).Count -eq 0) { Add-SortedChild ($framework.SelectSingleNode('Assemblies')) $assembly 'Assembly' { param($n) "$($n.GetAttribute('Name'))|$($n.GetAttribute('Version'))" } }
    }
    foreach ($sourceNamespace in @($Internal.SelectNodes('/Framework/Namespace'))) {
        $targetNamespace = $framework.SelectSingleNode("Namespace[@Name='$($sourceNamespace.GetAttribute('Name'))']")
        if ($null -eq $targetNamespace) { Add-SortedChild $framework $sourceNamespace 'Namespace' { param($n) $n.GetAttribute('Name') }; continue }
        foreach ($sourceType in @($sourceNamespace.SelectNodes('Type'))) {
            $targetType = $targetNamespace.SelectSingleNode("Type[@Id='$($sourceType.GetAttribute('Id'))']")
            if ($null -eq $targetType) { Add-SortedChild $targetNamespace $sourceType 'Type' { param($n) $n.GetAttribute('Id') }; continue }
            foreach ($member in @($sourceType.SelectNodes('Member'))) { if (@($targetType.SelectNodes("Member[@Id='$($member.GetAttribute('Id'))']")).Count -eq 0) { Add-SortedChild $targetType $member 'Member' { param($n) $n.GetAttribute('Id') } } }
        }
    }
}

function Assert-FrameworkIndexUnion([Xml.XmlDocument] $Public, [object[]] $Variants) {
    $types = @{}
    foreach ($type in @($Public.SelectNodes('/Framework/Namespace/Type'))) {
        $members = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($member in @($type.SelectNodes('Member'))) { [void]$members.Add($member.GetAttribute('Id')) }
        $types[$type.GetAttribute('Id')] = $members
    }
    foreach ($variant in $Variants) {
        foreach ($typeId in $variant.Presence.Types.Keys) {
            if (-not $types.ContainsKey($typeId)) { throw "Public FrameworksIndex omitted type '$typeId' from '$($variant.Key)'." }
            foreach ($memberId in $variant.Presence.Types[$typeId]) {
                if (-not $types[$typeId].Contains($memberId)) { throw "Public FrameworksIndex omitted member '$memberId' from '$($variant.Key)'." }
            }
        }
    }
}

foreach ($variant in $Variants) { $variant | Add-Member -NotePropertyName Presence -NotePropertyValue (Get-Presence (Join-Path $StagingRoot "FrameworksIndex/$($variant.Key).xml")) }
$types = Get-TypeDocuments $StagingRoot
foreach ($group in @($Variants | Group-Object Group)) {
    $variantsInGroup = @($group.Group); $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($variant in $variantsInGroup) { foreach ($id in $variant.Presence.Types.Keys) { [void]$ids.Add($id) } }
    foreach ($typeId in @($ids | Sort-Object)) {
        if (-not $types.ContainsKey($typeId)) { throw "mdoc structural union omitted type '$typeId'." }
        $type = $types[$typeId].Node; Process-Node $type $variantsInGroup $typeId $false; $types[$typeId].Changed = $true
        $members = @{}
        foreach ($member in @($type.SelectNodes('Members/Member'))) { $id = Get-DocId $member $true; if ($members.ContainsKey($id)) { throw "Ambiguous public member '$id'." }; $members[$id] = $member }
        $memberIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($variant in $variantsInGroup) { if ($variant.Presence.Types.ContainsKey($typeId)) { foreach ($id in $variant.Presence.Types[$typeId]) { [void]$memberIds.Add($id) } } }
        foreach ($id in @($memberIds | Sort-Object)) { if (-not $members.ContainsKey($id)) { throw "mdoc structural union omitted member '$id'." }; Process-Node $members[$id] $variantsInGroup $id $true }
    }
}
foreach ($entry in $types.Values) {
    if ((Remove-InternalMetadata $entry.Document) -or $entry.Changed) {
        Format-ElementChildren $entry.Node
        $entry.Document.Save($entry.File)
    }
}

$publicIndexPath = Join-Path $StagingRoot 'FrameworksIndex/skiasharp-views.xml'
$publicIndex = [Xml.XmlDocument]::new(); $publicIndex.PreserveWhitespace = $true; $publicIndex.Load($publicIndexPath)
foreach ($variant in $Variants) { Merge-FrameworkIndex $publicIndex $variant.Presence.Document; Remove-Item -LiteralPath (Join-Path $StagingRoot "FrameworksIndex/$($variant.Key).xml") -Force }
Assert-FrameworkIndexUnion $publicIndex $Variants
[void](Remove-InternalMetadata $publicIndex)
$publicIndex.Save($publicIndexPath)

$indexPath = Join-Path $StagingRoot 'index.xml'; $index = [Xml.XmlDocument]::new(); $index.PreserveWhitespace = $true; $index.Load($indexPath)
$assemblies = $index.SelectSingleNode('/Overview/Assemblies')
foreach ($name in @('SkiaSharp.Views.Gtk3', 'SkiaSharp.Views.Gtk4', 'SkiaSharp.Views.iOS')) {
    $node = $assemblies.SelectSingleNode("Assembly[@Name='$name']"); if ($null -eq $node) { throw "Missing assembly overview '$name'." }
    $whitespace = $node.PreviousSibling
    [void]$assemblies.RemoveChild($node)
    if ($whitespace -is [Xml.XmlWhitespace]) { [void]$assemblies.RemoveChild($whitespace) }
    Add-SortedChild $assemblies $node "Assembly[starts-with(@Name, 'SkiaSharp.Views.')]" { param($n) $n.GetAttribute('Name') }
}
$ios = $assemblies.SelectSingleNode("Assembly[@Name='SkiaSharp.Views.iOS']")
foreach ($attribute in @($ios.SelectNodes('Attributes/Attribute') | Where-Object { $_.InnerText -match 'System\.Runtime\.Versioning\.(SupportedOSPlatform|TargetPlatform)\("MacCatalyst' })) {
    $whitespace = $attribute.PreviousSibling
    [void]$attribute.ParentNode.RemoveChild($attribute)
    if ($whitespace -is [Xml.XmlWhitespace]) { [void]$whitespace.ParentNode.RemoveChild($whitespace) }
}
$attributes = $ios.SelectSingleNode('Attributes')
$publicKey = $ios.SelectSingleNode('Attributes/following-sibling::AssemblyPublicKey[1]')
if ($null -ne $publicKey) {
    $whitespace = $publicKey.PreviousSibling
    [void]$ios.RemoveChild($publicKey)
    if ($whitespace -is [Xml.XmlWhitespace]) { [void]$ios.RemoveChild($whitespace) }
    [void]$ios.InsertBefore($publicKey, $attributes)
    [void]$ios.InsertBefore($index.CreateWhitespace("`n      "), $attributes)
}
[void](Remove-InternalMetadata $index)
$extensions = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($extension in @($index.SelectNodes('/Overview/ExtensionMethods/ExtensionMethod'))) { $member = $extension.SelectSingleNode('Member'); if ($null -eq $member -or -not $extensions.Add((Get-DocId $member $true))) { throw 'Duplicate public extension DocId.' } }
$index.Save($indexPath)

foreach ($file in Get-ChildItem -LiteralPath $StagingRoot -Filter '*.xml' -File -Recurse) {
    $document = [Xml.XmlDocument]::new(); $document.PreserveWhitespace = $true; $document.Load($file.FullName)
    if (Remove-InternalMetadata $document) {
        $document.Save($file.FullName)
    }
    foreach ($returnValue in @($document.SelectNodes('//ReturnValue'))) { if ($null -eq $returnValue.SelectSingleNode('*')) { throw "Empty ReturnValue in '$($file.FullName)'." } }
    $text = Get-Content -LiteralPath $file.FullName -Raw
    foreach ($variant in $Variants) { if ($text.Contains($variant.Key)) { throw "Internal framework key '$($variant.Key)' leaked into '$($file.FullName)'." } }
}
