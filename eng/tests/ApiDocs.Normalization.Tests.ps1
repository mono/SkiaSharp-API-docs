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

Assert-Equal (Convert-MdocImportDocId 'C:Example.Outer+Inner(System.String)') `
    'M:Example.Outer.Inner.#ctor(System.String)' 'Constructor/nested DocId normalization failed.'
Assert-Equal (Convert-MdocImportDocId 'M:Example.Outer+Inner.Use(Example.Outer+Inner)') `
    'M:Example.Outer.Inner.Use(Example.Outer.Inner)' 'Nested parameter DocId normalization failed.'
Assert-Equal (Convert-MdocImportDocId 'T:Example.Type') 'T:Example.Type' 'Standard DocId changed unexpectedly.'
Assert-Equal (Test-ShouldExcludeExplicitInterfaceMember @($false, $false) $false) $true `
    'Private explicit-interface members must be excluded.'
Assert-Equal (Test-ShouldExcludeExplicitInterfaceMember @($false, $true) $false) $false `
    'Public explicit-interface members must be retained.'
Assert-Equal (Test-ShouldExcludeExplicitInterfaceMember @($false) $true) $false `
    'Private forwarding accessors must not hide a genuine public interface API.'
Assert-Equal (Test-ShouldExcludeGeneratedResourceConstructor '_Microsoft.Android.Resource.Designer.Resource') $true `
    'Synthetic resource-designer constructors must be excluded.'
Assert-Equal (Test-ShouldExcludeGeneratedResourceConstructor 'Example.Resource') $false `
    'Non-resource-designer constructors must be retained.'

$selected = Select-LatestMainTransportPackageVersion @(
    '0.0.0-branch.release.999',
    '0.0.0-branch.main.9',
    '0.0.0-branch.pull-request.1000',
    '0.0.0-branch.main.172',
    '0.0.0-branch.main.99'
)
Assert-Equal $selected '0.0.0-branch.main.172' 'Main package version selection failed.'
Assert-Equal (Resolve-DocsMediaPackageVersion $selected $null) $selected 'Media package did not follow _NuGets.'
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
