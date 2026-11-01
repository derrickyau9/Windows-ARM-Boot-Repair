[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string]$MountedPePath,
    [string]$BackupMediaRoot,
    [string]$PackagePath,
    [ValidateSet('None','Interactive','Automatic')][string]$AutoStartMode = 'None',
    [switch]$LibraryOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

function Assert-PlainPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $node = $full
    while ($node) {
        if (Test-Path -LiteralPath $node) {
            if ((Get-Item -LiteralPath $node -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw ('Links and junctions are not accepted: ' + $node) }
        }
        $next = Split-Path -Parent $node
        if ($next -eq $node) { break }
        $node = $next
    }
    return $full
}
function Get-InstallPeMachine([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $reader = New-Object IO.BinaryReader($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5a4d) { throw 'Invalid PE executable.' }
        $stream.Position = 0x3c; $offset = $reader.ReadInt32()
        if ($offset -lt 64 -or $offset -gt $stream.Length - 6) { throw 'Invalid PE offset.' }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x4550) { throw 'Invalid PE signature.' }
        return $reader.ReadUInt16()
    } finally { $reader.Dispose(); $stream.Dispose() }
}
function Get-StartupPlan([string]$Mount,[string]$Mode) {
    $system32 = Join-Path $Mount 'Windows\System32'
    $winpeshl = Join-Path $system32 'winpeshl.ini'
    $startnet = Join-Path $system32 'startnet.cmd'
    $line = 'call "%SystemDrive%\ArmBootRepair\AutoStart.cmd"'
    if ($Mode -eq 'None') { return [pscustomobject]@{Action='None';Path=$startnet;Line=$line} }
    if (Test-Path -LiteralPath $winpeshl) {
        throw 'Existing winpeshl.ini controls OEM startup. Automatic injection was not performed. Use AutoStartMode None, then add the documented LaunchApps entry after the OEM driver loader and wpeinit.'
    }
    $null = Assert-PlainPath $startnet
    if (Test-Path -LiteralPath $startnet) {
        $raw = [IO.File]::ReadAllBytes($startnet)
        if ($raw.Length -ge 2 -and (($raw[0] -eq 0xff -and $raw[1] -eq 0xfe) -or ($raw[0] -eq 0xfe -and $raw[1] -eq 0xff))) { throw 'UTF-16 startup file detected. Preserve it and integrate the documented command manually.' }
    }
    $existing = if (Test-Path -LiteralPath $startnet) { [IO.File]::ReadAllText($startnet) } else { '' }
    foreach ($lineText in ($existing -split '\r?\n')) {
        $command = $lineText.Trim().TrimStart('@').TrimStart()
        if ($command -match '^(?i:rem\b|::)' -or !$command) { continue }
        if ($command -match '^(?i)(?:call\s+)?"?%SystemDrive%\\ArmBootRepair\\AutoStart\.cmd"?\s*$') { return [pscustomobject]@{Action='AlreadyPresent';Path=$startnet;Line=$line} }
        if ($command -match '(?i)(^|[\s&|()])(exit|goto)(\s|$)') { throw 'Startup contains exit/goto control flow. Append-only integration might never run; preserve it and integrate the documented launcher manually.' }
    }
    return [pscustomobject]@{Action='Append';Path=$startnet;Line=$line}
}
function Write-StartupPlan($Plan,[string]$RunId) {
    if ($Plan.Action -ne 'Append') { return }
    if (Test-Path -LiteralPath $Plan.Path) { Copy-Item -LiteralPath $Plan.Path -Destination ($Plan.Path+'.before-arm-repair-'+$RunId) }
    # Append ASCII bytes, preserving the OEM file's original byte sequence and encoding.
    $prefix = if (Test-Path -LiteralPath $Plan.Path) { "`r`n" } else { "@echo off`r`nwpeinit`r`n" }
    $addition = $prefix + "rem Windows ARM Boot Repair (optional)`r`n" + $Plan.Line + "`r`n"
    $stream = [IO.File]::Open($Plan.Path,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $bytes=[Text.Encoding]::ASCII.GetBytes($addition); $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}
function Get-AutoStartText([string]$Mode) {
    $launcher = if ($Mode -eq 'Automatic') { 'Run-Automatic.cmd' } else { 'Run-Repair.cmd' }
    return "@echo off`r`nif exist %SystemDrive%\ArmBootRepair.started exit /b 0`r`necho started>%SystemDrive%\ArmBootRepair.started`r`nstart `"Windows ARM Boot Repair`" `"%SystemRoot%\System32\cmd.exe`" /d /k `"%SystemDrive%\ArmBootRepair\$launcher`"`r`n"
}
function Test-PackageContents([string]$Root) {
    foreach ($name in @('Repair-ArmBoot.ps1','FirmwareBoot.dll','FirmwareBoot.sha256','Run-Repair.cmd','Run-Automatic.cmd','Diagnose.cmd')) {
        $path = Assert-PlainPath (Join-Path $Root $name)
        if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw ('Package file is missing: '+$name) }
    }
    $expected = ([IO.File]::ReadAllText((Join-Path $Root 'FirmwareBoot.sha256'))).Trim()
    if ($expected -notmatch '^[0-9a-fA-F]{64}$' -or (Get-FileHash -LiteralPath (Join-Path $Root 'FirmwareBoot.dll') -Algorithm SHA256).Hash -ne $expected) { throw 'Firmware helper checksum failed.' }
}
function Copy-ToolkitFiles([string]$Source,[string]$Destination,[string]$Mode) {
    $null = Assert-PlainPath $Destination
    if (Test-Path -LiteralPath $Destination) {
        $links = @(Get-ChildItem -LiteralPath $Destination -Recurse -Force | Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint})
        if ($links.Count) { throw 'Existing toolkit directory contains links or junctions.' }
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($name in @('Repair-ArmBoot.ps1','FirmwareBoot.dll','FirmwareBoot.sha256','Run-Repair.cmd','Run-Automatic.cmd','Diagnose.cmd')) {
        Copy-Item -LiteralPath (Join-Path $Source $name) -Destination (Join-Path $Destination $name) -Force
        if ((Get-FileHash -LiteralPath (Join-Path $Source $name)).Hash -ne (Get-FileHash -LiteralPath (Join-Path $Destination $name)).Hash) { throw ('Installed payload verification failed: '+$name) }
    }
    $autoStart = Join-Path $Destination 'AutoStart.cmd'
    if ($Mode -ne 'None' -or !(Test-Path -LiteralPath $autoStart)) { [IO.File]::WriteAllText($autoStart,(Get-AutoStartText $Mode),[Text.Encoding]::ASCII) }
}
if ($LibraryOnly) { return }
if (!$MountedPePath -or !$BackupMediaRoot) { throw 'Specify -MountedPePath and -BackupMediaRoot. See docs/PE-INTEGRATION.md.' }
$mount = (Assert-PlainPath $MountedPePath).TrimEnd('\')
$onlineRoot = [IO.Path]::GetDirectoryName($env:SystemRoot.TrimEnd('\'))
if ($mount -eq $onlineRoot -or $mount -eq $env:SystemRoot -or $mount -match '^[a-zA-Z]:$') { throw 'An offline PE mount directory is required; installed Windows and drive roots are rejected.' }
foreach ($relative in @('Windows\System32\wpeutil.exe','Windows\System32\config\SYSTEM','Windows\System32\WindowsPowerShell\v1.0\powershell.exe')) {
    $path = Assert-PlainPath (Join-Path $mount $relative)
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw ('PE component is missing: '+$relative) }
}
if ((Get-InstallPeMachine (Join-Path $mount 'Windows\System32\wpeutil.exe')) -ne 0xaa64 -or (Get-InstallPeMachine (Join-Path $mount 'Windows\System32\WindowsPowerShell\v1.0\powershell.exe')) -ne 0xaa64) { throw 'Mounted PE must contain native ARM64 tools and PowerShell.' }
$media = Assert-PlainPath $BackupMediaRoot
if ($media -notmatch '^[a-zA-Z]:\\$') { throw 'BackupMediaRoot must be a local volume root, such as E:\.' }
Import-Module Storage -ErrorAction Stop
$letter = $media.Substring(0,1)
$volume = Get-Volume -DriveLetter $letter
$part = Get-Partition -DriveLetter $letter
$disk = Get-Disk -Number $part.DiskNumber
if ([string]$disk.BusType -notin @('USB','SD') -or $disk.IsBoot -or $disk.IsSystem -or $disk.IsOffline -or $disk.IsReadOnly -or [string]$volume.FileSystem -notin @('FAT32','NTFS','exFAT')) { throw 'Backup media must be a writable external USB/SD volume, not a running-system disk.' }
if (!$PackagePath) {
    $parent = Split-Path -Parent $PSScriptRoot
    $PackagePath = if (Test-Path -LiteralPath (Join-Path $parent 'Repair-ArmBoot.ps1')) { $parent } else { Join-Path $parent 'dist\Windows-ARM-Boot-Repair-0.1.0' }
}
$package = Assert-PlainPath $PackagePath
Test-PackageContents $package
$plan = Get-StartupPlan $mount $AutoStartMode
$target = Join-Path $mount 'ArmBootRepair'
$null = Assert-PlainPath $target
$marker = Join-Path $media 'ARM-BOOT-REPAIR.TAG'
$null = Assert-PlainPath $marker
if ((Test-Path -LiteralPath $marker) -and !(Test-Path -LiteralPath $marker -PathType Leaf)) { throw 'Backup media marker is not a regular file.' }
if ($package.TrimEnd('\') -eq $target.TrimEnd('\')) { throw 'Source package and installed destination must be different.' }
$runId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
if (!$PSCmdlet.ShouldProcess($mount,'Install Windows ARM Boot Repair and mark the selected backup media')) { return }
if (Test-Path -LiteralPath $target) {
    $links = @(Get-ChildItem -LiteralPath $target -Recurse -Force | Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint})
    if ($links.Count) { throw 'Existing toolkit contains links or junctions.' }
    Copy-Item -LiteralPath $target -Destination ($target+'.previous-'+$runId) -Recurse
}
Copy-ToolkitFiles $package $target $AutoStartMode
Write-StartupPlan $plan $runId
$currentPart = Get-Partition -DriveLetter $letter
$currentDisk = Get-Disk -Number $currentPart.DiskNumber
if ($currentPart.DiskNumber -ne $part.DiskNumber -or $currentPart.PartitionNumber -ne $part.PartitionNumber -or [string]$currentDisk.UniqueId -ne [string]$disk.UniqueId -or [string]$currentDisk.SerialNumber -ne [string]$disk.SerialNumber -or $currentDisk.Size -ne $disk.Size -or $currentDisk.IsOffline -or $currentDisk.IsReadOnly) { throw 'Backup media changed during installation; marker was not written. Keep this PE offline until the intended media is marked.' }
if (!(Test-Path -LiteralPath $marker)) { [IO.File]::WriteAllText($marker,"Windows ARM Boot Repair backup media`r`n",[Text.Encoding]::ASCII) }
Write-Host ('Installed and hash-verified: '+$target)
Write-Host ('Backup media marker: '+$marker)
if ($AutoStartMode -eq 'None') {
    Write-Host 'Startup and any existing AutoStart.cmd were preserved. Run X:\ArmBootRepair\Run-Repair.cmd from PE, or follow docs/PE-INTEGRATION.md to integrate the OEM shell.'
    if (Test-Path -LiteralPath (Join-Path $mount 'Windows\System32\winpeshl.ini')) {
        Write-Host 'Manual [LaunchApps] entry, placed after OEM drivers and wpeinit:'
        Write-Host '%SYSTEMROOT%\System32\cmd.exe, /d /c %SYSTEMDRIVE%\ArmBootRepair\AutoStart.cmd'
    }
} else { Write-Host ('startnet.cmd integration: '+$plan.Action+'; mode '+$AutoStartMode) }
Write-Host 'Commit the offline WIM using your image servicing workflow. This script does not mount, commit, reformat, or reboot anything.'
