# Reporting a security issue

This program runs with administrative privileges in Windows PE and writes boot state. Target-selection errors, unsafe path handling and accidental writes outside the selected disk are security-relevant bugs.

For issues that do not contain sensitive information, open an issue with a minimal reproduction, expected/actual behavior and a sanitized result summary. Do not attach recovery keys, complete disk images, EFI backups, firmware-variable dumps or unredacted device logs. The project does not collect telemetry.

This is an experimental initial release; there is no supported stable branch yet. Use the current source and release checksums when reproducing an issue. A SHA-256 sidecar detects corruption but is not an authenticated signature.
