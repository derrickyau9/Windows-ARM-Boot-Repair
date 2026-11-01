# Windows ARM Boot Repair

An experimental boot-repair toolkit for Windows on ARM, developed from an HP ARM laptop migration repair workflow. It is intended for RTX Spark / Windows ARM recovery scenarios, but does not claim universal device compatibility or official OEM support.

Version 0.1.0 provides automatic discovery, interactive selection, diagnostics, verified EFI backups, scoped BCDBoot/BCD repair, an ARM64 fallback loader and a UEFI boot-variable transaction. The generalized release has **not yet passed a physical boot test**. Mock tests cannot establish hardware compatibility.

## Run from ARM64 Windows PE

Your PE must already boot on the target machine, recognize its storage and provide native ARM64 PowerShell 5.1, .NET and StorageWMI. OEM drivers and Secure Boot trust must already work. This repository does not distribute PE, Windows images or drivers.

Extract the release ZIP to an external USB volume. In the target machine's PE, substitute its current USB drive letter:

```bat
E:\WindowsArmBootRepair\Diagnose.cmd -BackupRoot E:\
E:\WindowsArmBootRepair\Run-Repair.cmd -BackupRoot E:\
```

`Run-Automatic.cmd -BackupRoot E:\` repairs only an unambiguous eligible target. `Run-Repair.cmd` presents choices and asks for confirmation. Calling the PowerShell script directly defaults to diagnosis. It does not reboot by default.

Create an empty `ARM-BOOT-REPAIR.TAG` at the backup volume's root for automatic media discovery, or always pass `-BackupRoot`. Backups must reside on a USB/SD disk separate from the Windows disk. Disconnect unrelated storage, particularly Thunderbolt/eSATA enclosures which may report an internal-looking bus type.

## Scope

The target must have an accessible complete ARM64 Windows installation on GPT and an existing same-disk FAT32 EFI System Partition. Locked BitLocker volumes, missing ESPs and ambiguous cloned partition identities require resolving before repair. USB/SD and unsupported bus types are excluded as repair targets.

`-FirmwareMode Auto` attempts firmware repair if preflight succeeds; otherwise it returns `FILES_ONLY` after file repair. `Required` stops before file changes if firmware preflight fails. `Skip` explicitly chooses file repair only. A failure during firmware writes is reported as partial; the helper attempts to restore its original firmware state.

The selected Windows becomes the default. Other EFI vendor directories and unrelated firmware entries are retained. Backups and readbacks protect against detectable failures, but neither power loss nor successful Windows startup is covered by a software guarantee.

## Build and integrate

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Build.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\New-Package.ps1 -SkipBuild
```

The build uses Windows PowerShell 5.1 and the .NET Framework C# compiler. x64 Windows can build the AnyCPU library; only native ARM64 UEFI WinPE can run its production firmware operations. Tests use fake firmware variables and temporary files.

See [PE integration](PE-INTEGRATION.md), [compatibility](COMPATIBILITY.md) and [design](DESIGN.md). Report a sanitized error summary, not full EFI backups, firmware snapshots, serial numbers or recovery keys.
