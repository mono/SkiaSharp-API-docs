[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'ApiDocs.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'ApiDocs.Normalization.psm1') -Force -DisableNameChecking
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'ApiDocs.Completeness.psm1') -Force -DisableNameChecking

function Assert-Equal([object] $Actual, [object] $Expected, [string] $Message) {
    if ($Actual -cne $Expected) {
        throw "$Message Expected '$Expected'; got '$Actual'."
    }
}

$workspace = Join-Path $PSScriptRoot ".api-docs-normalization-$([Guid]::NewGuid())"
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

    try {
        [void](Import-CompilerXmlDocumentation $workspace @($compilerPath, $laterCompilerPath))
        throw 'Conflicting exact DocId documentation was accepted without manifest precedence.'
    }
    catch {
        if ($_.Exception.Message -notmatch 'conflicting content') {
            throw
        }
    }
    $documentationInputs = @(
        [PSCustomObject]@{ Order = 0; Path = $compilerPath; PackageId = 'Example'; Asset = 'lib/net10.0/Example.dll' }
        [PSCustomObject]@{ Order = 1; Path = $laterCompilerPath; PackageId = 'Example.Later'; Asset = 'lib/net10.0/Example.dll' }
    )
    $precedence = @([PSCustomObject]@{
        docId = 'M:Example.Outer.Inner.Use(Example.Outer.Inner)'
        packageId = 'Example.Later'
        asset = 'lib/net10.0/Example.dll'
    })
    $sidecarPrecedence = @(Get-CompilerXmlSidecarPrecedence $documentationInputs @())
    Assert-Equal $sidecarPrecedence.Count 1 'Compiler XML sidecar did not record the conflicting exact DocId.'
    Assert-Equal $sidecarPrecedence[0].docId 'M:Example.Outer.Inner.Use(Example.Outer.Inner)' `
        'Compiler XML sidecar selected an unexpected conflicting DocId.'
    Assert-Equal $sidecarPrecedence[0].packageId 'Example' `
        'Compiler XML sidecar did not preserve the first ordered exact source.'
    $imported = @(Import-CompilerXmlDocumentation $workspace $documentationInputs $precedence)
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
    [void](Import-CompilerXmlDocumentation $workspace $documentationInputs $precedence)
    [xml] $secondResult = Get-Content -Raw -Path $ecmaPath
    Assert-Equal $secondResult.SelectSingleNode('/Type/Members/Member[1]/Docs/remarks/format').InnerText $markdown `
        'Compiler XML import was not idempotent.'
    Assert-Equal $result.SelectSingleNode('/Type/Members/Member[2]/Docs/summary').InnerText 'Later framework prose.' `
        'Manifest precedence did not select the declared compiler XML source.'
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

$completenessWorkspace = Join-Path $PSScriptRoot ".api-docs-completeness-$([Guid]::NewGuid())"
New-Item -ItemType Directory -Force -Path $completenessWorkspace | Out-Null
try {
    $compilerPath = Join-Path $completenessWorkspace 'Example.xml'
    $ecmaPath = Join-Path $completenessWorkspace 'ExampleType.xml'
    $reportPath = Join-Path $completenessWorkspace 'completeness.json'
        $fixtureAssembly = Join-Path $completenessWorkspace 'Fixture.dll'
        Add-Type -OutputAssembly $fixtureAssembly -TypeDefinition @'
namespace Example {
    public interface IComplete { }
}
'@
    @'
<doc><members>
  <member name="T:Example.IComplete"><summary>A completely documented public interface.</summary></member>
</members></doc>
'@ | Set-Content -NoNewline -Path $compilerPath
    @'
    <Type Name="IComplete" FullName="Example.IComplete">
      <TypeSignature Language="DocId" Value="T:Example.IComplete" />
      <Docs><summary>A completely documented public interface.</summary></Docs>
  <Members />
</Type>
'@ | Set-Content -NoNewline -Path $ecmaPath
    $documentationInputs = @([PSCustomObject]@{
        Path = $compilerPath
        PackageId = 'Example'
        Asset = 'ref/net10.0/Example.dll'
    })
    $selectedAssets = @([PSCustomObject]@{
        PackageId = 'Example'
        Asset = 'ref/net10.0/Example.dll'
        Moniker = 'example'
    })
    $completenessResult = Assert-ApiDocsCompleteness `
        -OutputRoot $completenessWorkspace `
        -DocumentationPaths $documentationInputs `
        -AssemblyPaths @($fixtureAssembly) `
        -SelectedAssets $selectedAssets `
        -ImportedDocIds @('T:Example.IComplete') `
        -FilteredDocIds @() `
        -Canonicalizations @() `
        -ReportPath $reportPath
    Assert-Equal $completenessResult.status 'passed' 'Completeness gate rejected an exactly mapped public API.'
    $report = Get-Content -Raw -LiteralPath $reportPath | ConvertFrom-Json -Depth 32
    Assert-Equal $report.status 'passed' 'Completeness gate did not write its passing JSON report.'

    $missingSidecarAssembly = Join-Path $completenessWorkspace 'MissingSidecar.dll'
    Add-Type -OutputAssembly $missingSidecarAssembly -TypeDefinition @'
namespace Example {
    public interface IMissingSidecar {
        void Required();
    }
}
'@
    try {
        [void](Assert-ApiDocsCompleteness `
            -OutputRoot $completenessWorkspace `
            -DocumentationPaths $documentationInputs `
            -AssemblyPaths @($fixtureAssembly, $missingSidecarAssembly) `
            -SelectedAssets $selectedAssets `
            -ImportedDocIds @('T:Example.IComplete') `
            -FilteredDocIds @() `
            -Canonicalizations @() `
            -ReportPath $reportPath)
        throw 'Completeness gate accepted a public metadata API missing from compiler XML.'
    }
    catch {
        if ($_.Exception.Message -notmatch 'completeness validation failed') {
            throw
        }
    }
    $report = Get-Content -Raw -LiteralPath $reportPath | ConvertFrom-Json -Depth 32
    Assert-Equal $report.publicSelectedApi.missingCompilerXml[0].docId 'M:Example.IMissingSidecar.Required' `
        'Completeness gate did not identify the public member missing from compiler XML.'

    $syntaxAssembly = Join-Path $completenessWorkspace 'Syntax.dll'
    Add-Type -OutputAssembly $syntaxAssembly -TypeDefinition @'
namespace Example {
    public delegate int Callback(string value);
    public class Outer<T> {
        public class Inner { }
        protected void Protected<TMethod>(ref int value, string[] names) { }
        public static Outer<T> operator +(Outer<T> left, Outer<T> right) => left;
        public static implicit operator string(Outer<T> value) => "";
    }
}
'@
    $syntaxDocIds = (Get-SelectedAssemblyPublicDocIds @($syntaxAssembly)).ByDocId
    foreach ($docId in @(
        'T:Example.Callback',
        'T:Example.Outer`1',
        'T:Example.Outer`1.Inner',
        'M:Example.Outer`1.Protected``1(System.Int32@,System.String[])',
        'M:Example.Outer`1.op_Addition(Example.Outer{`0},Example.Outer{`0})',
        'M:Example.Outer`1.op_Implicit(Example.Outer{`0})~System.String'
    )) {
        if (-not $syntaxDocIds.ContainsKey($docId)) {
            throw "Exact metadata DocId formatter did not emit '$docId'."
        }
    }
    if (@($syntaxDocIds.Keys | Where-Object { $_ -like 'M:Example.Callback.*' }).Count -ne 0) {
        throw 'Compiler-generated delegate invocation members must not require compiler XML documentation.'
    }

    @'
<doc><members>
  <member name="T:Example.IComplete"><summary>A completely documented public interface.</summary></member>
  <member name="M:Example.Unmapped"><summary>Unmapped compiler XML.</summary></member>
</members></doc>
'@ | Set-Content -NoNewline -Path $compilerPath
    [void](Assert-ApiDocsCompleteness `
        -OutputRoot $completenessWorkspace `
        -DocumentationPaths $documentationInputs `
        -AssemblyPaths @($fixtureAssembly) `
        -SelectedAssets $selectedAssets `
        -ImportedDocIds @('T:Example.IComplete') `
        -FilteredDocIds @() `
        -Canonicalizations @() `
        -ReportPath $reportPath)
    $report = Get-Content -Raw -LiteralPath $reportPath | ConvertFrom-Json -Depth 32
    Assert-Equal $report.status 'passed' 'Implementation-only compiler XML must not expand the reference surface.'
    Assert-Equal $report.compilerXml.absentFromEcma[0].classification 'implementation-only-sidecar' `
        'Compiler XML DocId absent from the reference surface was not reported as implementation-only.'

    @'
<doc><members>
  <member name="T:Example.IComplete"><summary>A completely documented public interface.</summary></member>
</members></doc>
'@ | Set-Content -NoNewline -Path $compilerPath
    @'
<Type Name="IComplete" FullName="Example.IComplete">
  <TypeSignature Language="DocId" Value="T:Example.IComplete" />
  <Docs><summary>To be added.</summary></Docs>
  <Members />
</Type>
'@ | Set-Content -NoNewline -Path $ecmaPath
    try {
        [void](Assert-ApiDocsCompleteness `
            -OutputRoot $completenessWorkspace `
            -DocumentationPaths $documentationInputs `
            -AssemblyPaths @($fixtureAssembly) `
            -SelectedAssets $selectedAssets `
            -ImportedDocIds @('T:Example.IComplete') `
            -FilteredDocIds @() `
            -Canonicalizations @() `
            -ReportPath $reportPath)
        throw 'Completeness gate accepted placeholder ECMA documentation.'
    }
    catch {
        if ($_.Exception.Message -notmatch 'completeness validation failed') {
            throw
        }
    }
}
finally {
    Remove-Item -Recurse -Force $completenessWorkspace -ErrorAction Ignore
}

$gtkFrameworkName = Get-ApiDocsFrameworkName 'skiasharp-views' 'SkiaSharp.Views.Gtk3' 'lib/net10.0/SkiaSharp.Views.Gtk3.dll'
Assert-Equal $gtkFrameworkName 'skiasharp-views-skiasharp-views-gtk3-lib-net10-0' `
    'GTK framework name was not derived from its public moniker, package, and asset kind/TFM.'

$frameworkWorkspace = Join-Path $PSScriptRoot ".api-docs-frameworks-$([Guid]::NewGuid())"
New-Item -ItemType Directory -Force -Path $frameworkWorkspace | Out-Null
try {
    $frameworkAssets = @(
        [PSCustomObject]@{ FrameworkName = $gtkFrameworkName; FrameworkSource = $gtkFrameworkName }
    )
    $frameworkConfiguration = Write-MdocFrameworkConfiguration $frameworkWorkspace $frameworkAssets
    [xml] $frameworks = Get-Content -Raw -LiteralPath $frameworkConfiguration
    Assert-Equal $frameworks.SelectNodes('/Frameworks/Framework').Count 1 'Framework configuration omitted a selected asset.'
    Assert-Equal $frameworks.SelectNodes('/Frameworks/Framework/import').Count 0 'Structure-only mdoc configuration must not import prose.'
    foreach ($framework in $frameworks.SelectNodes('/Frameworks/Framework')) {
        Assert-Equal ([IO.Path]::GetFileName($framework.GetAttribute('Source'))) $framework.GetAttribute('Source') `
            'Framework source is not relative to an immediate directory.'
    }
}
finally {
    Remove-Item -Recurse -Force $frameworkWorkspace -ErrorAction Ignore
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
$manifest = Read-ApiDocsManifest (Join-Path (Split-Path -Parent $PSScriptRoot) 'api-docs-packages.json')
$uno = @($manifest.packages | Where-Object { $_.id -eq 'SkiaSharp.Views.Uno.WinUI' })
Assert-Equal $uno.Count 1 'Uno must have an explicit package classification.'
Assert-Equal $uno[0].classification 'exclude' 'Uno must be explicitly deferred from this generation.'
Assert-Equal $uno[0].preserveOutputPaths[0] 'SkiaSharp.Views.Windows' `
    'Uno deferred output must have an explicit scoped-promotion preservation path.'
foreach ($classification in $manifest.packages) {
    if ([string]::IsNullOrWhiteSpace($classification.reason)) {
        throw "Package '$($classification.id)' is missing a classification reason."
    }
    if ($classification.classification -ne 'exclude' -and @($classification.assetRoots).Count -eq 0) {
        throw "Package '$($classification.id)' must declare asset roots."
    }
}
Assert-Equal (Test-ShouldExcludeUndocumentedJavaPeerInfrastructureMember $true 'Java.Interop.IJavaPeerable.UnregisterFromRuntime' $false) $true `
    'Undocumented Java peer infrastructure member was not excluded.'
Assert-Equal (Test-ShouldExcludeUndocumentedJavaPeerInfrastructureMember $true 'Java.Interop.IJavaPeerable.UnregisterFromRuntime' $true) $false `
    'Documented Java peer infrastructure member was excluded.'
Assert-Equal (Test-ShouldExcludeUndocumentedJavaPeerInfrastructureMember $true 'Example.IPrivateContract.Run' $false) $false `
    'Ordinary private explicit-interface member was excluded.'
Assert-Equal (Test-ShouldExcludeUndocumentedJavaPeerInfrastructureMember $false 'Java.Interop.IJavaPeerable.UnregisterFromRuntime' $false) $false `
    'Public authored member was excluded.'
$javaFilterWorkspace = Join-Path $PSScriptRoot ".api-docs-java-filter-$([Guid]::NewGuid())"
New-Item -ItemType Directory -Force -Path $javaFilterWorkspace | Out-Null
try {
    $javaAssemblyPath = Join-Path $javaFilterWorkspace 'JavaPeerHost.dll'
    Add-Type -OutputAssembly $javaAssemblyPath -TypeDefinition @'
namespace Java.Interop {
    public interface IJavaPeerable {
        void UnregisterFromRuntime(string value);
    }
}
public class JavaPeerHost : Java.Interop.IJavaPeerable {
    void Java.Interop.IJavaPeerable.UnregisterFromRuntime(string value) { }
}
'@
    $javaEcmaPath = Join-Path $javaFilterWorkspace 'JavaPeerHost.xml'
    $javaDocId = 'M:JavaPeerHost.Java#Interop#IJavaPeerable#UnregisterFromRuntime(System.String)'
    @"
<Type Name="JavaPeerHost" FullName="JavaPeerHost">
  <TypeSignature Language="DocId" Value="T:JavaPeerHost" />
  <Docs><summary>Host.</summary></Docs>
  <Members>
    <Member><MemberSignature Language="DocId" Value="$javaDocId" /><Docs><summary>To be added.</summary></Docs></Member>
    <Member><MemberSignature Language="DocId" Value="M:JavaPeerHost.Other" /><Docs><summary>Other.</summary></Docs></Member>
  </Members>
</Type>
"@ | Set-Content -NoNewline -Path $javaEcmaPath
    $removed = @(Remove-UndocumentedJavaPeerInfrastructureMembers $javaFilterWorkspace @($javaAssemblyPath) @())
    Assert-Equal $removed.Count 1 'Java peer filter did not remove the one exact private infrastructure member.'
    Assert-Equal $removed[0] $javaDocId 'Java peer filter removed an unexpected DocId.'
    [xml] $javaResult = Get-Content -Raw -LiteralPath $javaEcmaPath
    Assert-Equal $javaResult.SelectNodes('/Type/Members/Member').Count 1 'Java peer filter removed more than its exact target.'

    @"
<Type Name="JavaPeerHost" FullName="JavaPeerHost">
  <TypeSignature Language="DocId" Value="T:JavaPeerHost" />
  <Docs><summary>Host.</summary></Docs>
  <Members>
    <Member><MemberSignature Language="DocId" Value="$javaDocId" /><Docs><summary>Documented infrastructure member.</summary></Docs></Member>
  </Members>
</Type>
"@ | Set-Content -NoNewline -Path $javaEcmaPath
    $removed = @(Remove-UndocumentedJavaPeerInfrastructureMembers $javaFilterWorkspace @($javaAssemblyPath) @($javaDocId))
    Assert-Equal $removed.Count 0 'Java peer filter removed an exactly documented member.'
}
finally {
    Remove-Item -Recurse -Force $javaFilterWorkspace -ErrorAction Ignore
}
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
