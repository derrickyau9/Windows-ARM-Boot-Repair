param([switch]$SkipTests)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$repo = Split-Path -Parent $PSScriptRoot
$version = '0.1.0'
$build = Join-Path $repo '.build'
$package = Join-Path $repo ('dist\Windows-ARM-Boot-Repair-' + $version)
if ($env:OS -ne 'Windows_NT') { throw 'Build on Windows with .NET Framework 4 and Windows PowerShell 5.1 installed.' }
foreach ($directory in @($build,$package)) {
    $full = [IO.Path]::GetFullPath($directory)
    if (!$full.StartsWith(([IO.Path]::GetFullPath($repo).TrimEnd('\') + '\'),[StringComparison]::OrdinalIgnoreCase)) { throw 'Build path escaped repository.' }
    $node = $full
    while ($node) {
        if ((Test-Path -LiteralPath $node) -and ((Get-Item -LiteralPath $node -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Build output cannot traverse a link or junction.' }
        $next = Split-Path -Parent $node
        if ($next -eq $node) { break }
        $node = $next
    }
    New-Item -ItemType Directory -Path $full -Force | Out-Null
}
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (!(Test-Path -LiteralPath $compiler)) { $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (!(Test-Path -LiteralPath $compiler)) { throw '.NET Framework 4 C# compiler was not found.' }
$source = Join-Path $repo 'src\FirmwareBoot\FirmwareBoot.cs'
$dll = Join-Path $package 'FirmwareBoot.dll'
& $compiler /nologo /target:library /platform:anycpu /optimize+ "/out:$dll" $source
if ($LASTEXITCODE -ne 0) { throw 'Firmware helper compilation failed.' }
(Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash | Set-Content -LiteralPath (Join-Path $package 'FirmwareBoot.sha256') -Encoding ASCII
foreach ($name in @('Repair-ArmBoot.ps1','Run-Repair.cmd','Run-Automatic.cmd','Diagnose.cmd')) {
    Copy-Item -LiteralPath (Join-Path $repo ('src\' + $name)) -Destination (Join-Path $package $name) -Force
}
New-Item -ItemType Directory -Path (Join-Path $package 'tools') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Install-ToPe.ps1') -Destination (Join-Path $package 'tools\Install-ToPe.ps1') -Force
foreach ($name in @('README.md','LICENSE','CHANGELOG.md')) {
    if (Test-Path -LiteralPath (Join-Path $repo $name)) { Copy-Item -LiteralPath (Join-Path $repo $name) -Destination (Join-Path $package $name) -Force }
}
if (Test-Path -LiteralPath (Join-Path $repo 'docs')) { Copy-Item -LiteralPath (Join-Path $repo 'docs') -Destination $package -Recurse -Force }
if (!$SkipTests) {
    $testExe = Join-Path $build 'FirmwareBoot.Tests.exe'
    & $compiler /nologo /target:exe /platform:anycpu /optimize+ "/out:$testExe" $source (Join-Path $repo 'tests\FirmwareBoot.Tests.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Firmware test compilation failed.' }
    & $testExe (Join-Path $build ('firmware-fixtures-' + [guid]::NewGuid().ToString('N')))
    if ($LASTEXITCODE -ne 0) { throw 'Firmware mock tests failed.' }
    $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    foreach ($name in @('Test-Runtime.ps1','Test-Packaging.ps1')) {
        $test = Join-Path $repo ('tests\' + $name)
        if (!(Test-Path -LiteralPath $test)) { throw ('Required test is missing: ' + $name) }
        & $powershell -NoProfile -ExecutionPolicy Bypass -File $test
        if ($LASTEXITCODE -ne 0) { throw ($name + ' failed.') }
    }
}
Write-Host ('Build ready: ' + $package)
Write-Host 'Firmware tests use an in-memory backend. This build does not access host disks or firmware.'
