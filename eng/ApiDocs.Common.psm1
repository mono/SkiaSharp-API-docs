Set-StrictMode -Version Latest

function Get-NuGetPackageIdentity {
    param([Parameter(Mandatory)][string] $Path)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $nuspec = $archive.Entries | Where-Object { $_.FullName -like '*.nuspec' } | Select-Object -First 1
        if ($null -eq $nuspec) {
            throw "'$Path' does not contain a nuspec."
        }

        $reader = [IO.StreamReader]::new($nuspec.Open())
        try {
            [xml] $document = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }

        $metadata = $document.package.metadata
        return [PSCustomObject]@{
            Id = [string] $metadata.id
            Version = [string] $metadata.version
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Expand-NuGetPackage {
    param(
        [Parameter(Mandatory)][string] $PackagePath,
        [Parameter(Mandatory)][string] $DestinationRoot
    )

    $identity = Get-NuGetPackageIdentity $PackagePath
    $destination = Join-Path (Join-Path $DestinationRoot $identity.Id) $identity.Version
    Remove-Item -Recurse -Force $destination -ErrorAction Ignore
    New-Item -ItemType Directory -Force $destination | Out-Null
    Expand-Archive -LiteralPath $PackagePath -DestinationPath $destination -Force
    return $destination
}

function Get-NuGetPackageDependencies {
    param([Parameter(Mandatory)][string] $PackagePath)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)
    try {
        $nuspec = $archive.Entries | Where-Object { $_.FullName -like '*.nuspec' } | Select-Object -First 1
        $reader = [IO.StreamReader]::new($nuspec.Open())
        try {
            [xml] $document = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }

        return @($document.SelectNodes("//*[local-name()='dependency']") | ForEach-Object {
            [PSCustomObject]@{ Id = [string] $_.id; Version = [string] $_.version }
        })
    }
    finally {
        $archive.Dispose()
    }
}

function Expand-TransportPackages {
    param(
        [Parameter(Mandatory)][string] $TransportRoot,
        [Parameter(Mandatory)][string] $DestinationRoot
    )

    $packages = [Collections.Generic.List[string]]::new()
    New-Item -ItemType Directory -Force $DestinationRoot | Out-Null
    foreach ($container in @(Get-ChildItem -LiteralPath $TransportRoot -Filter '_NuGets.Dependencies.*.nupkg' -File -Recurse | Sort-Object FullName)) {
        $temporary = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
        try {
            Expand-Archive -LiteralPath $container.FullName -DestinationPath $temporary -Force
            foreach ($package in @(Get-ChildItem -LiteralPath (Join-Path $temporary 'tools') -Filter '*.nupkg' -File -ErrorAction Ignore)) {
                $identity = Get-NuGetPackageIdentity $package.FullName
                $destination = Join-Path $DestinationRoot "$($identity.Id).$($identity.Version).nupkg"
                Copy-Item -LiteralPath $package.FullName -Destination $destination -Force
                $packages.Add($destination)
            }
        }
        finally {
            Remove-Item -Recurse -Force $temporary -ErrorAction Ignore
        }
    }
    return @($packages)
}

Export-ModuleMember -Function Get-NuGetPackageIdentity, Expand-NuGetPackage, Get-NuGetPackageDependencies, Expand-TransportPackages
