param([string]$PayloadPath=(Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Repair-ArmBoot.ps1'))
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$script:checks=0
function Assert([bool]$Condition,[string]$Reason){if(!$Condition){throw $Reason};$script:checks++}
function Reject([scriptblock]$Action,[string]$Reason){$failed=$false;try{& $Action | Out-Null}catch{$failed=$true};Assert $failed $Reason}
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($PayloadPath,[ref]$tokens,[ref]$parseErrors)
Assert ($parseErrors.Count -eq 0) ('Parse errors: '+($parseErrors | Out-String))
Assert (@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -match '^Convert(To|From)-Json$'},$true)).Count -eq 0) 'No JSON dependency in PE runtime'
. $PayloadPath -LibraryOnly
$fixture=Join-Path $env:TEMP ('ArmBootRepair-Test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$internal=[pscustomobject]@{Number=0;FriendlyName='Example internal SSD';BusType='NVMe';Size=2TB;PartitionStyle='GPT';IsOffline=$false;IsReadOnly=$false;UniqueId='synthetic-disk-0';SerialNumber='SYNTHETIC';LogicalSectorSize=512}
$usb=$internal.PSObject.Copy();$usb.Number=9;$usb.BusType='USB';$usb.UniqueId='synthetic-backup-9'
foreach($bus in @('NVMe','SATA','SAS','SCSI','RAID','UFS','ATA','MMC')){$test=$internal.PSObject.Copy();$test.BusType=$bus;Assert (!(Get-DiskRejection $test 9)) ('Accept supported fixed bus '+$bus)}
foreach($bus in @('USB','SD','iSCSI','Virtual','Unknown','File Backed Virtual')){$test=$internal.PSObject.Copy();$test.BusType=$bus;Assert ([bool](Get-DiskRejection $test 9)) ('Reject external/unknown bus '+$bus)}
Assert ([bool](Get-DiskRejection $internal 0)) 'Exclude backup disk even if internal bus is reported'
foreach($change in @(@('PartitionStyle','MBR'),@('IsReadOnly',$true),@('IsOffline',$true),@('UniqueId',''),@('Size',16GB))){$test=$internal.PSObject.Copy();$test.($change[0])=$change[1];Assert ([bool](Get-DiskRejection $test 9)) ('Reject '+$change[0])}
$osPart=[pscustomobject]@{DiskNumber=0;PartitionNumber=3;DriveLetter='W';Size=200GB;Offset=537919488;GptType='{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}';Guid='{11111111-1111-4111-8111-111111111111}'}
$espPart=[pscustomobject]@{DiskNumber=0;PartitionNumber=1;DriveLetter='S';Size=512MB;Offset=1048576;GptType='{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}';Guid='{22222222-2222-4222-8222-222222222222}'}
$candidate=[pscustomobject]@{Disk=$internal;Partition=$osPart;Root='W:\'}
Assert ((Select-RepairCandidate @($candidate) @() $null $null).Root -eq 'W:\') 'Select unique ARM Windows'
Reject {Select-RepairCandidate @() @() $null $null} 'Reject zero Windows'
Reject {Select-RepairCandidate @($candidate,$candidate) @() $null $null} 'Reject ambiguous automatic Windows'
$issue=[pscustomobject]@{DiskNumber=0;PartitionNumber=4;Reason='Locked volume'}
Reject {Select-RepairCandidate @($candidate) @($issue) $null $null} 'Unreadable candidate prevents automatic guessing'
Assert ((Select-RepairCandidate @($candidate) @($issue) 0 3).Root -eq 'W:\') 'Explicit valid disk/partition disambiguates unrelated locked partition'
Reject {Select-RepairCandidate @($candidate) @() $null 3} 'Partition selection requires disk'
Reject {Select-RepairCandidate @($candidate) @() 1 3} 'Never fall back from nonexistent requested disk'
Assert ((Select-EspPartition @($osPart,$espPart) $null).PartitionNumber -eq 1) 'Select same-disk ESP'
Reject {Select-EspPartition @($espPart,$espPart) $null} 'Reject multiple ESPs in automatic mode'
Reject {Select-EspPartition @($osPart) $null} 'Do not fabricate absent ESP'
Assert (!(Resolve-FirmwarePolicy 'Auto' $false 'not available').WriteFirmware) 'Auto degrades to files-only on unavailable firmware'
Assert (!(Resolve-FirmwarePolicy 'Skip' $true '').WriteFirmware) 'Skip honors explicit policy'
Assert ((Resolve-FirmwarePolicy 'Required' $true '').WriteFirmware) 'Required permits available firmware'
Reject {Resolve-FirmwarePolicy 'Required' $false 'denied'} 'Required stops before EFI mutation when unavailable'
Assert-UniqueTargetGuids $osPart $espPart @($osPart,$espPart)
$clone=$espPart.PSObject.Copy();$clone.DiskNumber=9
Reject {Assert-UniqueTargetGuids $osPart $espPart @($osPart,$espPart,$clone)} 'Reject cloned ESP GUID even on external disk'
$clone=$osPart.PSObject.Copy();$clone.DiskNumber=9
Reject {Assert-UniqueTargetGuids $osPart $espPart @($osPart,$espPart,$clone)} 'Reject cloned Windows GUID'
Assert-FirmwareGeometry $internal $espPart
foreach($change in @(@('Size',32MB),@('Size',8GB),@('Offset',0),@('Offset',1048577),@('PartitionNumber',1025))){$bad=$espPart.PSObject.Copy();$bad.($change[0])=$change[1];Reject {Assert-FirmwareGeometry $internal $bad} ('Reject firmware geometry '+$change[0]+'='+$change[1])}
$badDisk=$internal.PSObject.Copy();$badDisk.LogicalSectorSize=2048
Reject {Assert-FirmwareGeometry $badDisk $espPart} 'Reject unsupported logical sector size before file repair'
$english="identifier {default}`r`ndevice partition=W:`r`npath \Windows\system32\winload.efi`r`nosdevice partition=W:`r`nwinpe No`r`n"
$localized="标识符 {default}`r`n设备 partition=W:`r`n路径 \Windows\system32\winload.efi`r`nosdevice partition=W:`r`nwinpe 否`r`n"
Assert (Test-LoaderText $english 'W:') 'English BCD'
Assert (Test-LoaderText $localized 'W:') 'Localized BCD'
Assert (!(Test-LoaderText $english 'C:')) 'Reject wrong BCD partition'
Assert (!(Test-LoaderText ($english -replace 'partition=W:','ramdisk=[W:]\boot.wim') 'W:')) 'Reject recovery ramdisk BCD'
$bytes=New-Object byte[] 128;$bytes[0]=0x4D;$bytes[1]=0x5A;$bytes[0x3C]=0x40;$bytes[0x40]=0x50;$bytes[0x41]=0x45;$bytes[0x44]=0x64;$bytes[0x45]=0xAA
[IO.File]::WriteAllBytes((Join-Path $fixture 'pe.bin'),$bytes)
Assert ((Get-PeMachine (Join-Path $fixture 'pe.bin')) -eq 0xAA64) 'ARM64 PE machine detection'
$bytes[0x45]=0x86;[IO.File]::WriteAllBytes((Join-Path $fixture 'pe.bin'),$bytes)
Assert ((Get-PeMachine (Join-Path $fixture 'pe.bin')) -ne 0xAA64) 'Reject x64 as ARM64'
$bytes[0]=0;[IO.File]::WriteAllBytes((Join-Path $fixture 'pe.bin'),$bytes)
Reject {Get-PeMachine (Join-Path $fixture 'pe.bin')} 'Reject invalid PE'
function ConvertTo-Json {throw 'JSON unavailable in trimmed PE'}
function ConvertFrom-Json {throw 'JSON unavailable in trimmed PE'}
Test-RepairRuntime $fixture
Assert ((Import-Csv (Join-Path $fixture 'runtime-check.csv')).Result -eq 'PASS') 'Hash/CSV runtime works without JSON'
Write-RepairResult (Join-Path $fixture 'multiline.txt') ([ordered]@{Reason="first`r`nsecond";Blank=$null})
Assert ((Get-Content -LiteralPath (Join-Path $fixture 'multiline.txt') -Raw) -match 'Reason=first \| second') 'Result text sanitizes linebreaks'
$source=Join-Path $fixture 'source\';$backup=Join-Path $fixture 'backup'
New-Item -ItemType Directory -Path ($source+'EFI\Microsoft\Boot'),($source+'EFI\Boot') -Force | Out-Null
[IO.File]::WriteAllText(($source+'EFI\Microsoft\Boot\BCD'),'test-bcd')
[IO.File]::WriteAllText(($source+'EFI\Boot\bootaa64.efi'),'test-loader')
Backup-Efi $source $backup
$manifest=@(Import-Csv -LiteralPath (Join-Path $backup 'EFI-files-before.csv'))
Assert ($manifest.Count -eq 2) 'EFI backup inventories every file'
foreach($row in $manifest){Assert ((Get-FileHash -LiteralPath (Join-Path $backup $row.Path)).Hash -eq $row.SHA256) 'EFI backup verified by independent hash'}

# Inspect the real boot-file command plan through a mock native boundary; no EFI files are written.
& {
 $state=@{Commands=@();Copies=0}
 function Invoke-Native {
  param($Exe,$Arguments,[switch]$AllowFailure)
  $state.Commands+=@([pscustomobject]@{Exe=$Exe;Arguments=$Arguments})
  return [pscustomobject]@{ExitCode=0;Text=$english}
 }
 function New-Item {param($ItemType,$Path,[switch]$Force);if($Path -ne 'S:\EFI\Boot'){throw 'Unexpected mkdir in boot plan'}}
 function Copy-Item {param($LiteralPath,$Destination,[switch]$Force);$state.Copies++}
 function Get-PeMachine {return 0xAA64}
 function Get-FileHash {return [pscustomobject]@{Hash='SYNTHETIC-HASH'}}
 Invoke-BootFileRepair 'W:\' 'S:\' $fixture
 $bcdboot=@($state.Commands | Where-Object {$_.Exe -match 'bcdboot.exe$'})
 Assert ($bcdboot.Count -eq 1) 'Exactly one BCDBoot plan'
 Assert (($bcdboot[0].Arguments -contains '/s') -and ($bcdboot[0].Arguments -contains 'S:') -and !($bcdboot[0].Arguments -contains '/c')) 'BCDBoot explicitly targets ESP and preserves other entries'
 $bcdedit=@($state.Commands | Where-Object {$_.Exe -match 'bcdedit.exe$'})
 foreach($command in $bcdedit){Assert ($command.Arguments[0] -eq '/store' -and $command.Arguments[1] -eq 'S:\EFI\Microsoft\Boot\BCD') 'Every BCDEdit mutation/read uses explicit target store'}
 $sequence=@($bcdedit | Where-Object {$_.Arguments -contains '/bootsequence'})
 Assert ($sequence.Count -eq 1 -and $sequence[0].Arguments[-1] -eq '{default}') 'Override stale one-time OEM recovery with selected Windows for next boot'
 foreach($setting in @('persistbootsequence','resume')){
  $commands=@($bcdedit | Where-Object {$_.Arguments -contains $setting})
  Assert ($commands.Count -eq 1 -and $commands[0].Arguments[2] -eq '/set' -and $commands[0].Arguments[3] -eq '{bootmgr}' -and $commands[0].Arguments[-1] -eq 'No') ('Explicit boot manager '+$setting+' No on target store')
 }
 foreach($untouched in @('hiberboot','recoveryenabled','recoverysequence')){
  Assert (@($bcdedit | Where-Object {$_.Arguments -contains $untouched}).Count -eq 0) ('Do not modify '+$untouched)
 }
 Assert ($state.Copies -eq 1) 'Copy validated Windows manager to ARM fallback exactly once'
}
# Exercise actual identity and mount-cleanup routines with synthetic storage objects.
& {
 $state=@{Disk=$internal.PSObject.Copy();Part=$osPart.PSObject.Copy();Mapping=$osPart.PSObject.Copy();Removed=0}
 function Get-Disk {param($Number);return $state.Disk}
 function Get-Partition {param($DiskNumber,$PartitionNumber,$DriveLetter);if($DriveLetter){return $state.Mapping};return $state.Part}
 function Remove-PartitionAccessPath {$state.Removed++}
 Assert-DiskUnchanged $internal
 $state.Disk.UniqueId='changed'
 Reject {Assert-DiskUnchanged $internal} 'Actual disk identity routine rejects changed UniqueId'
 $state.Disk=$internal.PSObject.Copy();$state.Disk.SerialNumber='changed'
 Reject {Assert-DiskUnchanged $internal} 'Actual disk identity routine rejects changed serial'
 $state.Disk=$internal.PSObject.Copy()
 Assert-PartitionUnchanged $osPart 'W:\'
 $state.Part.Guid='{33333333-3333-4333-8333-333333333333}'
 Reject {Assert-PartitionUnchanged $osPart 'W:\'} 'Actual partition identity routine rejects changed GUID'
 $state.Part=$osPart.PSObject.Copy();$state.Mapping.DiskNumber=9
 Reject {Assert-PartitionUnchanged $osPart 'W:\'} 'Actual partition identity routine rejects swapped drive letter'
 $state.Mapping=$osPart.PSObject.Copy()
 # Only newly assigned paths enter Mounts; preexisting letters are never listed for removal.
 $script:Mounts=@(@{Partition=$osPart;Disk=$internal;Root='W:\'})
 Remove-RepairMounts
 Assert ($state.Removed -eq 1) 'Remove only recorded temporary mount after identity validation'
 $state.Mapping.DiskNumber=9
 Remove-RepairMounts
 Assert ($state.Removed -eq 1) 'Identity-changed mount is retained rather than removing another disk mapping'
 $script:Mounts=@()
 Remove-RepairMounts
 Assert ($state.Removed -eq 1) 'Preexisting mounts not recorded are untouched'
}
& {
 $state=@{Disk=$usb.PSObject.Copy()}
 function Get-Partition {return [pscustomobject]@{DiskNumber=9;PartitionNumber=1}}
 function Get-Disk {return $state.Disk}
 function Get-Volume {return [pscustomobject]@{FileSystem='FAT32'}}
 function Assert-NoReparsePath {}
 $location=Resolve-BackupLocation 'T:\'
 Assert ($location.Root -eq 'T:\ARM-BootRepair-Logs') 'Explicit backup volume root uses standard log directory'
 Assert ($location.Disk.Number -eq 9) 'Accept separately identified external backup disk'
 Assert ((Resolve-BackupLocation 'T:\MyLogs').Root -eq 'T:\MyLogs') 'Preserve explicit custom backup directory'
 $state.Disk.BusType='NVMe'
 Reject {Resolve-BackupLocation 'T:\'} 'Actual media resolver rejects internal backup storage'
 $state.Disk.BusType='USB';$state.Disk.IsReadOnly=$true
 Reject {Resolve-BackupLocation 'T:\'} 'Actual media resolver rejects read-only external storage'
 Reject {Resolve-BackupLocation '\\server\share'} 'Reject network backup paths'
}
# Orchestration tests replace every hardware/native boundary. Only synthetic logs under TEMP are written.
function Test-MockRun([string]$Scenario,[string]$RunMode,[string]$Policy,[int]$ExpectedCode,[string]$ExpectedStatus,[int]$ExpectedWrites,[int]$ExpectedFirmware,[int]$ExpectedRestore) {
 & {
  param($Scenario,$RunMode,$Policy,$ExpectedCode,$ExpectedStatus,$ExpectedWrites,$ExpectedFirmware,$ExpectedRestore)
  $Mode=$RunMode;$FirmwareMode=$Policy;$DiskNumber=$null;$WindowsPartitionNumber=$null;$EspPartitionNumber=$null;$BackupRoot='ignored';$RebootAfterRepair=$false
  $caseRoot=Join-Path $fixture ('case-'+$Scenario);New-Item -ItemType Directory -Path $caseRoot | Out-Null
  $state=@{Writes=0;Firmware=0;Restore=0;Cleanup=0;Probe=0;Identity=0}
  if($Scenario -eq 'geometry-invalid'){$internal=$internal.PSObject.Copy();$internal.LogicalSectorSize=2048}
  function Get-PeMachine {return 0xAA64}
  function Test-Path {
   param([string]$Path,[string]$LiteralPath,[string]$PathType)
   $value=$Path;if($LiteralPath){$value=$LiteralPath}
   if($value -eq 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT'){return $true}
   if($value -eq 'S:\EFI'){return $false}
   return Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
  }
  function Get-ItemProperty {return [pscustomobject]@{PEFirmwareType=2}}
  function Import-Module {}
  function Get-CimInstance {throw 'No optional SMBIOS in mock'}
  function Invoke-Native {param($Exe,$Arguments,[switch]$AllowFailure);return [pscustomobject]@{ExitCode=0;Text='mock native'}}
  function Resolve-BackupLocation {return [pscustomobject]@{Root=$caseRoot;VolumeRoot='T:\';Disk=$usb;Partition=[pscustomobject]@{DiskNumber=9;PartitionNumber=1}}}
  function Get-Disk {return @($internal,$usb)}
  function Get-Partition {param($DiskNumber);return @($osPart,$espPart)}
  function Mount-RepairPartition {param($Partition);if($Partition.PartitionNumber -eq 1){return 'S:\'};return 'W:\'}
  function Get-Volume {param($DriveLetter);return [pscustomobject]@{FileSystem=$(if($DriveLetter -eq 'S'){'FAT32'}else{'NTFS'});SizeRemaining=1GB}}
  function Get-ChildItem {
   param([string]$LiteralPath,[switch]$Force,[switch]$Recurse,[switch]$File,[string]$ErrorAction)
   if($LiteralPath -eq 'W:\'){return [pscustomobject]@{Name='Windows'}}
   return Microsoft.PowerShell.Management\Get-ChildItem @PSBoundParameters
  }
  function Test-WindowsInstallation {return $true}
  function Initialize-FirmwareHelper {return 'PASS: mock codec'}
  function Get-FirmwareProbe {$state.Probe++;return [pscustomobject]@{Available=($Scenario -notmatch 'unavailable|required');Reason='synthetic firmware probe'}}
  function Assert-RepairIdentity {$state.Identity++;if($Scenario -eq 'identity-changed'){throw 'Synthetic disk identity change'}}
  function Backup-Efi {}
  function Invoke-BootFileRepair {$state.Writes++;if($Scenario -eq 'file-failure'){throw 'Synthetic BCDBoot failure'}}
  function Set-RepairFirmware {$state.Firmware++;if($Scenario -eq 'firmware-failure'){throw 'Synthetic firmware transaction failure'};return 'Boot1000'}
  function Restore-Efi {$state.Restore++}
  function Remove-RepairMounts {$state.Cleanup++}
  function Read-Host {return ''}
  $oldArch=$env:PROCESSOR_ARCHITECTURE
  try{$env:PROCESSOR_ARCHITECTURE='ARM64';$code=Invoke-ArmBootRepair}finally{$env:PROCESSOR_ARCHITECTURE=$oldArch}
  Assert ($code -eq $ExpectedCode) ($Scenario+' exit code was '+$code)
  Assert ($state.Writes -eq $ExpectedWrites) ($Scenario+' boot-file writes')
  Assert ($state.Firmware -eq $ExpectedFirmware) ($Scenario+' firmware writes')
  Assert ($state.Restore -eq $ExpectedRestore) ($Scenario+' rollback invocation')
  Assert ($state.Cleanup -eq 1) ($Scenario+' always cleans temporary mounts')
  $result=@(Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $caseRoot -Filter result.txt -Recurse)
  Assert ($result.Count -eq 1) ($Scenario+' durable result exists')
  Assert ((Get-Content -LiteralPath $result[0].FullName -Raw) -match ('(?m)^Status='+[regex]::Escape($ExpectedStatus)+'\r?$')) ($Scenario+' correct result status')
 } $Scenario $RunMode $Policy $ExpectedCode $ExpectedStatus $ExpectedWrites $ExpectedFirmware $ExpectedRestore
}
Test-MockRun 'diagnose' 'Diagnose' 'Auto' 0 'DIAGNOSED' 0 0 0
Test-MockRun 'cancel' 'Interactive' 'Auto' 5 'CANCELLED' 0 0 0
Test-MockRun 'identity-changed' 'Automatic' 'Auto' 3 'STOPPED' 0 0 0
Test-MockRun 'geometry-invalid' 'Automatic' 'Required' 3 'STOPPED' 0 0 0
Test-MockRun 'required-unavailable' 'Automatic' 'Required' 3 'STOPPED' 0 0 0
Test-MockRun 'auto-unavailable' 'Automatic' 'Auto' 2 'FILES_ONLY' 1 0 0
Test-MockRun 'explicit-skip' 'Automatic' 'Skip' 2 'FILES_ONLY' 1 0 0
Test-MockRun 'file-failure' 'Automatic' 'Auto' 4 'PARTIAL' 1 0 1
Test-MockRun 'firmware-failure' 'Automatic' 'Auto' 4 'PARTIAL' 1 1 0
Test-MockRun 'success' 'Automatic' 'Required' 0 'REPAIRED' 1 1 0
Write-Output ('PASS: '+$script:checks+' runtime checks; fixture/mock only, no host disks or UEFI variables changed. Fixtures: '+$fixture)
