[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'ApiDocs.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'ApiDocs.Normalization.psm1') -Force -DisableNameChecking

function Assert-Equal([object] $Actual, [object] $Expected, [string] $Message) {
    if ($Actual -cne $Expected) {
        throw "$Message Expected '$Expected'; got '$Actual'."
    }
}

$workspace = Join-Path ([IO.Path]::GetTempPath()) "api-docs-normalization-$([Guid]::NewGuid())"
New-Item -ItemType Directory -Force -Path $workspace | Out-Null
try {
    $compilerPath = Join-Path $workspace 'Example.xml'
    $laterCompilerPath = Join-Path $workspace 'Example.Later.xml'
    $ecmaPath = Join-Path $workspace 'ExampleType.xml'
    @'
<doc><members>
  <member name="M:Example.Outer.Inner.#ctor(System.String)"><summary><![CDATA[Constructor <b>prose</b>.]]></summary><param name="value">Parameter prose.</param><remarks><see cref="T:Example.Outer.Inner" /><format type="text/markdown"><![CDATA[
    ## Example

    ```csharp
    if (ready) {
        Run();
    }
    ```]]></format></remarks></member>
  <member name="M:Example.Outer.Inner.Use(Example.Outer.Inner)"><summary>Nested type prose.</summary></member>
  <member name="M:Example.Case"><summary>Upper-case identity.</summary></member>
  <member name="M:Example.case"><summary>Lower-case identity.</summary></member>
</members></doc>
'@ | Set-Content -NoNewline -Path $compilerPath
    @'
<doc><members>
  <member name="M:Example.Outer.Inner.Use(Example.Outer.Inner)"><summary>Later framework prose.</summary></member>
</members></doc>
'@ | Set-Content -NoNewline -Path $laterCompilerPath
    @'
<Type Name="ExampleType" FullName="Example.Type">
  <TypeSignature Language="DocId" Value="T:Example.Type" />
  <Docs><summary>To be added.</summary></Docs>
  <Members>
    <Member><MemberSignature Language="DocId" Value="M:Example.Outer.Inner.#ctor(System.String)" /><Docs><summary>To be added.</summary></Docs></Member>
    <Member><MemberSignature Language="DocId" Value="M:Example.Outer.Inner.Use(Example.Outer.Inner)" /><Docs><summary>To be added.</summary></Docs></Member>
    <Member><MemberSignature Language="DocId" Value="M:Example.Unmatched" /><Docs><summary>To be added.</summary></Docs></Member>
    <Member><MemberSignature Language="DocId" Value="M:Example.Case" /><Docs><summary>To be added.</summary></Docs></Member>
    <Member><MemberSignature Language="DocId" Value="M:Example.case" /><Docs><summary>To be added.</summary></Docs></Member>
  </Members>
</Type>
'@ | Set-Content -NoNewline -Path $ecmaPath

    $imported = @(Import-CompilerXmlDocumentation $workspace @($compilerPath, $laterCompilerPath))
    Assert-Equal $imported.Count 4 'Exact DocId importer matched an unexpected number of APIs.'
    [xml] $result = Get-Content -Raw -Path $ecmaPath
    Assert-Equal $result.SelectSingleNode('/Type/Members/Member[1]/Docs/summary').InnerText 'Constructor <b>prose</b>.' `
        'Constructor compiler XML was not imported.'
    Assert-Equal $result.SelectSingleNode('/Type/Members/Member[1]/Docs').FirstChild.LocalName 'param' `
        'Compiler XML was not emitted in the established ECMA documentation order.'
    Assert-Equal $result.SelectSingleNode('/Type/Members/Member[1]/Docs/summary').FirstChild.NodeType ([System.Xml.XmlNodeType]::CDATA) `
        'Compiler XML CDATA content was not preserved.'
    Assert-Equal $result.SelectSingleNode('/Type/Members/Member[1]/Docs/remarks/see').GetAttribute('cref') 'T:Example.Outer.Inner' `
        'Compiler XML cref content was not preserved.'
    $markdown = $result.SelectSingleNode('/Type/Members/Member[1]/Docs/remarks/format').InnerText
    $expectedMarkdown = @'
## Example

```csharp
if (ready) {
    Run();
}
```
'@
    Assert-Equal $markdown ("`n" + $expectedMarkdown) `
        'Compiler XML markdown indentation was not normalized.'
    [void](Import-CompilerXmlDocumentation $workspace @($compilerPath, $laterCompilerPath))
    [xml] $secondResult = Get-Content -Raw -Path $ecmaPath
    Assert-Equal $secondResult.SelectSingleNode('/Type/Members/Member[1]/Docs/remarks/format').InnerText $markdown `
        'Compiler XML import was not idempotent.'
    Assert-Equal $result.SelectSingleNode('/Type/Members/Member[2]/Docs/summary').InnerText 'Later framework prose.' `
        'Later compiler XML must deterministically supersede an earlier exact DocId.'
    Assert-Equal $result.SelectSingleNode('/Type/Members/Member[3]/Docs/summary').InnerText 'To be added.' `
        'Unmatched DocId must not be imported by fuzzy matching.'
    Assert-Equal $result.SelectSingleNode('/Type/Members/Member[4]/Docs/summary').InnerText 'Upper-case identity.' `
        'Upper-case DocId was not matched ordinally.'
    Assert-Equal $result.SelectSingleNode('/Type/Members/Member[5]/Docs/summary').InnerText 'Lower-case identity.' `
        'Lower-case DocId was not matched ordinally.'
}
finally {
    Remove-Item -Recurse -Force $workspace -ErrorAction Ignore
}

$selected = Select-LatestMainTransportPackageVersion @(
    '0.0.0-branch.release.999',
    '0.0.0-branch.main.9',
    '0.0.0-branch.pull-request.1000',
    '0.0.0-branch.main.172',
    '0.0.0-branch.main.99'
)
Assert-Equal $selected '0.0.0-branch.main.172' 'Main package version selection failed.'
Assert-Equal (Resolve-DocsMediaPackageVersion $selected $null) $selected 'Media package did not follow _NuGets.'
Assert-Equal (Test-ShouldExcludeUndocumentedPrivateExplicitInterfaceMember $true $true $false) $true `
    'Undocumented private explicit-interface member was not excluded.'
Assert-Equal (Test-ShouldExcludeUndocumentedPrivateExplicitInterfaceMember $true $true $true) $false `
    'Documented private explicit-interface member was excluded.'
Assert-Equal (Test-ShouldExcludeUndocumentedPrivateExplicitInterfaceMember $false $false $false) $false `
    'Public authored member was excluded.'
try {
    [void](Resolve-DocsMediaPackageVersion $selected '0.0.0-branch.main.171')
    throw 'Mismatched _DocsMedia package version was accepted.'
}
catch {
    if ($_.Exception.Message -notmatch 'must exactly match') {
        throw
    }
}

Write-Host 'API docs normalization tests passed.'
