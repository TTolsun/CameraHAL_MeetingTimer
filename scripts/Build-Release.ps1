param([string]$OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist'))

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$destination = [IO.Directory]::CreateDirectory($OutputDirectory).FullName

function Write-Package([string]$name, [string]$root, [string[]]$files) {
    $path = Join-Path $destination $name
    $temp = Join-Path $destination ([guid]::NewGuid().ToString() + '.tmp')
    try {
        $archive = [IO.Compression.ZipFile]::Open($temp, 'Create')
        try {
            foreach ($file in $files) {
                [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                    $archive, (Join-Path $root $file), $file, 'Optimal')
            }
        } finally { $archive.Dispose() }
        Move-Item -LiteralPath $temp -Destination $path -Force
        Get-Item -LiteralPath $path
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

$repo = Split-Path -Parent $PSScriptRoot
Write-Package 'time-per-turn-Windows.zip' (Join-Path $repo 'windows') @('time-per-turn.bat', 'time-per-turn.ps1', 'TimeModel.ps1')
$extensionRoot = Join-Path $repo 'chrome-extension'
$files = @(Get-ChildItem -LiteralPath $extensionRoot -File -Recurse | ForEach-Object {
    $_.FullName.Substring($extensionRoot.Length + 1).Replace('\', '/')
})
Write-Package 'time-per-turn-Chrome.zip' $extensionRoot $files
