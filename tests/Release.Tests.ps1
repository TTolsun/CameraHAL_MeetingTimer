# Exercise the files extracted from the release ZIPs using isolated settings.
param([string]$PackageDirectory = (Join-Path $PSScriptRoot '..\dist'))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('Meeting Timer ' + [guid]::NewGuid().ToString('N'))
$windows = Join-Path $testRoot 'Windows'
$extension = Join-Path $testRoot 'Chrome'
$oldExtension = $env:TIMER_EXTENSION_DIR

function Test-BatLaunch {
    $scriptPath = Join-Path $windows 'MeetingTimer.ps1'
    $process = $null
    try {
        $cmd = Start-Process -FilePath $env:ComSpec -ArgumentList '/d /c MeetingTimer.bat' -WorkingDirectory $windows -WindowStyle Hidden -PassThru
        if (-not $cmd.WaitForExit(8000)) { throw 'BAT launcher timed out.' }
        if ($cmd.ExitCode) { throw "BAT failed: $($cmd.ExitCode)" }
        $deadline = [datetime]::UtcNow.AddSeconds(25)
        do {
            if (-not $process) {
                $child = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object {
                    $_.CommandLine -and $_.CommandLine.IndexOf($scriptPath, [StringComparison]::OrdinalIgnoreCase) -ge 0
                } | Select-Object -First 1
                if ($child) { $process = Get-Process -Id $child.ProcessId }
            }
            if ($process) { $process.Refresh() }
            if ($process -and $process.MainWindowTitle.EndsWith(' · 발표자 1 · 회의 타이머')) { break }
            if ([datetime]::UtcNow -ge $deadline) { throw 'Packaged BAT did not show the timer window.' }
            Start-Sleep -Milliseconds 120
        } while ($true)
        if (-not $process.CloseMainWindow() -or -not $process.WaitForExit(8000)) { throw 'Packaged window did not close cleanly.' }
        $config = Get-Content -LiteralPath (Join-Path $windows 'config.json') -Encoding UTF8 -Raw | ConvertFrom-Json
        if ($config.Speakers -ne 6) { throw 'Packaged timer did not save its preferences.' }
    } finally {
        if ($process -and -not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(5000) }
        if ($process) { $process.Dispose() }
    }
}
try {
    if (-not $env:CHROME_FOR_TESTING) { throw 'Set CHROME_FOR_TESTING to the Chrome for Testing executable.' }
    [void][IO.Directory]::CreateDirectory($testRoot)
    foreach ($name in @('Windows','Chrome')) {
        $zip = Join-Path $PackageDirectory ("MeetingTimer-{0}.zip" -f $name)
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, (Join-Path $testRoot $name))
    }
    $entries = @(Get-ChildItem -LiteralPath $windows -Name | Sort-Object)
    if (($entries -join ',') -ne 'MeetingTimer.bat,MeetingTimer.ps1,TimeModel.ps1') { throw 'Unexpected Windows package contents.' }
    $manifest = Get-Content -LiteralPath (Join-Path $extension 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.name -ne '회의 타이머') { throw 'Unexpected extension display name.' }
    Test-BatLaunch
    Write-Host 'Extracted BAT launched, closed and saved its settings.'
    $env:TIMER_EXTENSION_DIR = $extension
    & node --test (Join-Path $PSScriptRoot 'chrome-ui.test.mjs')
    if ($LASTEXITCODE -ne 0) { throw 'Packaged extension UI test failed.' }
} finally {
    $env:TIMER_EXTENSION_DIR = $oldExtension
    if ([IO.Directory]::Exists($testRoot)) {
        $actual = (Resolve-Path -LiteralPath $testRoot).Path
        if ($actual -eq $testRoot -and [IO.Path]::GetDirectoryName($actual) -eq [IO.Path]::GetTempPath().TrimEnd('\')) {
            Remove-Item -LiteralPath $actual -Recurse -Force
        }
    }
}
