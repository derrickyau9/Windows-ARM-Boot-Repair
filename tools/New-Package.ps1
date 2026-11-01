param([switch]$SkipBuild)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$repo = Split-Path -Parent $PSScriptRoot
if (!$SkipBuild) { & (Join-Path $PSScriptRoot 'Build.ps1') }
$version = '0.1.0'
$directory = Join-Path $repo ('dist\Windows-ARM-Boot-Repair-'+$version)
if (!(Test-Path -LiteralPath (Join-Path $directory 'FirmwareBoot.dll'))) { throw 'Run tools/Build.ps1 first.' }
$directory = (Get-Item -LiteralPath $directory).FullName.TrimEnd('\')
$directoryPrefix = $directory + '\'
# A strict payload allowlist prevents build fixtures or local diagnostic logs entering releases.
$allowed = @('Repair-ArmBoot.ps1','Run-Repair.cmd','Run-Automatic.cmd','Diagnose.cmd','FirmwareBoot.dll','FirmwareBoot.sha256','README.md','LICENSE','CHANGELOG.md')
$files = @(Get-ChildItem -LiteralPath $directory -Recurse -File -Force)
foreach ($file in $files) {
    if (!$file.FullName.StartsWith($directoryPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw ('Release file escaped the package directory: '+$file.FullName) }
    $relative = $file.FullName.Substring($directoryPrefix.Length)
    if ($relative -notin $allowed -and $relative -ne 'tools\Install-ToPe.ps1' -and $relative -notmatch '^docs\\[^\\]+\.md$') { throw ('Unexpected file in release directory: '+$relative) }
    if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Release files cannot be links.' }
}
$zip = Join-Path $repo ('dist\Windows-ARM-Boot-Repair-'+$version+'.zip')
Compress-Archive -LiteralPath $directory -DestinationPath $zip -CompressionLevel Optimal -Force
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
($hash+'  '+[IO.Path]::GetFileName($zip)) | Set-Content -LiteralPath ($zip+'.sha256') -Encoding ASCII
Write-Host ('Package: '+$zip)
Write-Host ('SHA256: '+$hash)
