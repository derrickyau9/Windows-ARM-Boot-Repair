$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$repo = Split-Path -Parent $PSScriptRoot
$package = Join-Path $repo 'dist\Windows-ARM-Boot-Repair-0.1.0'
$script:checks = 0
function Assert([bool]$Condition,[string]$Message) { if (!$Condition) { throw $Message }; $script:checks++ }
function Reject([scriptblock]$Action,[string]$Message) { $rejected=$false; try { & $Action | Out-Null } catch { $rejected=$true }; Assert $rejected $Message }
. (Join-Path $repo 'tools\Install-ToPe.ps1') -LibraryOnly
Test-PackageContents $package
Assert $true 'Built payload files and checksum'
$null = [Reflection.Assembly]::LoadFrom((Join-Path $package 'FirmwareBoot.dll'))
Assert ([ArmBootRepair.FirmwareBoot]::SelfTest() -match '^PASS') 'Managed helper pure self-test'
foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $repo 'tools') -Filter '*.ps1') + @(Get-ChildItem -LiteralPath (Join-Path $repo 'src') -Filter '*.ps1')) {
    $tokens=$null; $errors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    Assert ($errors.Count -eq 0) ('Parse: '+$file.Name+' '+($errors | Out-String))
}
$fixture = Join-Path $repo ('.build\packaging-fixture-'+[guid]::NewGuid().ToString('N'))
$system32 = Join-Path $fixture 'Windows\System32'
New-Item -ItemType Directory -Path $system32 -Force | Out-Null
$startnet = Join-Path $system32 'startnet.cmd'
$original = "@echo off`r`ncall OEM-Drivers.cmd`r`nwpeinit`r`n"
[IO.File]::WriteAllText($startnet,$original,[Text.Encoding]::ASCII)
$none = Get-StartupPlan $fixture 'None'
Assert ($none.Action -eq 'None') 'Default leaves startup alone'
Write-StartupPlan $none 'test'
Assert ([IO.File]::ReadAllText($startnet) -eq $original) 'Default startup bytes unchanged'
$plan = Get-StartupPlan $fixture 'Automatic'
Assert ($plan.Action -eq 'Append') 'Explicit startnet integration planned'
Write-StartupPlan $plan 'test'
$written = [IO.File]::ReadAllText($startnet)
Assert ($written.StartsWith($original)) 'OEM startup commands retain order and bytes'
Assert (Test-Path -LiteralPath ($startnet+'.before-arm-repair-test')) 'Original startup is backed up'
$again = Get-StartupPlan $fixture 'Interactive'
Assert ($again.Action -eq 'AlreadyPresent') 'Repeat installation is idempotent'
Write-StartupPlan $again 'test2'
Assert ([IO.File]::ReadAllText($startnet) -eq $written) 'Repeat startup has no duplicate lines'
$winpeshl = Join-Path $system32 'winpeshl.ini'
$oemIni="[LaunchApps]`r`nwpeinit.exe`r`nOEM-Shell.exe`r`n"
[IO.File]::WriteAllText($winpeshl,$oemIni,[Text.Encoding]::ASCII)
Reject { Get-StartupPlan $fixture 'Automatic' } 'Existing OEM shell must block guessed auto-start injection'
Assert ([IO.File]::ReadAllText($winpeshl) -eq $oemIni) 'OEM winpeshl retained'
Assert ((Get-StartupPlan $fixture 'None').Action -eq 'None') 'Manual integration remains supported with OEM shell'
$fresh = Join-Path $fixture 'Fresh'
New-Item -ItemType Directory -Path (Join-Path $fresh 'Windows\System32') -Force | Out-Null
$freshPlan = Get-StartupPlan $fresh 'Automatic'
Write-StartupPlan $freshPlan 'fresh'
Assert ([IO.File]::ReadAllText($freshPlan.Path).Contains('wpeinit')) 'New startup initializes PE first'
$unicode = Join-Path $fixture 'Unicode'
New-Item -ItemType Directory -Path (Join-Path $unicode 'Windows\System32') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $unicode 'Windows\System32\startnet.cmd'),$original,[Text.Encoding]::Unicode)
Reject { Get-StartupPlan $unicode 'Automatic' } 'Unsupported startup encoding does not get corrupted'
$terminal = Join-Path $fixture 'Terminal'
New-Item -ItemType Directory -Path (Join-Path $terminal 'Windows\System32') -Force | Out-Null
foreach ($control in @('exit','exit /b','goto :eof','goto finished','if defined SKIP exit /b')) {
    [IO.File]::WriteAllText((Join-Path $terminal 'Windows\System32\startnet.cmd'),($original+$control+"`r`n"),[Text.Encoding]::ASCII)
    Reject { Get-StartupPlan $terminal 'Automatic' } ('Unreachable append is refused: '+$control)
}
[IO.File]::WriteAllText((Join-Path $terminal 'Windows\System32\startnet.cmd'),($original+"exit /b`r`n"+'call "%SystemDrive%\ArmBootRepair\AutoStart.cmd"'+"`r`n"),[Text.Encoding]::ASCII)
Reject { Get-StartupPlan $terminal 'Automatic' } 'An existing unreachable launcher is not reported as configured'
$installed = Join-Path $fixture 'ArmBootRepair'
Copy-ToolkitFiles $package $installed 'Automatic'
Test-PackageContents $installed
Assert $true 'Installed files hash-verified'
Assert ([IO.File]::ReadAllText((Join-Path $installed 'AutoStart.cmd')).Contains('Run-Automatic.cmd')) 'Automatic launcher requested'
Copy-ToolkitFiles $package $installed 'None'
Assert ([IO.File]::ReadAllText((Join-Path $installed 'AutoStart.cmd')).Contains('Run-Automatic.cmd')) 'None preserves existing launcher mode'
Copy-ToolkitFiles $package $installed 'Interactive'
Assert ([IO.File]::ReadAllText((Join-Path $installed 'AutoStart.cmd')).Contains('Run-Repair.cmd')) 'Interactive launcher requested'
[IO.File]::AppendAllText((Join-Path $installed 'FirmwareBoot.dll'),'tamper')
Reject { Test-PackageContents $installed } 'Corrupt managed helper is rejected'
foreach ($name in @('Run-Repair.cmd','Run-Automatic.cmd','Diagnose.cmd')) {
    $text = [IO.File]::ReadAllText((Join-Path $package $name))
    Assert ($text.Contains('%~dp0Repair-ArmBoot.ps1')) ('Launcher is relocatable: '+$name)
}
Write-Host ('PASS: '+$script:checks+' packaging/install checks; temporary files only, no disk or firmware API calls.')
