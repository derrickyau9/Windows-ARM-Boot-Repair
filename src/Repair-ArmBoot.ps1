[CmdletBinding()]
param(
 [ValidateSet('Diagnose','Interactive','Automatic')][string]$Mode='Diagnose',
 [ValidateSet('Auto','Required','Skip')][string]$FirmwareMode='Auto',
 [string]$BackupRoot,
 [Nullable[int]]$DiskNumber,
 [Nullable[int]]$WindowsPartitionNumber,
 [Nullable[int]]$EspPartitionNumber,
 [switch]$RebootAfterRepair,
 [switch]$LibraryOnly
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$script:Version='0.1.0'
$script:EspType='{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$script:DataType='{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'

function Get-PeMachine([string]$Path) {
 $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
 $reader=New-Object IO.BinaryReader($stream)
 try {
  if($reader.ReadUInt16() -ne 0x5A4D){throw "Not a PE file: $Path"}
  $stream.Position=0x3C; $offset=$reader.ReadInt32()
  if($offset -lt 64 -or $offset -gt $stream.Length-6){throw "Invalid PE header: $Path"}
  $stream.Position=$offset
  if($reader.ReadUInt32() -ne 0x4550){throw "Invalid PE signature: $Path"}
  return $reader.ReadUInt16()
 } finally {$reader.Dispose();$stream.Dispose()}
}
function Get-DiskRejection($Disk,[int]$BackupDiskNumber) {
 if($Disk.Number -eq $BackupDiskNumber){return 'Backup/media disk'}
 if(@('NVMe','SATA','SAS','SCSI','RAID','UFS','ATA','MMC') -notcontains [string]$Disk.BusType){return ('Unsupported/external bus: '+$Disk.BusType)}
 if($Disk.Size -le 32GB){return 'Disk is 32 GiB or smaller'}
 if([string]$Disk.PartitionStyle -ne 'GPT'){return 'Not GPT'}
 if($Disk.IsOffline){return 'Offline'}
 if($Disk.IsReadOnly){return 'Read-only'}
 if([string]::IsNullOrWhiteSpace([string]$Disk.UniqueId)){return 'Missing stable disk identity'}
 return ''
}
function Select-RepairCandidate($Candidates,$Issues,[Nullable[int]]$RequestedDisk,[Nullable[int]]$RequestedPartition,[switch]$AllowChoice) {
 $items=@($Candidates)
 if($null -ne $RequestedDisk){$items=@($items | Where-Object {$_.Disk.Number -eq $RequestedDisk})}
 if($null -ne $RequestedPartition){
  if($null -eq $RequestedDisk){throw 'WindowsPartitionNumber requires DiskNumber'}
  $items=@($items | Where-Object {$_.Partition.PartitionNumber -eq $RequestedPartition})
 }
 $relevantIssues=@($Issues)
 if($null -ne $RequestedDisk){$relevantIssues=@($relevantIssues | Where-Object {$_.DiskNumber -eq $RequestedDisk})}
 if($null -ne $RequestedPartition){$relevantIssues=@($relevantIssues | Where-Object {$_.PartitionNumber -eq $RequestedPartition})}
 if(!$AllowChoice -and $relevantIssues.Count){throw 'Some possible Windows partitions could not be validated; inspect diagnostics or use Interactive mode'}
 if($items.Count -eq 0){throw 'No complete, accessible ARM64 Windows installation matches the selection'}
 if($items.Count -eq 1){return $items[0]}
 if(!$AllowChoice){throw ('Ambiguous Windows selection: '+$items.Count+' installations; use Interactive mode or specify disk and partition')}
 for($i=0;$i -lt $items.Count;$i++){
  Write-Host ('[{0}] Disk {1}: {2}; partition {3}; Windows {4}' -f ($i+1),$items[$i].Disk.Number,$items[$i].Disk.FriendlyName,$items[$i].Partition.PartitionNumber,$items[$i].Root)
 }
 $choice=Read-Host 'Select Windows number (blank cancels)'
 $index=0
 if(![int]::TryParse($choice,[ref]$index) -or $index -lt 1 -or $index -gt $items.Count){throw 'Selection cancelled or invalid'}
 return $items[$index-1]
}
function Select-EspPartition($Partitions,[Nullable[int]]$RequestedPartition,[switch]$AllowChoice) {
 $items=@($Partitions | Where-Object {[string]$_.GptType -eq $script:EspType})
 if($null -ne $RequestedPartition){$items=@($items | Where-Object {$_.PartitionNumber -eq $RequestedPartition})}
 if($items.Count -eq 0){throw 'No matching EFI System Partition on the selected Windows disk; no partition will be created'}
 if($items.Count -eq 1){return $items[0]}
 if(!$AllowChoice){throw 'Multiple EFI System Partitions on the selected disk; specify EspPartitionNumber or use Interactive mode'}
 for($i=0;$i -lt $items.Count;$i++){Write-Host ('[{0}] EFI partition {1}, {2:N0} MiB, GUID {3}' -f ($i+1),$items[$i].PartitionNumber,($items[$i].Size/1MB),$items[$i].Guid)}
 $choice=Read-Host 'Select EFI partition number from this list (blank cancels)';$index=0
 if(![int]::TryParse($choice,[ref]$index) -or $index -lt 1 -or $index -gt $items.Count){throw 'EFI selection cancelled or invalid'}
 return $items[$index-1]
}
function Resolve-FirmwarePolicy([string]$Policy,[bool]$Available,[string]$Reason) {
 if($Policy -eq 'Skip'){return [pscustomobject]@{WriteFirmware=$false;Reason='Firmware update explicitly skipped'}}
 if($Available){return [pscustomobject]@{WriteFirmware=$true;Reason='Native UEFI variable access available'}}
 if($Policy -eq 'Required'){throw ('Firmware access required but unavailable: '+$Reason)}
 return [pscustomobject]@{WriteFirmware=$false;Reason=('Firmware access unavailable: '+$Reason)}
}
function Get-HardwareProfile([string]$Manufacturer,[string]$Model,[string]$Board,[string]$Cpu) {
 if($Model -match '14-ks000' -or $Board -eq '8F22'){return 'HP RTX Spark family (identity hint; not a compatibility guarantee)'}
 if(($Manufacturer+' '+$Model+' '+$Cpu) -match 'NVIDIA|Spark'){return 'NVIDIA ARM64 (generic UEFI path)'}
 if($Cpu -match 'Qualcomm|Snapdragon'){return 'Qualcomm ARM64 (generic UEFI path)'}
 return 'Generic Windows ARM64 UEFI'
}
function Test-LoaderText([string]$Text,[string]$Drive) {
 $partition='(?im)\s+partition='+[regex]::Escape($Drive)+'\s*$'
 return ([regex]::Matches($Text,$partition).Count -eq 2 -and $Text -match '(?im)\s+\\Windows\\system32\\winload\.efi\s*$' -and $Text -notmatch '(?i)ramdisk|WSDVTDC')
}
function Write-Log([string]$Message) {
 $line='[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'),$Message
 Write-Host $line
 Add-Content -LiteralPath $script:Log -Value $line -Encoding UTF8
}
function Write-RepairResult([string]$Path,[System.Collections.IDictionary]$Fields) {
 $lines=foreach($key in $Fields.Keys){'{0}={1}' -f $key,(([string]$Fields[$key]) -replace '\r?\n',' | ')}
 $lines | Set-Content -LiteralPath $Path -Encoding UTF8
}
function Initialize-FirmwareHelper {
 $library=Join-Path $PSScriptRoot 'FirmwareBoot.dll'
 $checksum=Join-Path $PSScriptRoot 'FirmwareBoot.sha256'
 if(!(Test-Path -LiteralPath $library) -or !(Test-Path -LiteralPath $checksum)){throw 'Firmware helper or checksum missing; use a complete built package'}
 $expected=(Get-Content -LiteralPath $checksum -Raw).Trim()
 if($expected -notmatch '^[0-9a-fA-F]{64}$' -or (Get-FileHash -LiteralPath $library -Algorithm SHA256).Hash -ne $expected){throw 'Firmware helper checksum mismatch'}
 $null=[Reflection.Assembly]::LoadFrom($library)
 $check=[ArmBootRepair.FirmwareBoot]::SelfTest()
 if($check -notmatch '^PASS'){throw 'Firmware device-path self-check failed'}
 return $check
}
function Get-FirmwareProbe {
 try{return [pscustomobject]@{Available=$true;Reason=[ArmBootRepair.FirmwareBoot]::Probe()}}
 catch{return [pscustomobject]@{Available=$false;Reason=$_.Exception.Message}}
}
function Assert-FirmwareGeometry($Disk,$Partition) {
 $sector=[long]$Disk.LogicalSectorSize
 if(@(512,4096) -notcontains $sector){throw 'UEFI repair supports 512-byte or 4096-byte logical sectors'}
 if($Partition.Size -lt 64MB -or $Partition.Size -gt 4GB -or $Partition.Offset -le 0 -or $Partition.PartitionNumber -lt 1 -or $Partition.PartitionNumber -gt 1024){throw 'EFI partition geometry is outside the supported firmware repair range'}
 if(($Partition.Offset % $sector) -ne 0 -or ($Partition.Size % $sector) -ne 0){throw 'EFI partition is not aligned to logical sectors'}
}
function Test-RepairRuntime([string]$Directory) {
 $probe=Join-Path $Directory 'runtime-probe.txt'
 [IO.File]::WriteAllText($probe,'abc',[Text.Encoding]::ASCII)
 $expected='BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD'
 $hash=(Get-FileHash -LiteralPath $probe -Algorithm SHA256).Hash
 if($hash -ne $expected){throw 'PE runtime SHA256 self-check failed'}
 $csv=Join-Path $Directory 'runtime-check.csv'
 [pscustomobject]@{Component='SHA256 and CSV';Result='PASS';SHA256=$hash} | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
 if((Get-Content -LiteralPath $csv -Raw) -notmatch $expected){throw 'PE runtime CSV self-check failed'}
 Write-RepairResult (Join-Path $Directory 'runtime-check.txt') ([ordered]@{Version=$script:Version;Hash='PASS';CSV='PASS';ResultText='PASS'})
}
function Invoke-Native([string]$Exe,[string[]]$Arguments,[switch]$AllowFailure) {
 Write-Log ($Exe+' '+($Arguments -join ' '))
 $old=$ErrorActionPreference;$ErrorActionPreference='Continue'
 try{$output=(& $Exe @Arguments 2>&1 | Out-String);$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
 Add-Content -LiteralPath $script:Log -Value $output -Encoding UTF8
 if($code -ne 0 -and !$AllowFailure){throw "$Exe failed, exit code $code. See repair.log."}
 return [pscustomobject]@{ExitCode=$code;Text=$output}
}
function Assert-NoReparsePath([string]$Path) {
 $current=[IO.Path]::GetFullPath($Path)
 while($current){
  if(Test-Path -LiteralPath $current){
   if((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw ('Reparse paths are not supported: '+$current)}
  }
  $parent=[IO.Directory]::GetParent($current)
  if($null -eq $parent){break};$current=$parent.FullName
 }
}
function Resolve-BackupLocation([string]$RequestedRoot) {
 if(!$RequestedRoot){
  $matches=@(Get-Volume | Where-Object {$_.DriveLetter -and (Test-Path -LiteralPath ([string]$_.DriveLetter+':\ARM-BOOT-REPAIR.TAG'))})
  if($matches.Count -ne 1){throw 'Use -BackupRoot on an external USB/SD volume, or mark exactly one such volume with ARM-BOOT-REPAIR.TAG'}
  $RequestedRoot=[string]$matches[0].DriveLetter+':\ARM-BootRepair-Logs'
 }
 if($RequestedRoot -notmatch '^[A-Za-z]:\\'){throw 'BackupRoot must be an absolute local drive path on external USB/SD storage'}
 $full=[IO.Path]::GetFullPath($RequestedRoot)
 if($full -match '^[A-Za-z]:\\$'){$full=$full+'ARM-BootRepair-Logs'}
 Assert-NoReparsePath $full
 $part=Get-Partition -DriveLetter $full.Substring(0,1)
 $disk=Get-Disk -Number $part.DiskNumber
 if(@('USB','SD') -notcontains [string]$disk.BusType -or $disk.IsOffline -or $disk.IsReadOnly){throw 'BackupRoot must be writable external USB/SD storage, separate from target Windows'}
 if([string]::IsNullOrWhiteSpace([string]$disk.UniqueId)){throw 'Backup disk has no stable identity'}
 $volume=Get-Volume -DriveLetter $full.Substring(0,1)
 if(!$volume.FileSystem -or [string]$volume.FileSystem -eq 'RAW'){throw 'Backup volume is locked or unrecognized'}
 return [pscustomobject]@{Root=$full;VolumeRoot=$full.Substring(0,3);Disk=$disk;Partition=$part}
}
function Assert-DiskUnchanged($Expected) {
 $now=Get-Disk -Number $Expected.Number
 if([string]$now.UniqueId -ne [string]$Expected.UniqueId -or [string]$now.SerialNumber -ne [string]$Expected.SerialNumber -or $now.Size -ne $Expected.Size -or [string]$now.BusType -ne [string]$Expected.BusType -or [string]$now.PartitionStyle -ne [string]$Expected.PartitionStyle -or $now.IsOffline -or $now.IsReadOnly){throw 'Disk identity or availability changed'}
}
function Assert-PartitionUnchanged($Expected,[string]$Root) {
 $now=Get-Partition -DiskNumber $Expected.DiskNumber -PartitionNumber $Expected.PartitionNumber
 if([string]$now.Guid -ne [string]$Expected.Guid -or $now.Offset -ne $Expected.Offset -or $now.Size -ne $Expected.Size -or [string]$now.GptType -ne [string]$Expected.GptType){throw 'Partition identity changed'}
 if($Root){
  $mapped=@(Get-Partition -DriveLetter $Root.Substring(0,1))
  if($mapped.Count -ne 1 -or $mapped[0].DiskNumber -ne $Expected.DiskNumber -or $mapped[0].PartitionNumber -ne $Expected.PartitionNumber){throw 'Drive letter mapping changed'}
 }
}
function Assert-UniqueTargetGuids($WindowsPartition,$EspPartition,$AllPartitions) {
 foreach($targetPart in @($WindowsPartition,$EspPartition)){
  $guid=[string]$targetPart.Guid
  if([string]::IsNullOrWhiteSpace($guid) -or $guid -eq '{00000000-0000-0000-0000-000000000000}'){throw 'Target partition has no stable GPT GUID'}
  $matches=@($AllPartitions | Where-Object {[string]$_.Guid -eq $guid})
  if($matches.Count -ne 1 -or $matches[0].DiskNumber -ne $targetPart.DiskNumber -or $matches[0].PartitionNumber -ne $targetPart.PartitionNumber){throw 'Duplicate or changed target partition GUID; disconnect old cloned disks before repair'}
 }
}
function Assert-RepairIdentity($Disk,$WindowsPartition,[string]$WindowsRoot,$EspPartition,[string]$EspRoot,$Media) {
 Assert-UniqueTargetGuids $WindowsPartition $EspPartition @(Get-Partition)
 Assert-DiskUnchanged $Disk
 Assert-PartitionUnchanged $WindowsPartition $WindowsRoot
 Assert-PartitionUnchanged $EspPartition $EspRoot
 Assert-DiskUnchanged $Media.Disk
 Assert-PartitionUnchanged $Media.Partition $Media.VolumeRoot
 Assert-NoReparsePath $Media.Root
 if($Disk.Number -eq $Media.Disk.Number){throw 'Target and backup refer to the same disk'}
}
function Mount-RepairPartition($Partition) {
 if($Partition.DriveLetter){
  $root=[string]$Partition.DriveLetter+':\'
  Assert-PartitionUnchanged $Partition $root
  return $root
 }
 $used=@(Get-Volume | ForEach-Object {[string]$_.DriveLetter})
 $letters=@('S','W','V','T','R','Q','P','O','N','M','L','J','I','H','G','F','E','D','C' | Where-Object {$used -notcontains $_})
 if($letters.Count -eq 0){throw 'No free drive letter'}
 $root=$letters[0]+':\'
 $disk=Get-Disk -Number $Partition.DiskNumber
 Add-PartitionAccessPath -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber -AccessPath $root
 $script:Mounts+=@{Partition=$Partition;Disk=$disk;Root=$root}
 Assert-PartitionUnchanged $Partition $root
 return $root
}
function Remove-RepairMounts {
 foreach($mount in $script:Mounts){
  try{
   Assert-DiskUnchanged $mount.Disk
   Assert-PartitionUnchanged $mount.Partition $mount.Root
   Remove-PartitionAccessPath -DiskNumber $mount.Partition.DiskNumber -PartitionNumber $mount.Partition.PartitionNumber -AccessPath $mount.Root
  }catch{Write-Host ('Temporary mount retained: '+$mount.Root+' '+$_.Exception.Message) -ForegroundColor Yellow}
 }
}
function Test-WindowsInstallation([string]$Root) {
 if(!(Test-Path -LiteralPath ($Root+'Windows'))){return $false}
 Assert-NoReparsePath ($Root+'Windows')
 foreach($required in @('Windows\System32\ntoskrnl.exe','Windows\System32\winload.efi','Windows\Boot\EFI\bootmgfw.efi','Windows\System32\config\BCD-Template','Windows\System32\config\SYSTEM','Windows\System32\config\SOFTWARE')){
  Assert-NoReparsePath ($Root+$required)
  if(!(Test-Path -LiteralPath ($Root+$required) -PathType Leaf)){throw ('Incomplete Windows: '+$Root+$required)}
 }
 foreach($binary in @('Windows\System32\ntoskrnl.exe','Windows\System32\winload.efi','Windows\Boot\EFI\bootmgfw.efi')){
  if((Get-PeMachine ($Root+$binary)) -ne 0xAA64){throw ('Not ARM64 Windows: '+$Root+$binary)}
 }
 return $true
}
function Backup-Efi([string]$Esp,[string]$Destination) {
 New-Item -ItemType Directory -Path $Destination -Force | Out-Null
 $entries=@()
 if(Test-Path -LiteralPath ($Esp+'EFI')){
  Assert-NoReparsePath ($Esp+'EFI')
  $all=@(Get-ChildItem -LiteralPath ($Esp+'EFI') -Recurse -Force)
  if(@($all | Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'EFI tree contains a reparse point'}
  Copy-Item -LiteralPath ($Esp+'EFI') -Destination (Join-Path $Destination 'EFI') -Recurse -Force
  foreach($file in @($all | Where-Object {!$_.PSIsContainer})){
   $relative=$file.FullName.Substring($Esp.Length)
   $hash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
   if((Get-FileHash -LiteralPath (Join-Path $Destination $relative) -Algorithm SHA256).Hash -ne $hash){throw ('EFI backup mismatch: '+$relative)}
   $entries+=[pscustomobject]@{Path=$relative;SHA256=$hash}
  }
 }
 $entries | Export-Csv -LiteralPath (Join-Path $Destination 'EFI-files-before.csv') -NoTypeInformation -Encoding UTF8
}
function Restore-Efi([string]$Esp,[string]$Backup,[string]$RunId) {
 foreach($relative in @('EFI\Microsoft\Boot','EFI\Boot')){
  $current=[IO.Path]::GetFullPath($Esp+$relative)
  if(!$current.StartsWith($Esp,[StringComparison]::OrdinalIgnoreCase) -or $Esp -notmatch '^[A-Z]:\\$'){throw 'Invalid EFI rollback path'}
  Assert-NoReparsePath $current
  if(Test-Path -LiteralPath $current){Rename-Item -LiteralPath $current -NewName ('Boot.failed-'+$RunId)}
  $previous=Join-Path $Backup $relative
  if(Test-Path -LiteralPath $previous){Copy-Item -LiteralPath $previous -Destination $current -Recurse -Force}
 }
 # Verify every previously saved file in the managed directories after restoration.
 $manifest=Join-Path $Backup 'EFI-files-before.csv'
 if(Test-Path -LiteralPath $manifest){
  foreach($row in @(Import-Csv -LiteralPath $manifest)){
   if($row.Path -match '^EFI\\(Microsoft\\Boot|Boot)\\'){
    if((Get-FileHash -LiteralPath (Join-Path $Esp $row.Path) -Algorithm SHA256).Hash -ne $row.SHA256){throw 'Restored EFI file checksum mismatch'}
   }
  }
 }
}
function Set-RepairFirmware([string]$Esp,[string]$Backup,$Partition,$Disk) {
 Assert-DiskUnchanged $Disk
 Assert-PartitionUnchanged $Partition $Esp
 $actualDisk=Get-Disk -Number $Disk.Number
 return [ArmBootRepair.FirmwareBoot]::Repair($Esp,[string]$Partition.Guid,[uint32]$Partition.PartitionNumber,[long]$Partition.Offset,[long]$Partition.Size,[uint32]$actualDisk.LogicalSectorSize,(Join-Path $Backup 'Firmware'))
}

function Invoke-BootFileRepair([string]$os,[string]$esp,[string]$backup) {
 $native=$env:SystemRoot+'\System32\'
  # An explicit ESP avoids BCDBoot choosing the PE USB. Omit /c to retain existing unrelated BCD entries.
  $null=Invoke-Native ($native+'bcdboot.exe') @(($os+'Windows'),'/s',$esp.Substring(0,2),'/f','UEFI','/v')
  $store=$esp+'EFI\Microsoft\Boot\BCD'
  foreach($setting in @(
   @('{bootmgr}','device',('partition='+$esp.Substring(0,2))),
   @('{bootmgr}','path','\EFI\Microsoft\Boot\bootmgfw.efi'),
   @('{bootmgr}','persistbootsequence','No'),
   @('{bootmgr}','resume','No'),
   @('{default}','device',('partition='+$os.Substring(0,2))),
   @('{default}','osdevice',('partition='+$os.Substring(0,2))),
   @('{default}','path','\Windows\system32\winload.efi'),
   @('{default}','systemroot','\Windows'),
   @('{default}','winpe','No')
  )){$null=Invoke-Native ($native+'bcdedit.exe') (@('/store',$store,'/set')+$setting)}
  $null=Invoke-Native ($native+'bcdedit.exe') @('/store',$store,'/displayorder','{default}','/addfirst')
  # Override a stale one-time OEM/recovery selection while retaining other boot entries.
  $null=Invoke-Native ($native+'bcdedit.exe') @('/store',$store,'/bootsequence','{default}')
  $loader=Invoke-Native ($native+'bcdedit.exe') @('/store',$store,'/enum','{default}','/v')
  $loader.Text | Set-Content -LiteralPath (Join-Path $backup 'windows-loader-after.txt') -Encoding UTF8
  if(!(Test-LoaderText $loader.Text $os.Substring(0,2))){throw 'Rebuilt Windows loader failed verification'}
  $manager=$esp+'EFI\Microsoft\Boot\bootmgfw.efi'
  if((Get-PeMachine $manager) -ne 0xAA64){throw 'EFI boot manager is not ARM64'}
  New-Item -ItemType Directory -Path ($esp+'EFI\Boot') -Force | Out-Null
  Copy-Item -LiteralPath $manager -Destination ($esp+'EFI\Boot\bootaa64.efi') -Force
  if((Get-FileHash -LiteralPath $manager).Hash -ne (Get-FileHash -LiteralPath ($esp+'EFI\Boot\bootaa64.efi')).Hash){throw 'ARM64 fallback verification failed'}
}

function Invoke-ArmBootRepair {
 $script:Mounts=@();$script:Log=Join-Path $env:TEMP ('ARM-BootRepair-'+[guid]::NewGuid().ToString('N')+'.log')
 $runId=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
 $backup=$null;$esp=$null;$os=$null;$disk=$null;$target=$null;$efiPart=$null;$media=$null
 $bootTouched=$false;$filesVerified=$false;$mutex=$null;$rollback='Not needed';$exitCode=3
 try{
  if($env:PROCESSOR_ARCHITECTURE -ne 'ARM64' -or !(Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT')){throw 'Run in native ARM64 Windows PE with PowerShell, WMI and Storage components; installed Windows is not supported'}
  $createdNew=$false;$mutex=New-Object Threading.Mutex($true,'Global\WindowsArmBootRepair',[ref]$createdNew)
  if(!$createdNew){throw 'Another ARM boot repair instance is already running'}
  $native=$env:SystemRoot+'\System32\'
  foreach($tool in @('bcdboot.exe','bcdedit.exe','wpeutil.exe')){if((Get-PeMachine ($native+$tool)) -ne 0xAA64){throw ('PE tool is not native ARM64: '+$tool)}}
  $null=Invoke-Native ($native+'wpeutil.exe') @('UpdateBootInfo')
  if((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name PEFirmwareType).PEFirmwareType -ne 2){throw 'Start PE in UEFI mode'}
  Import-Module Storage -ErrorAction Stop
  $media=Resolve-BackupLocation $BackupRoot
  $backup=Join-Path $media.Root $runId
  New-Item -ItemType Directory -Path $backup | Out-Null
  Copy-Item -LiteralPath $script:Log -Destination (Join-Path $backup 'repair.log') -ErrorAction SilentlyContinue
  $script:Log=Join-Path $backup 'repair.log'
  Write-Log ('Windows ARM Boot Repair '+$script:Version+' | '+$Mode+' | firmware '+$FirmwareMode)
  Test-RepairRuntime $backup
  $profile='Generic Windows ARM64 UEFI'
  try{
   $computer=Get-CimInstance Win32_ComputerSystem;$board=Get-CimInstance Win32_BaseBoard;$processor=@(Get-CimInstance Win32_Processor)[0]
   $profile=Get-HardwareProfile ([string]$computer.Manufacturer) ([string]$computer.Model) ([string]$board.Product) ([string]$processor.Name)
   Write-RepairResult (Join-Path $backup 'hardware.txt') ([ordered]@{Manufacturer=$computer.Manufacturer;Model=$computer.Model;Board=$board.Product;Processor=$processor.Name;Profile=$profile})
  }catch{Write-Log ('Optional hardware identity unavailable: '+$_.Exception.Message)}
  Write-Log ('Profile: '+$profile)
  $allDisks=@(Get-Disk)
  $allDisks | Select-Object Number,FriendlyName,SerialNumber,UniqueId,Size,BusType,PartitionStyle,IsOffline,IsReadOnly | Export-Csv -LiteralPath (Join-Path $backup 'disks.csv') -NoTypeInformation -Encoding UTF8
  $candidates=@();$issues=@();$excluded=@();$partInventory=@()
  foreach($scanDisk in $allDisks){
   $rejection=Get-DiskRejection $scanDisk $media.Disk.Number
   if($rejection){$excluded+=[pscustomobject]@{DiskNumber=$scanDisk.Number;Reason=$rejection};continue}
   if($null -ne $DiskNumber -and $scanDisk.Number -ne $DiskNumber){continue}
   try{$parts=@(Get-Partition -DiskNumber $scanDisk.Number)}catch{$issues+=[pscustomobject]@{DiskNumber=$scanDisk.Number;PartitionNumber=-1;Reason=$_.Exception.Message};continue}
   $partInventory+=$parts
   foreach($partition in @($parts | Where-Object {[string]$_.GptType -eq $script:DataType -and $_.Size -gt 20GB})){
    if($null -ne $WindowsPartitionNumber -and $partition.PartitionNumber -ne $WindowsPartitionNumber){continue}
    try{
     $root=Mount-RepairPartition $partition
     $volume=Get-Volume -DriveLetter $root.Substring(0,1)
     if([string]$volume.FileSystem -ne 'NTFS'){throw ('Not accessible NTFS (locked, unrecognized or unsupported): '+$root)}
     # A BitLocker locked drive may still report NTFS; directory enumeration must succeed.
     $null=Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop | Select-Object -First 1
     if(Test-WindowsInstallation $root){$candidates+=[pscustomobject]@{Disk=$scanDisk;Partition=$partition;Root=$root}}
    }catch{$issues+=[pscustomobject]@{DiskNumber=$scanDisk.Number;PartitionNumber=$partition.PartitionNumber;Reason=$_.Exception.Message}}
   }
  }
  $partInventory | Select-Object DiskNumber,PartitionNumber,DriveLetter,Size,Offset,GptType,Guid | Export-Csv -LiteralPath (Join-Path $backup 'partitions.csv') -NoTypeInformation -Encoding UTF8
  $excluded | Export-Csv -LiteralPath (Join-Path $backup 'excluded-disks.csv') -NoTypeInformation -Encoding UTF8
  $issues | Export-Csv -LiteralPath (Join-Path $backup 'scan-issues.csv') -NoTypeInformation -Encoding UTF8
  $candidates | ForEach-Object {[pscustomobject]@{DiskNumber=$_.Disk.Number;Disk=$_.Disk.FriendlyName;PartitionNumber=$_.Partition.PartitionNumber;Windows=$_.Root}} | Export-Csv -LiteralPath (Join-Path $backup 'windows-candidates.csv') -NoTypeInformation -Encoding UTF8
  foreach($issue in $issues){Write-Log ('Scan issue: disk '+$issue.DiskNumber+' partition '+$issue.PartitionNumber+': '+$issue.Reason)}
  foreach($item in $candidates){Write-Log ('Windows candidate: disk '+$item.Disk.Number+' '+$item.Disk.FriendlyName+' partition '+$item.Partition.PartitionNumber+' at '+$item.Root)}
  $firmwareAvailable=$false;$firmwareReason='Skipped by request'
  if($FirmwareMode -ne 'Skip'){
   # Integrity/codec failures indicate a broken package and never silently downgrade.
   Write-Log (Initialize-FirmwareHelper)
   $probe=Get-FirmwareProbe;$firmwareReason=$probe.Reason;$firmwareAvailable=$probe.Available
  }
  Write-Log ('Firmware probe: '+$firmwareReason)
  if($Mode -eq 'Diagnose'){
   Write-RepairResult (Join-Path $backup 'result.txt') ([ordered]@{Version=$script:Version;Status='DIAGNOSED';WindowsCandidates=$candidates.Count;ScanIssues=$issues.Count;FirmwareAvailable=$firmwareAvailable;FirmwareReason=$firmwareReason;Backup=$backup;BootFilesChanged='No';PhysicalWindowsBoot='Not tested'})
   Write-Host ('Diagnosis complete. Report: '+$backup) -ForegroundColor Cyan
   return 0
  }
  $policy=Resolve-FirmwarePolicy $FirmwareMode $firmwareAvailable $firmwareReason
  $target=Select-RepairCandidate $candidates $issues $DiskNumber $WindowsPartitionNumber -AllowChoice:($Mode -eq 'Interactive')
  $disk=$target.Disk;$os=$target.Root
  $efiPart=Select-EspPartition @(Get-Partition -DiskNumber $disk.Number) $EspPartitionNumber -AllowChoice:($Mode -eq 'Interactive')
  if($policy.WriteFirmware){Assert-FirmwareGeometry $disk $efiPart}
  $esp=Mount-RepairPartition $efiPart
  $efiVolume=Get-Volume -DriveLetter $esp.Substring(0,1)
  if([string]$efiVolume.FileSystem -ne 'FAT32'){throw 'Selected EFI partition must be FAT32'}
  $efiBytes=0
  if(Test-Path -LiteralPath ($esp+'EFI')){$efiBytes=(@(Get-ChildItem -LiteralPath ($esp+'EFI') -Recurse -File -Force) | Measure-Object Length -Sum).Sum}
  if($efiVolume.SizeRemaining -lt ([long]$efiBytes+64MB)){throw 'EFI partition lacks repair/rollback space (existing EFI size plus 64 MiB free required)'}
  if((Get-Volume -DriveLetter $media.VolumeRoot.Substring(0,1)).SizeRemaining -lt ([long]$efiBytes+128MB)){throw 'External backup volume lacks EFI size plus 128 MiB free space'}
  Write-Log ('Plan: disk '+$disk.Number+' '+$disk.FriendlyName+'; Windows '+$os+'; EFI '+$esp+'; backup '+$backup)
  Write-Log $policy.Reason
  if($Mode -eq 'Interactive'){
   Write-Host 'This makes the selected Windows the default boot choice and replaces its Windows/ARM fallback boot files. Existing EFI files are backed up.'
   if((Read-Host 'Type REPAIR to apply this plan, or press Enter to cancel') -cne 'REPAIR'){
    Write-RepairResult (Join-Path $backup 'result.txt') ([ordered]@{Version=$script:Version;Status='CANCELLED';Backup=$backup})
    return 5
   }
  }
  Assert-RepairIdentity $disk $target.Partition $os $efiPart $esp $media
  $null=Test-WindowsInstallation $os
  Backup-Efi $esp $backup
  Assert-RepairIdentity $disk $target.Partition $os $efiPart $esp $media
  $bootTouched=$true
  Invoke-BootFileRepair $os $esp $backup
  Assert-RepairIdentity $disk $target.Partition $os $efiPart $esp $media
  $filesVerified=$true;$firmwareId='Not updated'
  if($policy.WriteFirmware){
   Write-Log 'Boot files verified. Updating and verifying UEFI Boot option, BootOrder and BootNext.'
   $firmwareId=Set-RepairFirmware $esp $backup $efiPart $disk
   $status='REPAIRED';$exitCode=0
  }else{$status='FILES_ONLY';$exitCode=2}
  Write-RepairResult (Join-Path $backup 'result.txt') ([ordered]@{Version=$script:Version;Status=$status;DiskNumber=$disk.Number;Disk=$disk.FriendlyName;Serial=$disk.SerialNumber;Windows=$os;EFI=$esp;FirmwareEntry=$firmwareId;FirmwareReason=$policy.Reason;Backup=$backup;PhysicalWindowsBoot='Not yet tested'})
  if($status -eq 'REPAIRED'){
   Write-Host 'SUCCESS: boot files and firmware entry verified. Actual Windows startup still needs a reboot test.' -ForegroundColor Green
  }else{Write-Host 'FILES ONLY: EFI/BCD and ARM fallback verified; firmware entry was not updated. Use the firmware boot menu if necessary.' -ForegroundColor Yellow}
  Write-Host ('Backup and report: '+$backup)
  if($RebootAfterRepair -and $status -eq 'REPAIRED'){
   Write-Host 'Remove the external backup/repair media to reboot. Keep AC power connected.'
   while(Test-Path -LiteralPath $media.VolumeRoot){Start-Sleep -Seconds 2}
   & ($native+'wpeutil.exe') reboot
  }
  return $exitCode
 }catch{
  $reason=$_.Exception.Message
  try{Write-Log ('STOPPED: '+$reason)}catch{Write-Host $reason -ForegroundColor Red}
  if($bootTouched){$exitCode=4}
  if($bootTouched -and !$filesVerified -and $backup -and $esp){
   try{
    Assert-RepairIdentity $disk $target.Partition $os $efiPart $esp $media
    Restore-Efi $esp $backup $runId
    $rollback='Previous managed EFI directories restored and verified; failed output retained'
    Write-Log $rollback
   }catch{$rollback='Needs inspection: '+$_.Exception.Message;Write-Host $rollback -ForegroundColor Red}
  }
  if($backup){
   try{Write-RepairResult (Join-Path $backup 'result.txt') ([ordered]@{Version=$script:Version;Status=$(if($bootTouched){'PARTIAL'}else{'STOPPED'});Reason=$reason;EFIFileVerification=$filesVerified;Rollback=$rollback;Windows=$os;EFI=$esp;Backup=$backup;PhysicalWindowsBoot='Not tested'})}catch{}
  }
  Write-Host ('Stopped. Report: '+$script:Log) -ForegroundColor Yellow
  return $exitCode
 }finally{
  Remove-RepairMounts
  if($mutex){$mutex.Dispose()}
 }
}
if($LibraryOnly){return}
exit (Invoke-ArmBootRepair)
