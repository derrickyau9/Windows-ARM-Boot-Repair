# Design and recovery boundaries

The runtime is Windows PowerShell 5.1. A small .NET Framework AnyCPU library implements the UEFI variable transaction. No Microsoft binaries are distributed. Native BCDBoot and BCDEdit come from the running ARM64 PE; Windows boot files come from the selected offline Windows installation.

## Discovery and selection

The runtime checks ARM64, WinPE and UEFI, then discovers supported internal GPT disks and complete ARM64 Windows installations. Hardware names are descriptive, not authorization keys. The backup volume's physical disk is excluded. Explicit disk or partition parameters do not bypass eligibility checks.

Automatic repair needs a uniquely valid target. Interactive repair presents candidates and asks for a final confirmation. Inaccessible or incomplete installations must be reported instead of silently guessing. The selected ESP must be FAT32 and reside on the Windows disk. A missing ESP is a stop condition; this tool does not create one.

Diagnosis may create logs on external media and temporarily assign drive letters. It does not repair EFI/BCD or write firmware variables. Drive letters created by the tool are removed on exit after identity checks; existing drive letters are retained.

## File repair

1. Record disk and partition identities, verify runtime capabilities, available space and the external backup location.
2. Copy the existing EFI tree to a new per-run backup directory and verify SHA-256 for every file.
3. Recheck identities before writes. Invoke ARM64 BCDBoot with explicit Windows and ESP paths, `/s`, `/f UEFI`, and verbose output. The generic tool does not use `/c` to discard the whole previous BCD configuration.
4. Set and validate the selected Windows loader, its Windows partition and normal `winload.efi` path. The selected Windows becomes the default and replaces any stale Windows Boot Manager one-time recovery selection. Clear `persistbootsequence` and `resume` so the override stays one-time and does not immediately attempt an old hibernation resume. Other EFI vendor directories remain in place; `hiberboot`, `recoveryenabled` and `recoverysequence` are not changed.
5. Copy the manager selected by BCDBoot to `EFI\Boot\bootaa64.efi`, checking architecture and matching hash.
6. Only then attempt the firmware transaction, if enabled and available.

The standard ARM64 fallback location is useful but is not a promise that every firmware will boot a fixed disk without a firmware entry. The tool does not alter Secure Boot keys, sign loaders, enable test signing or bypass TPM checks.

## Firmware transaction

`GetFirmwareEnvironmentVariableExW` and `SetFirmwareEnvironmentVariableExW` access only `Boot####`, `BootOrder` and `BootNext` in the EFI global namespace. The library enables `SeSystemEnvironmentPrivilege` for its scope and restores the previous privilege state on disposal. Public production entry points enforce native ARM64, UEFI and MiniNT.

The load option uses a GPT hard-drive device path plus the exact `\EFI\Microsoft\Boot\bootmgfw.efi` file path. Geometry uses the disk's actual logical sector size (512 or 4096). Identical cloned partition GUIDs make short-form paths ambiguous, so they must be resolved before repair.

The helper reuses an exact matching owned entry or finds an unused variable number; it never overwrites an unrelated entry. It saves original bytes, attributes and existence, rechecks that the state has not changed, then writes and reads back the option, persistent order and one-time selection. Other order entries remain present. On any failure it restores and verifies the prior state. If rollback cannot remove an entry safely because it remains referenced, it retains it and reports the problem.

The helper's hash sidecar detects accidental mismatch between package files. It is not a digital signature or a trust guarantee; obtain the ZIP from the expected repository and compare its release checksum.

## Result semantics and rollback

- `REPAIRED`: file and firmware readbacks passed. Physical Windows boot remains untested.
- `FILES_ONLY`: EFI/BCD passed but firmware was intentionally skipped or unavailable during preflight. The user may need the firmware's boot menu or a supported vendor recovery route.
- `PARTIAL`: a later stage failed after verified EFI repair, or rollback requires inspection. The tool reports it rather than pretending success.
- `STOPPED`: preflight/selection failure, or an unsuccessful operation with details recorded in the result.

Before file verification, a file-stage failure triggers restoration of the two managed boot directories from the verified backup. New failed directories are renamed and retained for diagnosis. After successful file verification, a firmware failure keeps the repaired EFI files; the firmware helper handles its own rollback. These are separate transactions, not one atomic disk-and-firmware transaction.

Backups are local to the chosen external media. There is no telemetry and no automatic log upload. For manual recovery, retain the entire run directory and inspect `repair.log`, `result.txt`, `EFI-files-before.csv`, the saved EFI tree and `Firmware` states. Reconfirm physical disk and GPT identities before restoring anything. This initial release intentionally has no unattended restore-from-an-arbitrary-folder command.

Rollback is best effort after detected errors; it is not power-loss atomic. Keep stable power during repair.

## References

- [Microsoft BCDBoot reference](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/bcdboot-command-line-options-techref-di?view=windows-11): explicit `/s` suppresses BCDBoot's NVRAM creation; `/f` requires `/s`; `/c` resets old settings.
- [Microsoft WinPE optional components](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/winpe-add-packages--optional-components-reference?view=windows-11): ARM64 packages, architecture/build matching and PowerShell/StorageWMI dependencies.
- [GetFirmwareEnvironmentVariableExW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getfirmwareenvironmentvariableexw) and [SetFirmwareEnvironmentVariableExW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-setfirmwareenvironmentvariableexw).
- [AdjustTokenPrivileges](https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-adjusttokenprivileges).
- [UEFI 2.11 Boot Manager](https://uefi.org/specs/UEFI/2.11/03_Boot_Manager.html) and [UEFI device paths](https://uefi.org/specs/UEFI/2.10/10_Protocols_Device_Path_Protocol.html).
