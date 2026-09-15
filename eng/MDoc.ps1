<#
.SYNOPSIS
Downloads and runs the mdoc command used by the API documentation generator.

.DESCRIPTION
Stores mdoc 5.9.3 under artifacts/downloads/tools/mdoc. Invoke this script
directly to acquire the tool and run an mdoc command, or dot-source it and call
Invoke-MDoc after the tool has been acquired.

.EXAMPLE
./eng/MDoc.ps1 --version

Downloads mdoc if necessary and prints its version.
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $MDocArguments
)

Set-StrictMode -Version Latest

function Invoke-MDoc {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [string] $Version = '5.9.3',
        [string] $ToolsRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts/downloads/tools')
    )

    # Use mdoc's cross-platform net6 payload, never its .NET Framework payload.
    $toolRoot = Join-Path $ToolsRoot "mdoc/$Version"
    $mdoc = Join-Path $toolRoot 'tools/net6.0/mdoc.dll'
    if (-not (Test-Path -LiteralPath $mdoc -PathType Leaf)) {
        # Acquire the pinned mdoc package from the public engineering feed.
        New-Item -ItemType Directory -Force $ToolsRoot | Out-Null
        dotnet package download "mdoc@$Version" --source 'https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-public/nuget/v3/index.json' --output $ToolsRoot
        if ($LASTEXITCODE -ne 0) {
            throw "Downloading mdoc $Version failed."
        }
        if (-not (Test-Path -LiteralPath $mdoc -PathType Leaf)) {
            throw "mdoc $Version was downloaded but mdoc.dll was not found."
        }
    }

    # Forward the caller's arguments unchanged to the pinned tool.
    & dotnet $mdoc @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "mdoc exited with code $LASTEXITCODE."
    }
}

$forwardedArguments = if ($null -ne $MDocArguments -and $MDocArguments.Count -gt 0) {
    $MDocArguments
}
else {
    @($MyInvocation.UnboundArguments)
}
if (@($forwardedArguments).Count -gt 0) {
    Invoke-MDoc -Arguments $forwardedArguments
}
